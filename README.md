# BeveFormat.jl

BEVE serialization and deserialization library for Julia. BEVE (Binary Efficient Versatile Encoding) provides fast and compact serialization of Julia data structures including primitives, collections, and custom structs.

## Installation

BeveFormat.jl implements the [BEVE](https://github.com/beve-org/beve) binary format. Add it to your Julia project:

```julia
using Pkg
Pkg.add("BeveFormat")
```

## Usage

Import the library:

```julia
using BeveFormat
```

## Basic Usage

### File Helpers

Use `write_beve_file(path, data)` to serialize Julia objects directly to disk.
The serializer writes straight to the file descriptor with no intermediate
copies. `read_beve_file(path; preserve_matrices)` and
`deser_beve_file(T, path; kwargs...)` stream the file through the deserializer,
so the whole file is never held in a contiguous buffer in addition to the
decoded value (see [Streaming from an `IO`](#streaming-from-an-io)).

```julia
sample = Dict("message" => "hello", "values" => [1, 2, 3])
write_beve_file("sample.beve", sample)

matrix = Float32[1 2; 3 4]
write_beve_file("matrix.beve", matrix)

read_beve_file("sample.beve")                  # -> Dict
read_beve_file("matrix.beve"; preserve_matrices = true)  # -> BeveMatrix wrapper
deser_beve_file(Matrix{Float32}, "matrix.beve")  # -> Matrix{Float32}
```

### Serialization and Deserialization

```julia
# Serialize data to BEVE format
data = "Hello, World!"
beve_data = to_beve(data)

# Deserialize back to Julia objects
result = from_beve(beve_data)
println(result) # "Hello, World!"
```

### Streaming from an `IO`

`from_beve` and `deser_beve` also accept an `IO`, decoding a value directly from
a stream without first materializing the input into a buffer. The typed form,
`deser_beve(T, io)`, decodes straight into `T`: object fields are written into
their struct slots as they arrive and unmatched keys are skipped on the wire, so
it never builds the intermediate generic `Dict`/`Vector` tree that the
buffer-based path constructs. Peak memory is the constructed `T` plus small
working buffers, independent of payload size, which makes it suitable for large
files, sockets, and pipes.

```julia
open("collection.beve") do io
    result = deser_beve(Collection, io)   # decodes into Collection, never the whole file
end

# Generic streaming decode
open("collection.beve") do io
    tree = from_beve(io)                  # -> Dict/Vector tree, pulled incrementally
end
```

`deser_beve_file(T, path)` and `read_beve_file(path)` are thin wrappers that open
the file and stream it through these entry points. The stream must block (not
report EOF) while more bytes are still in flight; standard blocking `IO` types
such as `Base.PipeEndpoint` and `Base.BufferStream` already behave this way, so a
value delivered in bursts decodes correctly.

### Supported Types

BeveFormat.jl supports all basic Julia types:

```julia
# Basic types
to_beve(nothing)           # null
to_beve(true)             # boolean
to_beve(42)               # integers (Int8, Int16, Int32, Int64)
to_beve(UInt8(255))       # unsigned integers
to_beve(3.14)             # floats (Float32, Float64)
to_beve("text")           # strings

# Arrays
to_beve([1, 2, 3, 4])                    # numeric arrays
to_beve(["hello", "world"])              # string arrays
to_beve([true, false, true])             # boolean arrays
to_beve([1, "hello", true, 3.14])        # mixed arrays

# Dictionaries
to_beve(Dict("name" => "Alice", "age" => 30))
```

### Enums

Julia enums are serialized as their string representation for robustness:

```julia
@enum Color red green blue

# Serialize enum value
beve_data = to_beve(red)
from_beve(beve_data)  # "red" (string)

# Enums in structs are automatically handled
struct Pixel
    x::Int
    y::Int
    color::Color
end

pixel = Pixel(10, 20, blue)
beve_data = to_beve(pixel)

# Deserialize back to struct with enum field
reconstructed = deser_beve(Pixel, beve_data)
reconstructed.color  # blue::Color
```

Serializing as strings rather than integers ensures compatibility even if enum values are reordered.

### Working with Custom Structs

BeveFormat.jl can serialize and deserialize custom Julia structs:

```julia
# Define a struct
struct Person
    name::String
    age::Int
end

# Create and serialize
person = Person("Alice", 30)
beve_data = to_beve(person)

# Deserialize as generic data
parsed = from_beve(beve_data)
println(parsed["name"])  # "Alice"
println(parsed["age"])   # 30

# Deserialize back to original struct type
reconstructed = deser_beve(Person, beve_data)
println(reconstructed.name)  # "Alice"
println(reconstructed.age)   # 30
```

#### Skipping Struct Fields

Exclude fields from serialization either declaratively with `@skip` or dynamically with `skip(::Type, ::Val, value)`:

```julia
struct Credentials
    username::String
    password::String
    token::Union{String, Nothing}
    session_id::String
end

# Skip password and session_id for every serialization
BeveFormat.@skip Credentials password session_id

# Skip token only when it is `nothing`
BeveFormat.skip(::Type{Credentials}, ::Val{:token}, value) = value === nothing

data = Credentials("alice", "secret", nothing, "sess-42")
parsed = from_beve(to_beve(data))

@assert keys(parsed) == ["username"]

# Reconstructing with skipped fields
deser_beve(Credentials, to_beve(data))

# Enforce strict field presence
deser_beve(Credentials, to_beve(data); error_on_missing_fields = true)
```

By default `deser_beve` allows reconstruction even when fields were skipped in the serialized input, making it easy to rely on struct defaults. Set `error_on_missing_fields = true` to throw a `BeveError` whenever a field is absent.

### Complex Nested Structures

BeveFormat.jl handles deeply nested data structures:

```julia
struct Address
    street::String
    city::String
    zipcode::String
end

struct Employee
    name::String
    age::Int
    salary::Float64
    address::Address
    active::Bool
end

# Create nested data
address = Address("123 Main St", "New York", "10001")
employee = Employee("John Doe", 30, 75000.0, address, true)

# Serialize and deserialize
beve_data = to_beve(employee)
reconstructed = deser_beve(Employee, beve_data)

println(reconstructed.name)                    # "John Doe"
println(reconstructed.address.street)          # "123 Main St"
```

### Arrays of Structs

```julia
struct Product
    id::Int
    name::String
    price::Float64
    in_stock::Bool
end

products = [
    Product(1, "Laptop", 999.99, true),
    Product(2, "Mouse", 25.50, false),
    Product(3, "Keyboard", 75.00, true)
]

# Serialize array of structs
beve_data = to_beve(products)
parsed = from_beve(beve_data)

# Access individual products
println(parsed[1]["name"])    # "Laptop"
println(parsed[2]["price"])   # 25.50
```

### Matrices

Julia `AbstractMatrix` and `Matrix{T}` values automatically use the BEVE matrix extension:

```julia
mat = Float32[1 2 3; 4 5 6]
bytes = to_beve(mat)

parsed = from_beve(bytes)                    # Matrix{Float32}
raw = from_beve(bytes; preserve_matrices = true)  # BeveMatrix wrapper with layout/extents/data
```

Matrix fields inside structs are also reconstructed when using `deser_beve`:

```julia
struct Grid
    values::Matrix{Float64}
end

grid = Grid([1.0 2.0; 3.0 4.0])
roundtrip = deser_beve(Grid, to_beve(grid))
@assert roundtrip.values == grid.values
```

### Optional and Union Fields

BeveFormat.jl supports optional fields and Union types:

```julia
struct OptionalData
    required_field::String
    optional_number::Union{Int, Nothing}
    optional_string::Union{String, Nothing}
end

# With values present
data1 = OptionalData("required", 42, "optional")
beve_data1 = to_beve(data1)
result1 = from_beve(beve_data1)

# With nothing values
data2 = OptionalData("required", nothing, nothing)
beve_data2 = to_beve(data2)
result2 = from_beve(beve_data2)
```

### Custom Type Selection with `StructUtils.@choosetype`

For abstract types or complex Union types, use `StructUtils.@choosetype` to control how BEVE selects the concrete type during deserialization. This works with both BEVE and JSON.jl:

```julia
using StructUtils
using BeveFormat

abstract type Message end

struct TextMessage <: Message
    content::String
end

struct ImageMessage <: Message
    url::String
    width::Int
    height::Int
end

# Define type selection based on source data
StructUtils.@choosetype(Message, x -> haskey(x, "url") ? ImageMessage : TextMessage)

struct MessageHolder
    message::Message
end

# Deserialize with automatic type selection
text_data = Dict("message" => Dict("content" => "Hello"))
holder = deser_beve(MessageHolder, to_beve(text_data))
# holder.message is a TextMessage

img_data = Dict("message" => Dict("url" => "http://example.com/img.png", "width" => 800, "height" => 600))
holder2 = deser_beve(MessageHolder, to_beve(img_data))
# holder2.message is an ImageMessage
```

You can also use `@choosetype` with Union types:

```julia
struct TypeA
    a_field::Int
end

struct TypeB
    b_field::String
end

StructUtils.@choosetype(Union{TypeA, TypeB}, x -> haskey(x, "a_field") ? TypeA : TypeB)

struct Container
    item::Union{TypeA, TypeB}
end

data = Dict("item" => Dict("a_field" => 42))
container = deser_beve(Container, to_beve(data))
# container.item is a TypeA with a_field == 42
```

## API Reference

### Main Functions

- `to_beve(data)` - Serialize Julia data to BEVE format
- `from_beve(beve_data)` / `from_beve(io)` - Deserialize BEVE data (a buffer or a stream) to Julia objects (as dictionaries for structs)
- `deser_beve(Type, beve_data)` / `deser_beve(Type, io)` - Deserialize BEVE data (a buffer or a stream) back to a specific struct type; the `IO` form streams directly into `Type` without building the intermediate generic tree
- `StructUtils.@choosetype(Type, func)` - Define concrete type selection for abstract/Union types

## Running Tests

To run the test suite:

```bash
julia --project=. -e "import Pkg; Pkg.test()"
```

## Optional Zstandard Compression

BeveFormat ships an optional extension that wraps [CodecZstd.jl](https://github.com/JuliaIO/CodecZstd.jl) so you can read and write `.beve.zst` files. The helpers are no-ops unless `CodecZstd` is available; install it explicitly when you want compressed output:

```julia
using Pkg
Pkg.add("CodecZstd")  # add only when you need compression
```

Once `CodecZstd` is in the environment, the extension activates automatically and provides these helpers:

- `to_beve_zstd(data; buffer=nothing, level=3)` – compress the result of `to_beve`.
- `from_beve_zstd(bytes; preserve_matrices=false)` and `from_beve_zstd(io; preserve_matrices=false)` – decompress then call `from_beve`; the `IO` form decompresses and deserializes on the fly so neither the compressed nor the decompressed bytes are held in full.
- `write_beve_zstd_file(path, data; level=3)` – stream-compress and write `.beve.zst` files directly (no intermediate buffer).
- `read_beve_zstd_file(path; preserve_matrices=false)` – read `.beve.zst` files (streamed through the decompressor).
- `deser_beve_zstd(::Type{T}, bytes; kwargs...)`, `deser_beve_zstd(::Type{T}, io; kwargs...)`, and `deser_beve_zstd_file(::Type{T}, path; kwargs...)` mirror their uncompressed counterparts when you want structs back directly. The `IO` and file forms combine streaming decompression with the streaming typed decode, so peak memory is the constructed `T` plus working buffers.

The `to_beve_zstd` helper reuses any `IOBuffer` you pass via `buffer` to avoid reallocations. `write_beve_zstd_file` streams serialization directly through Zstd compression to the file, avoiding large intermediate buffers. Files should use the `.beve.zst` suffix so tools can recognize the codec.

Example:

```julia
using BeveFormat
using CodecZstd  # activates the extension

sample = Dict("message" => "hello")
compressed = to_beve_zstd(sample, level = 5)
@assert from_beve_zstd(compressed) == sample

struct Person
    name::String
    age::Int
end

person = Person("Ada", 37)
bytes = to_beve_zstd(person)
@assert deser_beve_zstd(Person, bytes) == person

write_beve_zstd_file("person.beve.zst", person)
@assert deser_beve_zstd_file(Person, "person.beve.zst") == person
```

## Optional HTTP Support

BeveFormat.jl includes optional HTTP server and client functionality through a package extension. HTTP.jl is now an optional dependency - you only need it if you want to use HTTP features.

### Enabling HTTP Features

HTTP functionality is provided through a Julia package extension (available since Julia 1.9). To use HTTP features, simply load HTTP.jl:

```julia
using BeveFormat
using HTTP  # This automatically loads the HTTP extension

# Now HTTP functions are available
```

Without HTTP.jl, core BEVE serialization works normally, but HTTP functions will not be available.

### HTTP Server

Once HTTP.jl is loaded, you can register struct instances at HTTP paths and serve them:

```julia
using BeveFormat
using HTTP  # Required for HTTP functionality

# Define your structs
struct Employee
    id::Int
    name::String
    email::String
    active::Bool
end

struct Company
    name::String
    employees::Vector{Employee}
    founded::Int
end

# Create data
employees = [
    Employee(1, "Alice", "alice@company.com", true),
    Employee(2, "Bob", "bob@company.com", false)
]
company = Company("ACME Corp", employees, 2020)

# Register objects at HTTP paths
register_object("/api/company", company)

# Start HTTP server
server = start_server("127.0.0.1", 8080)
```

The server supports JSON pointer syntax for accessing nested data:

- `GET /api/company` - Returns entire company object
- `GET /api/company?pointer=/name` - Returns just the company name
- `GET /api/company?pointer=/employees` - Returns the employees array
- `GET /api/company?pointer=/employees/0` - Returns first employee
- `GET /api/company?pointer=/employees/0/name` - Returns first employee's name

### HTTP Client

Make requests to BEVE HTTP servers:

```julia
using BeveFormat
using HTTP  # Required for HTTP functionality

# Create client
client = BeveHttpClient("http://localhost:8080")

# Get entire company and deserialize to struct
company = get(client, "/api/company", as_type=Company)

# Get specific fields using JSON pointers
company_name = get(client, "/api/company", json_pointer="/name")
employees = get(client, "/api/company", json_pointer="/employees")
first_employee = get(client, "/api/company", json_pointer="/employees/0", as_type=Employee)

# Update data via POST
post(client, "/api/company", "New Company Name", json_pointer="/name")
```

### JSON Pointer Support

JSON pointers follow RFC 6901 standard:

- `/` - Root object
- `/field` - Access field named "field"
- `/array/0` - Access first element of array
- `/nested/field/value` - Access nested fields
- Special characters: `~0` for `~`, `~1` for `/`

### API Reference

#### Server Functions (requires HTTP.jl)

- `register_object(path::String, obj)` - Register an object at the given HTTP path
- `unregister_object(path::String)` - Remove an object from the given path
- `start_server(host::String, port::Int)` - Start HTTP server

#### Client Functions (requires HTTP.jl)

- `BeveHttpClient(base_url::String; headers::Dict)` - Create HTTP client
- `get(client::BeveHttpClient, path::String; json_pointer::String, as_type::Type)` - GET request
- `post(client::BeveHttpClient, path::String, data; json_pointer::String)` - POST request

## Compatibility

- Julia 1.9+ (required for package extensions)
- HTTP.jl (optional, only needed for HTTP functionality)
