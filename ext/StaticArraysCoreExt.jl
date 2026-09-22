module StaticArraysCoreExt

using BEVE
using BEVE: BeveSerializer, BeveStyle
import BEVE: beve_value!
using StaticArraysCore: StaticArray
using StructUtils

# Serialize StaticArrays as typed arrays (like Vector), not as objects.
# Without this, the catch-all struct serializer sees fieldnames(MVector) == (:data,)
# and serializes as {"data": [...]}.
function beve_value!(ser::BeveSerializer, val::StaticArray)
    beve_value!(ser, collect(val))
end

# Deserialize: construct StaticArray from a Vector source.
# StructUtils.makearray can't initialize StaticArrays with (undef, length).
function StructUtils.make(style::BeveStyle, ::Type{T}, source::AbstractVector) where {T<:StaticArray}
    ET = eltype(T)
    typed = ET[convert(ET, x) for x in source]
    return convert(T, typed), StructUtils.defaultstate(style)
end

end # module
