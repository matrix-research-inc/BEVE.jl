# BEVE Streaming Typed Deserialization
#
# `deser_beve(T, io::IO)` decodes a BEVE stream directly into the Julia type `T`
# without first building the full generic `Dict`/`Vector` tree that the
# buffer-based `deser_beve(T, ::Vector{UInt8})` constructs via `from_beve`. For a
# large payload that intermediate boxed tree is bigger than either the input or
# the output struct; this path avoids it so peak memory is the constructed `T`
# plus `O(chunk)` working buffers.
#
# Strategy: the decode is driven by the *target type*. `stream_make(style, T,
# deser)` decodes exactly one BEVE value from the deserializer into `T`:
#
#   * Object/generic-array headers whose target is a struct / dict / 1-D array
#     are streamed structurally: each field/element is decoded straight into its
#     typed slot, and object keys that do not match a struct field are skipped on
#     the wire (`skip_value!`) without ever being materialized.
#   * Every other value (scalars, strings, typed numeric arrays, complex,
#     matrices, tags) is read with the existing `parse_value`, which already
#     bulk-reads typed arrays into their natural Julia vectors with no boxing.
#   * Values whose target needs to inspect the whole value before constructing it
#     (`@choosetype`, `Union`, abstract types) are materialized for that one
#     subtree (bounded by the subtree, not the payload) and handed to the normal
#     `StructUtils.make` pipeline, so all existing lift/choosetype/union logic is
#     reused verbatim.
#
# This deliberately does *not* override `StructUtils.make`/`applyeach` on a lazy
# stream value: a `@choosetype`-registered type defines its own
# `make(::StructStyle, ::Type{ThatType}, source)`, which would be mutually
# ambiguous with such an override. Driving the recursion ourselves and only ever
# handing *materialized* values to `StructUtils.make` keeps dispatch unambiguous.

# ─── Header classification helpers ────────────────────────────────────────────

@inline function _is_int_object_header(h::UInt8)
    return h == I8_OBJECT || h == I16_OBJECT || h == I32_OBJECT || h == I64_OBJECT || h == I128_OBJECT ||
           h == U8_OBJECT || h == U16_OBJECT || h == U32_OBJECT || h == U64_OBJECT || h == U128_OBJECT
end

@inline _is_object_header(h::UInt8) = h == STRING_OBJECT || _is_int_object_header(h)

# Element type for an integer-keyed object header.
@inline function _object_key_type(h::UInt8)
    h == I8_OBJECT   ? Int8   :
    h == I16_OBJECT  ? Int16  :
    h == I32_OBJECT  ? Int32  :
    h == I64_OBJECT  ? Int64  :
    h == I128_OBJECT ? Int128 :
    h == U8_OBJECT   ? UInt8  :
    h == U16_OBJECT  ? UInt16 :
    h == U32_OBJECT  ? UInt32 :
    h == U64_OBJECT  ? UInt64 :
    h == U128_OBJECT ? UInt128 :
    throw(BeveError("Not an integer-keyed object header: 0x$(string(h, base = 16))"))
end

# Byte width of one element of a typed numeric array header (the size that
# follows `read_size`), or 0 if `h` is not a fixed-width numeric array header.
@inline function _numeric_array_elem_bytes(h::UInt8)
    (h == I8_ARRAY  || h == U8_ARRAY)  ? 1  :
    (h == I16_ARRAY || h == U16_ARRAY || h == F16_ARRAY || h == BF16_ARRAY) ? 2 :
    (h == I32_ARRAY || h == U32_ARRAY || h == F32_ARRAY) ? 4 :
    (h == I64_ARRAY || h == U64_ARRAY || h == F64_ARRAY) ? 8 :
    (h == I128_ARRAY || h == U128_ARRAY || h == F128_ARRAY) ? 16 :
    0
end

# ─── Skipping a value on the wire (no materialization) ────────────────────────

