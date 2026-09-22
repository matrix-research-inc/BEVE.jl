# Tests for streaming typed deserialization: `deser_beve(T, ::IO)` and friends.
#
# The existing suite already exercises the streaming engine indirectly, since
# `deser_beve_file` / `read_beve_file` / the `*_zstd_file` readers were rerouted
# through it. These tests target the streaming-specific guarantees that a
# buffer-only path cannot: IO/buffer result parity, correct blocking when bytes
# arrive in bursts (no treating a transiently-empty stream as EOF), and skipping
# large unmatched object fields without materializing them.

struct StrmInner
    a::Int
    b::String
end

struct StrmOuter
    name::String
    xs::Vector{Float64}
    iq::Vector{ComplexF32}
    inner::StrmInner
    children::Vector{StrmInner}
    tags::Dict{String, Int}
    opt::Union{Nothing, Int}
end

# A subset of StrmOuter's fields, to exercise on-the-wire skipping of the omitted
# (and deliberately large) ones.
struct StrmSubset
    name::String
    inner::StrmInner
end

Base.@kwdef struct StrmDefaults
    present::Int
    missing_with_default::String = "default"
end

abstract type StrmShape end
struct StrmCircle <: StrmShape
    radius::Float64
end
struct StrmSquare <: StrmShape
    side::Float64
end
StructUtils.@choosetype StrmShape x -> haskey(x, "radius") ? StrmCircle : StrmSquare

struct StrmShapeHolder
    label::String
    shape::StrmShape
end

struct StrmNM
    v::Union{Nothing, Missing, Int}
end

# Stream `bytes` into `io` one small chunk at a time from a background task while
# the foreground decodes, so the deserializer must block on a transiently-empty
# stream rather than see EOF. Returns the decoded value.
function decode_in_bursts(::Type{T}, bytes::Vector{UInt8}; chunk::Int = 1) where {T}
    bs = Base.BufferStream()
    producer = @async begin
        i = 1
        n = length(bytes)
        while i <= n
            j = min(i + chunk - 1, n)
            write(bs, @view bytes[i:j])
            yield()
            i = j + 1
        end
        close(bs)
    end
    result = deser_beve(T, bs)
    wait(producer)
    return result
end

