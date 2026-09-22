module CodecZstdExt

using BeveFormat
using CodecZstd
using CodecZstd: ZstdCompressorStream, ZstdDecompressorStream
using BeveFormat: to_beve, to_beve!, from_beve, deser_beve, BeveSerializer, beve_value!
import BeveFormat: to_beve_zstd, from_beve_zstd, write_beve_zstd_file, read_beve_zstd_file,
              deser_beve_zstd, deser_beve_zstd_file

const DEFAULT_ZSTD_LEVEL = 3
const _transcode = CodecZstd.TranscodingStreams.transcode

# Serialize `data` to BEVE and Zstd-compress the result in memory.
# Pass an `IOBuffer` via `buffer` to reuse its allocation across calls.
function to_beve_zstd(data;
                      buffer::Union{Nothing, IOBuffer} = nothing,
                      level::Integer = DEFAULT_ZSTD_LEVEL)::Vector{UInt8}
    if buffer === nothing
        raw = to_beve(data)  # allocates a fresh buffer and returns serialized bytes
    else
        to_beve!(buffer, data)  # serializes into the existing IOBuffer (returns Nothing)
        raw = take!(buffer)  # extract the serialized bytes as a Vector{UInt8}
    end
    return _transcode(ZstdCompressor(level = level), raw)
end

function from_beve_zstd(data::AbstractVector{UInt8};
                        preserve_matrices::Bool = false)
    decompressed = _transcode(ZstdDecompressor(), data)
    return from_beve(decompressed; preserve_matrices = preserve_matrices)
end

# Streaming generic decode of a Zstd-compressed BEVE stream: decompress and
# deserialize on the fly, so neither the compressed bytes nor the decompressed
# bytes are ever held in full. Peak memory is the decoded value plus the codec's
# and deserializer's working buffers.
function from_beve_zstd(io::IO; preserve_matrices::Bool = false)
    stream = ZstdDecompressorStream(io)
    return from_beve(stream; preserve_matrices = preserve_matrices)
end

# Serialize `data` directly through a ZstdCompressorStream to `path`,
# avoiding large intermediate buffers. Only Zstd's internal buffers are
# held in memory, so peak RAM is independent of the data size.
function write_beve_zstd_file(path::AbstractString,
                              data;
                              level::Integer = DEFAULT_ZSTD_LEVEL)::Nothing
    open(path, "w") do file_io
        stream = ZstdCompressorStream(file_io; level = level)
        ser = BeveSerializer(stream)
        beve_value!(ser, data)
        close(stream)
    end
    return nothing
end

function read_beve_zstd_file(path::AbstractString;
                             preserve_matrices::Bool = false)
    return open(path, "r") do file_io
        from_beve_zstd(file_io; preserve_matrices = preserve_matrices)
    end
end

function deser_beve_zstd(::Type{T}, data::AbstractVector{UInt8};
                         error_on_missing_fields::Bool = false,
                         preserve_matrices::Bool = false) where T
    decompressed = _transcode(ZstdDecompressor(), data)
    return deser_beve(T, decompressed;
                      error_on_missing_fields = error_on_missing_fields,
                      preserve_matrices = preserve_matrices)
end

# Streaming typed decode of a Zstd-compressed BEVE stream: decompress and decode
# directly into `T` on the fly. Combined with the structural streaming in
# `deser_beve(T, ::IO)`, peak memory is the constructed `T` plus working buffers,
# with neither the compressed nor decompressed bytes held in full.
function deser_beve_zstd(::Type{T}, io::IO;
                         error_on_missing_fields::Bool = false,
                         preserve_matrices::Bool = false) where T
    stream = ZstdDecompressorStream(io)
    return deser_beve(T, stream;
                      error_on_missing_fields = error_on_missing_fields,
                      preserve_matrices = preserve_matrices)
end

function deser_beve_zstd_file(::Type{T}, path::AbstractString;
                              error_on_missing_fields::Bool = false,
                              preserve_matrices::Bool = false) where T
    return open(path, "r") do file_io
        deser_beve_zstd(T, file_io;
                        error_on_missing_fields = error_on_missing_fields,
                        preserve_matrices = preserve_matrices)
    end
end

end # module