# Read and discard exactly `n` bytes from the deserializer's stream using its
# working buffer, blocking for more bytes if the stream is still delivering.
function _discard_bytes!(deser::BeveDeserializer, n::Integer)
    n <= 0 && return nothing
    buf = deser.read_buffer
    remaining = Int(n)
    while remaining > 0
        chunk = min(remaining, length(buf))
        nread = readbytes!(deser.io, buf, chunk)
        nread == 0 && throw(BeveError("Unexpected end of data while skipping $(n) bytes at byte $(deser.pos)"))
        deser.pos += nread
        remaining -= nread
    end
    return nothing
end

# Skip a length-prefixed string body (the `read_size` count + that many bytes),
# i.e. a BEVE string *without* its header byte (as used for object keys).
@inline function _skip_string_body!(deser::BeveDeserializer)
    _discard_bytes!(deser, read_size(deser))
    return nothing
end

"""
    skip_value!(deser::BeveDeserializer) -> Nothing

Advance `deser` past exactly one BEVE value (header + body) without
materializing it. Used by the streaming typed decoder to drop object entries
whose key does not correspond to a target struct field, so an arbitrarily large
unmatched value never has to be allocated just to be discarded.
"""
function skip_value!(deser::BeveDeserializer)
    header = read_byte!(deser)
    _skip_after_header!(deser, header)
    return nothing
end

function _skip_after_header!(deser::BeveDeserializer, header::UInt8)
    if header == NULL || header == FALSE || header == TRUE
        return nothing
    elseif header == I8 || header == U8
        _discard_bytes!(deser, 1)
    elseif header == I16 || header == U16 || header == F16 || header == BF16
        _discard_bytes!(deser, 2)
    elseif header == I32 || header == U32 || header == F32
        _discard_bytes!(deser, 4)
    elseif header == I64 || header == U64 || header == F64
        _discard_bytes!(deser, 8)
    elseif header == I128 || header == U128 || header == F128
        _discard_bytes!(deser, 16)
    elseif header == STRING
        _skip_string_body!(deser)
    elseif header == STRING_OBJECT
        n = read_size(deser)
        for _ in 1:n
            _skip_string_body!(deser)
            skip_value!(deser)
        end
    elseif _is_int_object_header(header)
        kbytes = sizeof(_object_key_type(header))
        n = read_size(deser)
        for _ in 1:n
            _discard_bytes!(deser, kbytes)
            skip_value!(deser)
        end
    elseif header == GENERIC_ARRAY
        n = read_size(deser)
        for _ in 1:n
            skip_value!(deser)
        end
    elseif header == STRING_ARRAY
        n = read_size(deser)
        for _ in 1:n
            _skip_string_body!(deser)
        end
    elseif header == BOOL_ARRAY
        n = read_size(deser)
        _discard_bytes!(deser, (n + 7) ÷ 8)
    elseif (elbytes = _numeric_array_elem_bytes(header)) != 0
        n = read_size(deser)
        _discard_bytes!(deser, n * elbytes)
    elseif header == COMPLEX
        _skip_complex!(deser)
    elseif header == MATRIX
        _skip_matrix!(deser)
    elseif header == TAG
        read_size(deser)        # type-tag index
        skip_value!(deser)      # tagged value
    else
        throw(BeveError("Cannot skip BEVE value with header $(header_name(header)) (0x$(string(header, base = 16))) at byte $(deser.pos)"))
    end
    return nothing
end

function _skip_complex!(deser::BeveDeserializer)
    complex_header = read_byte!(deser)
    is_array = complex_header & 0x01
    byte_count = 1 << ((complex_header >> 5) & 0x07)   # bytes per real/imag component
    if is_array != 0
        n = read_size(deser)
        _discard_bytes!(deser, n * 2 * byte_count)
    else
        _discard_bytes!(deser, 2 * byte_count)
    end
    return nothing
end

function _skip_matrix!(deser::BeveDeserializer)
    read_byte!(deser)                       # matrix layout header
    extents_header = read_byte!(deser)
    _skip_after_header!(deser, extents_header)  # extents: a typed integer array body
    skip_value!(deser)                      # matrix value (typed/complex array)
    return nothing
end

# ─── Streaming decode driven by the target type ───────────────────────────────