@testset "Streaming typed deserialization" begin
    sample = StrmOuter(
        "collection-7",
        collect(1.0:0.5:50.0),
        ComplexF32[ComplexF32(i, -i) for i in 1:64],
        StrmInner(11, "origin"),
        [StrmInner(1, "a"), StrmInner(2, "b"), StrmInner(3, "c")],
        Dict("alpha" => 1, "beta" => 2, "gamma" => 3),
        nothing,
    )
    sample_bytes = to_beve(sample)

    @testset "IO decode matches buffer decode" begin
        from_buffer = deser_beve(StrmOuter, sample_bytes)
        from_io = deser_beve(StrmOuter, IOBuffer(sample_bytes))

        @test from_io.name == from_buffer.name
        @test from_io.xs == from_buffer.xs
        @test from_io.iq == from_buffer.iq
        @test from_io.iq isa Vector{ComplexF32}
        @test from_io.inner.a == from_buffer.inner.a
        @test from_io.inner.b == from_buffer.inner.b
        @test length(from_io.children) == 3
        @test [c.a for c in from_io.children] == [1, 2, 3]
        @test [c.b for c in from_io.children] == ["a", "b", "c"]
        @test from_io.tags == from_buffer.tags
        @test from_io.opt === nothing
    end

    @testset "present nullable union over IO" begin
        present = StrmOuter(
            "c", Float64[1.0], ComplexF32[ComplexF32(1, 1)],
            StrmInner(1, "x"), StrmInner[], Dict{String, Int}(), 99,
        )
        decoded = deser_beve(StrmOuter, IOBuffer(to_beve(present)))
        @test decoded.opt == 99
    end

    @testset "unmatched object fields are skipped on the wire" begin
        decoded = deser_beve(StrmSubset, IOBuffer(sample_bytes))
        @test decoded.name == "collection-7"
        @test decoded.inner.a == 11
        @test decoded.inner.b == "origin"
    end

    @testset "skipping a large unmatched field does not materialize it" begin
        # A ~40 MB array field that the target type omits entirely.
        big = StrmOuter(
            "big",
            collect(1.0:1.0:5_000_000.0),   # ~40 MB of Float64
            ComplexF32[ComplexF32(1, 2)],
            StrmInner(5, "keep"),
            StrmInner[],
            Dict("k" => 1),
            nothing,
        )
        big_bytes = to_beve(big)
        @test sizeof(big.xs) > 32_000_000

        decoded = deser_beve(StrmSubset, IOBuffer(big_bytes))
        @test decoded.name == "big"
        @test decoded.inner.a == 5

        # Decoding the subset must allocate far less than the skipped array: the
        # large field is advanced over on the wire, never built.
        allocated = @allocated deser_beve(StrmSubset, IOBuffer(big_bytes))
        @test allocated < sizeof(big.xs) ÷ 4
    end

    @testset "stream is fully consumed after a subset decode" begin
        io = IOBuffer(sample_bytes)
        deser_beve(StrmSubset, io)
        @test eof(io)
    end

    @testset "partial reads: bytes arriving in bursts never look like EOF" begin
        # One byte at a time, foreground blocking on a BufferStream.
        decoded = decode_in_bursts(StrmOuter, sample_bytes; chunk = 1)
        @test decoded.name == "collection-7"
        @test decoded.xs == sample.xs
        @test decoded.iq == sample.iq
        @test [c.b for c in decoded.children] == ["a", "b", "c"]
        @test decoded.tags == sample.tags

        # A larger array in 7-byte bursts (straddles typed-array element reads).
        big = StrmOuter(
            "burst", collect(1.0:1.0:20_000.0), ComplexF32[ComplexF32(3, 4)],
            StrmInner(9, "n"), StrmInner[StrmInner(8, "m")], Dict("z" => 26), 7,
        )
        big_bytes = to_beve(big)
        decoded_big = decode_in_bursts(StrmOuter, big_bytes; chunk = 7)
        @test decoded_big.xs == big.xs
        @test decoded_big.opt == 7
        @test decoded_big.children[1].a == 8
    end

    @testset "partial reads while skipping a large unmatched field" begin
        # The blocking discard path (`_discard_bytes!`) must also tolerate bytes
        # arriving in bursts: skip a large unmatched field delivered piecemeal.
        big = StrmOuter(
            "burstskip", collect(1.0:1.0:40_000.0), ComplexF32[ComplexF32(1, 1)],
            StrmInner(6, "keep"), StrmInner[], Dict("k" => 1), nothing,
        )
        big_bytes = to_beve(big)
        decoded = decode_in_bursts(StrmSubset, big_bytes; chunk = 13)
        @test decoded.name == "burstskip"
        @test decoded.inner.a == 6
        @test decoded.inner.b == "keep"
    end

    @testset "Union{Nothing, Missing, X} null parity with buffer path" begin
        null_bytes = to_beve(Dict("v" => nothing))
        # Both paths must resolve a wire null to the same union member.
        @test deser_beve(StrmNM, null_bytes).v === deser_beve(StrmNM, IOBuffer(null_bytes)).v
        @test deser_beve(StrmNM, IOBuffer(null_bytes)).v === missing
        # A present value still decodes.
        @test deser_beve(StrmNM, IOBuffer(to_beve(Dict("v" => 5)))).v === 5
    end

    @testset "integer-keyed dict over IO" begin
        d = Dict{Int32, String}(Int32(1) => "one", Int32(2) => "two", Int32(3) => "three")
        decoded = deser_beve(Dict{Int32, String}, IOBuffer(to_beve(d)))
        @test decoded == d

        # Integer-keyed map forced into a non-dict type is rejected, as in the
        # buffer path, decided from the header alone.
        @test_throws BeveFormat.BeveError deser_beve(StrmInner, IOBuffer(to_beve(d)))
    end

    @testset "@kwdef default for a missing field over IO" begin
        partial = Dict("present" => 42)
        decoded = deser_beve(StrmDefaults, IOBuffer(to_beve(partial)))
        @test decoded.present == 42
        @test decoded.missing_with_default == "default"
    end

    @testset "strict missing-field error over IO" begin
        partial = Dict("a" => 1)   # StrmInner also needs "b"
        @test_throws BeveFormat.BeveError deser_beve(
            StrmInner, IOBuffer(to_beve(partial)); error_on_missing_fields = true,
        )
    end

    @testset "@choosetype / abstract field over IO (materialized fallback)" begin
        circle = StrmShapeHolder("c", StrmCircle(2.5))
        square = StrmShapeHolder("s", StrmSquare(4.0))

        dc = deser_beve(StrmShapeHolder, IOBuffer(to_beve(circle)))
        @test dc.shape isa StrmCircle
        @test dc.shape.radius == 2.5

        ds = deser_beve(StrmShapeHolder, IOBuffer(to_beve(square)))
        @test ds.shape isa StrmSquare
        @test ds.shape.side == 4.0
    end

    @testset "bare leaf and array targets over IO" begin
        @test deser_beve(Vector{Float64}, IOBuffer(to_beve(collect(1.0:100.0)))) == collect(1.0:100.0)
        @test deser_beve(Vector{ComplexF64}, IOBuffer(to_beve(ComplexF64[1 + 2im, 3 + 4im]))) == ComplexF64[1 + 2im, 3 + 4im]
        @test deser_beve(String, IOBuffer(to_beve("plain"))) == "plain"
        @test deser_beve(Int, IOBuffer(to_beve(1234))) == 1234
        @test deser_beve(Vector{StrmInner}, IOBuffer(to_beve([StrmInner(1, "x"), StrmInner(2, "y")]))) ==
              [StrmInner(1, "x"), StrmInner(2, "y")]
    end

    @testset "deser_beve_file streams from disk" begin
        mktempdir() do dir
            path = joinpath(dir, "sample.beve")
            write_beve_file(path, sample)
            decoded = deser_beve_file(StrmOuter, path)
            @test decoded.name == sample.name
            @test decoded.xs == sample.xs
            @test decoded.iq == sample.iq
        end
    end