# Can the value with header `header` be streamed structurally into `T` (vs.
# materialized and routed through the normal `make` pipeline)?
@inline function _can_stream(style::BeveStyle, ::Type{T}, header::UInt8, tags) where {T}
    haskey(tags, :choosetype) && return false
    if header == STRING_OBJECT
        return StructUtils.dictlike(style, T) || StructUtils.noarg(style, T) ||
               (StructUtils.structlike(style, T) && !(T <: Tuple))
    elseif _is_int_object_header(header)
        return StructUtils.dictlike(style, T)
    elseif header == GENERIC_ARRAY
        return (T <: AbstractArray && ndims(T) == 1) || T <: AbstractSet
    else
        return false
    end
end

"""
    deser_beve(::Type{T}, io::IO; error_on_missing_fields = false,
               preserve_matrices = false) -> T

Streaming typed deserialization: decode a BEVE value directly from `io` into the
Julia type `T` without first building the intermediate generic `Dict`/`Vector`
tree. Object fields are decoded straight into their typed struct slots and
unmatched keys are skipped on the wire, so peak memory is the constructed `T`
plus the deserializer's small working buffers regardless of payload size. This
is the counterpart of the buffer-based `deser_beve(T, ::Vector{UInt8})` for data
that should never be held in RAM in its entirety (sockets, pipes, large files).

The stream must block (not report EOF) while more bytes are still in flight;
`IO` types like `Base.PipeEndpoint`/`Base.BufferStream` already behave this way.
"""
function deser_beve(::Type{T}, io::IO;
                    error_on_missing_fields::Bool = false,
                    preserve_matrices::Bool = false) where {T}
    deser = BeveDeserializer(io; preserve_matrices = preserve_matrices)
    style = BeveStyle(error_on_missing_fields)

    # Mirror the buffer path's top-level rejection of an integer-keyed map being
    # forced into a non-dictionary type, decided from the header alone (no
    # materialization). Nested occurrences are handled uniformly by the recursion
    # below, matching `make`'s positional handling, exactly as the buffer path.
    header = peek_byte!(deser)
    if _is_int_object_header(header) && !(T <: AbstractDict) && T !== Any
        throw(BeveError("Cannot convert integer-keyed dictionary to type $T"))
    end

    return stream_make(style, T, deser)
end

# Decode exactly one BEVE value from `deser` into type `T`. `tags` carries the
# StructUtils field tags for the field being decoded (empty at the top level).
function stream_make(style::BeveStyle, ::Type{T}, deser::BeveDeserializer, tags = (;)) where {T}
    T === Any && return parse_value(deser)

    header = peek_byte!(deser)

    # Null short-circuit for nullable unions, decided without consuming non-null
    # values (so we never materialize a present value just to test for null).
    # `Missing` is tested before `Nothing` to match the resolution order of the
    # buffer path's `StructUtils.make` (which checks `T >: Missing` first), so a
    # `Union{Nothing, Missing, X}` field resolves a wire null to `missing`
    # identically on both paths.
    if header == NULL
        if Missing <: T
            read_byte!(deser)
            return missing
        elseif Nothing <: T
            read_byte!(deser)
            return nothing
        end
    end

    if _can_stream(style, T, header, tags)
        return _stream_into(style, T, deser, header)
    end

    # Leaf, type mismatch, or lookahead-needing target: materialize this single
    # value (bounded by the subtree) and run the normal make/lift pipeline.
    val = parse_value(deser)
    return _make_from_value(style, T, val, tags)
end

@inline function _make_from_value(style::BeveStyle, ::Type{T}, val, tags) where {T}
    # Preserve the buffer path's direct passthrough of a preserved matrix.
    if val isa BEVE.BeveMatrix && T <: BEVE.BeveMatrix
        return val
    end
    result, _ = isempty(tags) ? StructUtils.make(style, T, val) :
                                StructUtils.make(style, T, val, tags)
    return result
end

function _stream_into(style::BeveStyle, ::Type{T}, deser::BeveDeserializer, header::UInt8) where {T}
    if _is_object_header(header)
        return _stream_object(style, T, deser, header)
    else  # GENERIC_ARRAY into a 1-D array / set
        return _stream_array(style, T, deser)
    end
end

# ─── Streaming objects → structs / dicts / @noarg structs ─────────────────────

function _stream_object(style::BeveStyle, ::Type{T}, deser::BeveDeserializer, header::UInt8) where {T}
    StructUtils.dictlike(style, T) && return _stream_dict(style, T, deser, header)

    read_byte!(deser)               # consume the (peeked) object header
    n = read_size(deser)
    fstrs = StructUtils.fieldnamestrings(T)

    if StructUtils.noarg(style, T)
        # @noarg types are constructed empty then mutated field-by-field.
        obj = StructUtils.initialize(style, T, nothing)
        for _ in 1:n
            key = _read_object_key(deser, header)
            idx = _find_field_index(style, T, key, fstrs)
            if idx === nothing
                skip_value!(deser)
            else
                ftags = StructUtils.fieldtags(style, T, fieldname(T, idx))
                StructUtils._setfield!(obj, idx, stream_make(style, fieldtype(T, idx), deser, ftags))
            end
        end
        return obj
    end

    fsyms = StructUtils.fieldnamesymbols(T)
    vals = StructUtils.mem(fieldcount(T))
    for _ in 1:n
        key = _read_object_key(deser, header)
        idx = _find_field_index(style, T, key, fstrs)
        if idx === nothing
            skip_value!(deser)
        else
            ftags = StructUtils.fieldtags(style, T, fsyms[idx])
            @inbounds vals[idx] = stream_make(style, fieldtype(T, idx), deser, ftags)
        end
    end
    return _beve_finish_struct(style, T, vals, fsyms)
end

@inline function _read_object_key(deser::BeveDeserializer, header::UInt8)
    if header == STRING_OBJECT
        return read_string_data(deser)
    else
        K = _object_key_type(header)
        return (K === Int8 || K === UInt8) ? read(deser.io, K) : ltoh(read(deser.io, K))
    end
end

# Resolve a BEVE object key to a field index of `T`, honoring `:name` field tags.
# Mirrors the matching in `StructUtils.findfield` for string and integer keys.
@inline function _find_field_index(style::BeveStyle, ::Type{T}, key, fstrs) where {T}
    if key isa Integer
        k = Int(key)
        return (1 <= k <= fieldcount(T)) ? k : nothing
    end
    for i in 1:fieldcount(T)
        ftags = StructUtils.fieldtags(style, T, fieldname(T, i))
        field = get(ftags, :name, @inbounds fstrs[i])
        StructUtils.keyeq(key, field) && return i
    end
    return nothing
end

# Build a dictionary by decoding each value straight into the dict's value type
# and lifting each key into its key type, via the same `initialize` /
# `addkeyval!` / `liftkey` path StructUtils uses for a *nested* dict field. This
# makes a top-level dict target behave identically to a nested one. It differs
# from the buffer path's `deser_beve(T, ::Vector{UInt8})` only for top-level dict
# targets, where that path takes an explicit `convert(T, parsed)` shortcut: an
# unparameterized `Dict` target therefore yields `Dict{Any,Any}` here (like a
# nested dict) rather than the buffer path's `Dict{String,Any}`, and a
# `Dict{Symbol,V}` target lifts string keys to symbols rather than erroring on
# `convert`. Concrete `Dict{K,V}` targets produce identical results on both paths.
function _stream_dict(style::BeveStyle, ::Type{T}, deser::BeveDeserializer, header::UInt8) where {T}
    read_byte!(deser)
    n = read_size(deser)
    dict = StructUtils.initialize(style, T, nothing)
    VT = valtype(dict)
    KT = keytype(dict)
    for _ in 1:n
        rawkey = _read_object_key(deser, header)
        val = stream_make(style, VT, deser)
        StructUtils.addkeyval!(dict, StructUtils.liftkey(style, KT, rawkey), val)
    end
    return dict
end

# ─── Streaming generic arrays → 1-D arrays / sets ─────────────────────────────

function _stream_array(style::BeveStyle, ::Type{T}, deser::BeveDeserializer) where {T}
    read_byte!(deser)               # consume the (peeked) GENERIC_ARRAY header
    n = read_size(deser)
    arr = StructUtils.initialize(style, T, nothing)
    ET = eltype(arr)
    for _ in 1:n
        push!(arr, stream_make(style, ET, deser))
    end
    return arr
end