end

# Streaming Zstd typed decode, only when CodecZstd is available.
let
    codeczstd_available = try
        Base.require(Base.PkgId(Base.UUID("6b39b394-51ab-5f42-8807-6242bab2b4c2"), "CodecZstd"))
        true
    catch
        @info "Skipping streaming Zstd tests: CodecZstd not available"
        false
    end

    if codeczstd_available
        @testset "Streaming Zstd typed decode" begin
            sample = StrmOuter(
                "zc",
                collect(1.0:1.0:10_000.0),
                ComplexF32[ComplexF32(i, i) for i in 1:32],
                StrmInner(3, "z"),
                [StrmInner(4, "w")],
                Dict("q" => 17),
                123,
            )
            compressed = BeveFormat.to_beve_zstd(sample)

            from_buffer = deser_beve_zstd(StrmOuter, compressed)
            from_io = deser_beve_zstd(StrmOuter, IOBuffer(compressed))
            @test from_io.name == from_buffer.name
            @test from_io.xs == from_buffer.xs
            @test from_io.iq == from_buffer.iq
            @test from_io.opt == 123

            # Generic streaming zstd from IO.
            generic = from_beve_zstd(IOBuffer(compressed))
            @test generic["name"] == "zc"

            mktempdir() do dir
                path = joinpath(dir, "sample.beve.zst")
                write_beve_zstd_file(path, sample)
                decoded = deser_beve_zstd_file(StrmOuter, path)
                @test decoded.xs == sample.xs
                @test decoded.children[1].b == "w"
            end
        end
    end
end
