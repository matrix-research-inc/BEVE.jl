using Test
using BEVE
using StructUtils

@testset "BEVE.jl" begin
    @testset "File Helpers" begin
        sample = Dict("message" => "hello", "values" => [1, 2, 3])
        struct FilePerson
            name::String
            age::Int
        end

        struct MissingField
            a::Int
            b::Int
        end

        mktempdir() do tmp
            path = joinpath(tmp, "sample.beve")

            write_beve_file(path, sample)
            @test read(path) == to_beve(sample)
            @test read_beve_file(path) == sample

            matrix = Float32[1 2; 3 4]
            matrix_path = joinpath(tmp, "matrix.beve")
            write_beve_file(matrix_path, matrix)
            @test read(matrix_path) == to_beve(matrix)
            @test read_beve_file(matrix_path) == matrix

            preserved = read_beve_file(matrix_path; preserve_matrices = true)
            @test preserved isa BEVE.BeveMatrix{Float32}
            @test preserved.layout == BEVE.LayoutLeft
            @test preserved.extents == [2, 2]
            @test preserved.data == vec(matrix)

            person = FilePerson("Ada", 37)
            person_path = joinpath(tmp, "person.beve")
            write_beve_file(person_path, person)
            @test deser_beve_file(FilePerson, person_path) == person

            matrix_raw = deser_beve_file(BEVE.BeveMatrix{Float32}, matrix_path; preserve_matrices = true)
            @test matrix_raw isa BEVE.BeveMatrix{Float32}
            @test matrix_raw.layout == preserved.layout
            @test matrix_raw.extents == preserved.extents
            @test matrix_raw.data == preserved.data

            dict_path = joinpath(tmp, "missing.beve")
            write(dict_path, to_beve(Dict("a" => 1)))
            @test_throws BEVE.BeveError deser_beve_file(MissingField, dict_path; error_on_missing_fields = true)
    end
    end

    @testset "Tuple Serialization" begin
        float_tuple = (1.5, 2.5)
        tuple_bytes = to_beve(float_tuple)
        @test from_beve(tuple_bytes) == Any[1.5, 2.5]
        @test deser_beve(Tuple{Float64, Float64}, tuple_bytes) == float_tuple

        struct TupleWrapper
            coords::Tuple{Float64, Float64}
            label::String
        end

        wrapped = TupleWrapper((3.0, 4.0), "pos")
        roundtrip = deser_beve(TupleWrapper, to_beve(wrapped))
        @test roundtrip.label == wrapped.label
        @test roundtrip.coords == wrapped.coords

        struct NTupleHolder
            data::NTuple{2, Float64}
        end

        holder = NTupleHolder((7.0, 9.0))
        parsed_holder = deser_beve(NTupleHolder, to_beve(holder))
        @test parsed_holder.data == holder.data

        named_tuple = (x = 11.0, y = 13.0)
        named_bytes = to_beve(named_tuple)
        @test from_beve(named_bytes) == Dict("x" => 11.0, "y" => 13.0)
        @test deser_beve(NamedTuple{(:x, :y), Tuple{Float64, Float64}}, named_bytes) == named_tuple

        struct NamedTupleHolder
            point::NamedTuple{(:x, :y), Tuple{Float64, Float64}}
        end

        holder = NamedTupleHolder((x = 2.0, y = 5.0))
        @test deser_beve(NamedTupleHolder, to_beve(holder)) == holder
    end

    @testset "Zstd Helpers" begin
        codec_available = try
            Base.require(Base.PkgId(Base.UUID("6b39b394-51ab-5f42-8807-6242bab2b4c2"), "CodecZstd"))
            true
        catch err
            @info "Skipping Zstd tests: CodecZstd not available" exception = err
            false
        end

        if codec_available
            sample = Dict("message" => "hello", "values" => [1, 2, 3])
            compressed = to_beve_zstd(sample)
            @test from_beve_zstd(compressed) == sample

            matrix = Float32[1 2; 3 4]
            buffer = IOBuffer()
            compressed_matrix = to_beve_zstd(matrix; buffer = buffer, level = 7)
            restored = from_beve_zstd(compressed_matrix; preserve_matrices = true)
            @test restored isa BEVE.BeveMatrix{Float32}
            @test restored.layout == BEVE.LayoutLeft
            @test restored.extents == [2, 2]
            @test restored.data == vec(matrix)

            struct ZstdPerson
                name::String
                age::Int
            end

            person = ZstdPerson("Ada", 37)
            person_bytes = to_beve_zstd(person)
            @test deser_beve_zstd(ZstdPerson, person_bytes) == person

            mktempdir() do tmp
                path = joinpath(tmp, "sample.beve.zst")
                write_beve_zstd_file(path, sample)
                @test endswith(path, ".beve.zst")
                @test read_beve_zstd_file(path) == sample

                matrix_path = joinpath(tmp, "matrix.beve.zst")
                write_beve_zstd_file(matrix_path, matrix)
                matrix_restored = read_beve_zstd_file(matrix_path; preserve_matrices = true)
                @test matrix_restored.layout == restored.layout
                @test matrix_restored.data == restored.data

                person_path = joinpath(tmp, "person.beve.zst")
                write_beve_zstd_file(person_path, person)
                @test deser_beve_zstd_file(ZstdPerson, person_path) == person
                @test deser_beve_zstd_file(BEVE.BeveMatrix{Float32}, matrix_path;
                                           preserve_matrices = true).data == restored.data
            end
        end
    end

    @testset "Basic Types" begin
        # Test null
        data = to_beve(nothing)
        @test from_beve(data) === nothing
        
        # Test booleans
        @test from_beve(to_beve(true)) === true
        @test from_beve(to_beve(false)) === false
        
        # Test integers
        @test from_beve(to_beve(Int8(42))) === Int8(42)
        @test from_beve(to_beve(Int16(1000))) === Int16(1000)
        @test from_beve(to_beve(Int32(100000))) === Int32(100000)
        @test from_beve(to_beve(Int64(1000000000))) === Int64(1000000000)
        
        # Test unsigned integers
        @test from_beve(to_beve(UInt8(255))) === UInt8(255)
        @test from_beve(to_beve(UInt16(65535))) === UInt16(65535)
        @test from_beve(to_beve(UInt32(4294967295))) === UInt32(4294967295)
        
        # Test floats
        @test from_beve(to_beve(Float32(3.14))) ≈ Float32(3.14)
        @test from_beve(to_beve(Float64(3.14159))) ≈ Float64(3.14159)
        
        # Test strings
        @test from_beve(to_beve("Hello, World!")) == "Hello, World!"
        @test from_beve(to_beve("")) == ""
    end
    
    @testset "Arrays" begin
        # Test boolean arrays
        bool_array = [true, false, true, false]
        @test from_beve(to_beve(bool_array)) == bool_array
        
        # Test string arrays
        str_array = ["hello", "world", "test"]
        @test from_beve(to_beve(str_array)) == str_array
        
        # Test numeric arrays
        int_array = Int32[1, 2, 3, 4, 5]
        @test from_beve(to_beve(int_array)) == int_array
        
        float_array = Float64[1.1, 2.2, 3.3]
        @test from_beve(to_beve(float_array)) ≈ float_array
        
        # Test generic arrays
        generic_array = Any[1, "hello", true, 3.14]
        result = from_beve(to_beve(generic_array))
        @test length(result) == length(generic_array)
        @test result[1] == 1
        @test result[2] == "hello" 
        @test result[3] == true
        @test result[4] ≈ 3.14
    end

    @testset "Matrices" begin
        @testset "Column-major defaults" begin
            matrix = Float32[1 2 3; 4 5 6]
            bytes = to_beve(matrix)
            parsed = from_beve(bytes)
            @test parsed isa Matrix{Float32}
            @test parsed == matrix

            raw = from_beve(bytes; preserve_matrices = true)
            @test raw isa BEVE.BeveMatrix
            @test raw.layout == BEVE.LayoutLeft
            @test raw.extents == [2, 3]
            @test raw.data == vec(matrix)

            raw_again = deser_beve(BEVE.BeveMatrix{Float32}, bytes; preserve_matrices = true)
            @test raw_again isa BEVE.BeveMatrix{Float32}
            @test raw_again.data == vec(matrix)
        end

        @testset "Numeric element types" begin
            int_matrix = reshape(Int32(1):Int32(6), 2, 3)
            @test from_beve(to_beve(int_matrix)) == int_matrix

            uint_matrix = reshape(UInt16(1):UInt16(9), 3, 3)
            parsed_uint = from_beve(to_beve(uint_matrix))
            @test parsed_uint isa Matrix{UInt16}
            @test parsed_uint == uint_matrix

            float_matrix = reshape(Float64(1):Float64(9), 3, 3)
            @test from_beve(to_beve(float_matrix)) == float_matrix
        end

        @testset "Row-major roundtrip" begin
            expected = Float64[1 2 3; 4 5 6]
            row_major = BEVE.BeveMatrix(BEVE.LayoutRight, [2, 3], Float64[1, 2, 3, 4, 5, 6])
            parsed_row = from_beve(to_beve(row_major))
            @test parsed_row isa Matrix{Float64}
            @test parsed_row == expected
        end

        @testset "Complex matrices" begin
            complex_matrix = ComplexF64[ComplexF64(i, -i) for i in 1:6]
            complex_matrix = reshape(complex_matrix, 2, 3)
            parsed_complex = from_beve(to_beve(complex_matrix))
            @test parsed_complex isa Matrix{ComplexF64}
            @test parsed_complex == complex_matrix

            raw_complex = from_beve(to_beve(complex_matrix); preserve_matrices = true)
            @test raw_complex isa BEVE.BeveMatrix{ComplexF64}
            @test raw_complex.data == vec(complex_matrix)
        end

        @testset "Strided and view matrices" begin
            base = reshape(Float32.(1:12), 3, 4)
            view_matrix = @view base[:, 1:2:4]
            parsed_view = from_beve(to_beve(view_matrix))
            @test parsed_view isa Matrix{Float32}
            @test parsed_view == Matrix(view_matrix)

            permuted = permutedims(base)
            parsed_permuted = from_beve(to_beve(permuted))
            @test parsed_permuted == Matrix(permuted)
        end

        @testset "Struct reconstruction" begin
            struct MatrixHolder
                weights::Matrix{Float64}
                grads::Matrix{Float32}
            end

            holder = MatrixHolder([1.0 2.0; 3.0 4.0], Float32[0.1 0.2; 0.3 0.4])
            roundtrip_holder = deser_beve(MatrixHolder, to_beve(holder))
            @test roundtrip_holder.weights == holder.weights
            @test roundtrip_holder.grads == holder.grads

            struct NestedContainer
                items::Vector{Matrix{Float32}}
                stats::Dict{String, Matrix{Int}}
            end

            nested = NestedContainer(
                [Float32[1 2; 3 4], Float32[5 6; 7 8]],
                Dict("ones" => ones(Int, 2, 2), "identity" => [1 0; 0 1])
            )

            parsed_nested = deser_beve(NestedContainer, to_beve(nested))
            @test parsed_nested.items == nested.items
            @test parsed_nested.stats == nested.stats
        end

        @testset "Higher-dimensional remains raw" begin
            tensor = BEVE.BeveMatrix(BEVE.LayoutLeft, [2, 2, 2], Float32[1, 2, 3, 4, 5, 6, 7, 8])
            parsed_tensor = from_beve(to_beve(tensor))
            @test parsed_tensor isa BEVE.BeveMatrix
            @test parsed_tensor.extents == [2, 2, 2]
        end
    end

    @testset "SubArray Support" begin
        int_data = collect(1:6)
        int_view = @view int_data[2:5]
        @test from_beve(to_beve(int_view)) == collect(int_view)

        bool_data = Bool[true, false, true, true, false, false]
        bool_view = @view bool_data[1:4]
        @test from_beve(to_beve(bool_view)) == collect(bool_view)

        str_data = ["alpha", "beta", "gamma", "delta"]
        str_view = @view str_data[2:4]
        @test from_beve(to_beve(str_view)) == collect(str_view)
    end

    @testset "Struct With SubArray" begin
        struct SubArrayHolder
            label::String
            slice::SubArray{Int, 1, Vector{Int}, Tuple{UnitRange{Int}}, true}
        end

        base_data = collect(10:20)
        data_view = @view base_data[3:8]
        holder = SubArrayHolder("numbers", data_view)

        roundtrip = from_beve(to_beve(holder))
        @test roundtrip["label"] == "numbers"
        @test roundtrip["slice"] == collect(data_view)
    end

    @testset "Objects" begin
        # Test dictionary
        dict = Dict("name" => "Alice", "age" => 30, "active" => true)
        result = from_beve(to_beve(dict))
        @test result["name"] == "Alice"
        @test result["age"] == 30
        @test result["active"] == true
    end
    
    @testset "Structs" begin
        struct Person
            name::String
            age::Int
        end
        
        person = Person("Bob", 25)
        beve_data = to_beve(person)
        parsed = from_beve(beve_data)
        
        @test parsed isa Dict{String, Any}
        @test parsed["name"] == "Bob"
        @test parsed["age"] == 25
        
        # Test reconstruction
        reconstructed = deser_beve(Person, beve_data)
        @test reconstructed.name == person.name
        @test reconstructed.age == person.age
    end

    @testset "Struct Field Skipping" begin
        Base.@kwdef struct Credentials
            username::String
            password::String = ""
            token::Union{String, Nothing} = nothing
        end

        BEVE.@skip Credentials password

        function BEVE.skip(::Type{Credentials}, ::Val{:token}, value)
            return value === nothing
        end

        credentials = Credentials("alice", "secret", "abc123")
        parsed_credentials = from_beve(to_beve(credentials))

        @test parsed_credentials isa Dict{String, Any}
        @test parsed_credentials["username"] == "alice"
        @test !haskey(parsed_credentials, "password")
        @test parsed_credentials["token"] == "abc123"

        beve_credentials = to_beve(credentials)
        reconstructed_credentials = deser_beve(Credentials, beve_credentials)
        @test reconstructed_credentials.username == "alice"
        @test reconstructed_credentials.password == ""
        @test reconstructed_credentials.token == "abc123"

        @test_throws BEVE.BeveError deser_beve(Credentials, beve_credentials; error_on_missing_fields = true)

        credentials_without_token = Credentials("bob", "hidden", nothing)
        parsed_without_token = from_beve(to_beve(credentials_without_token))

        @test parsed_without_token isa Dict{String, Any}
        @test parsed_without_token["username"] == "bob"
        @test !haskey(parsed_without_token, "password")
        @test !haskey(parsed_without_token, "token")
        @test length(parsed_without_token) == 1

        beve_without_token = to_beve(credentials_without_token)
        roundtrip_without_token = deser_beve(Credentials, beve_without_token)
        @test roundtrip_without_token.username == "bob"
        @test roundtrip_without_token.password == ""
        @test roundtrip_without_token.token === nothing
        @test_throws BEVE.BeveError deser_beve(Credentials, beve_without_token; error_on_missing_fields = true)
    end

    @testset "Multiple Field Skipping" begin
        Base.@kwdef struct Secrets
            public_id::Int
            api_key::String = ""
            private_notes::String = ""
            created_at::String
        end

        BEVE.@skip Secrets api_key private_notes

        secrets = Secrets(101, "API-XYZ", "internal", "2024-01-01")
        parsed_secrets = from_beve(to_beve(secrets))

        @test parsed_secrets isa Dict{String, Any}
        @test parsed_secrets["public_id"] == 101
        @test parsed_secrets["created_at"] == "2024-01-01"
        @test !haskey(parsed_secrets, "api_key")
        @test !haskey(parsed_secrets, "private_notes")
        @test length(parsed_secrets) == 2

        beve_secrets = to_beve(secrets)
        reconstructed_secrets = deser_beve(Secrets, beve_secrets)
        @test reconstructed_secrets.public_id == 101
        @test reconstructed_secrets.api_key == ""
        @test reconstructed_secrets.private_notes == ""
        @test reconstructed_secrets.created_at == "2024-01-01"
        @test_throws BEVE.BeveError deser_beve(Secrets, beve_secrets; error_on_missing_fields = true)
    end
    
    @testset "Complex Nested Structs" begin
        # Define nested struct types
        struct Address
            street::String
            city::String
            zipcode::String
        end
        
        struct Contact
            email::String
            phone::String
        end
        
        struct Employee
            name::String
            age::Int
            salary::Float64
            address::Address
            contact::Contact
            active::Bool
        end
        
        # Create nested data
        address = Address("123 Main St", "New York", "10001")
        contact = Contact("john@example.com", "555-1234")
        employee = Employee("John Doe", 30, 75000.0, address, contact, true)
        
        # Test serialization and deserialization
        beve_data = to_beve(employee)
        parsed = from_beve(beve_data)
        
        @test parsed isa Dict{String, Any}
        @test parsed["name"] == "John Doe"
        @test parsed["age"] == 30
        @test parsed["salary"] ≈ 75000.0
        @test parsed["active"] == true
        
        # Test nested address
        @test parsed["address"] isa Dict{String, Any}
        @test parsed["address"]["street"] == "123 Main St"
        @test parsed["address"]["city"] == "New York"
        @test parsed["address"]["zipcode"] == "10001"
        
        # Test nested contact
        @test parsed["contact"] isa Dict{String, Any}
        @test parsed["contact"]["email"] == "john@example.com"
        @test parsed["contact"]["phone"] == "555-1234"
        
        # Test full reconstruction
        reconstructed = deser_beve(Employee, beve_data)
        @test reconstructed.name == employee.name
        @test reconstructed.age == employee.age
        @test reconstructed.salary ≈ employee.salary
        @test reconstructed.active == employee.active
        @test reconstructed.address.street == employee.address.street
        @test reconstructed.address.city == employee.address.city
        @test reconstructed.address.zipcode == employee.address.zipcode
        @test reconstructed.contact.email == employee.contact.email
        @test reconstructed.contact.phone == employee.contact.phone
    end
    
    @testset "Arrays of Structs" begin
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
        
        # Test array of structs
        beve_data = to_beve(products)
        parsed = from_beve(beve_data)
        
        @test parsed isa Vector{Any}
        @test length(parsed) == 3
        
        # Check first product
        @test parsed[1] isa Dict{String, Any}
        @test parsed[1]["id"] == 1
        @test parsed[1]["name"] == "Laptop"
        @test parsed[1]["price"] ≈ 999.99
        @test parsed[1]["in_stock"] == true
        
        # Check second product
        @test parsed[2]["id"] == 2
        @test parsed[2]["name"] == "Mouse"
        @test parsed[2]["price"] ≈ 25.50
        @test parsed[2]["in_stock"] == false
    end
    
    @testset "Deeply Nested Structures" begin
        struct Point
            x::Float64
            y::Float64
        end
        
        struct Shape
            name::String
            center::Point
            vertices::Vector{Point}
        end
        
        struct Drawing
            title::String
            shapes::Vector{Shape}
            metadata::Dict{String, Any}
        end
        
        # Create deeply nested structure
        triangle = Shape("triangle", 
                        Point(0.0, 0.0),
                        [Point(-1.0, -1.0), Point(1.0, -1.0), Point(0.0, 1.0)])
        
        square = Shape("square",
                      Point(5.0, 5.0),
                      [Point(4.0, 4.0), Point(6.0, 4.0), Point(6.0, 6.0), Point(4.0, 6.0)])
        
        drawing = Drawing("My Drawing", 
                         [triangle, square],
                         Dict("author" => "Alice", "version" => 1, "scale" => 2.5))
        
        # Test serialization and deserialization
        beve_data = to_beve(drawing)
        parsed = from_beve(beve_data)
        
        @test parsed isa Dict{String, Any}
        @test parsed["title"] == "My Drawing"
        @test parsed["shapes"] isa Vector{Any}
        @test length(parsed["shapes"]) == 2
        
        # Check triangle
        triangle_parsed = parsed["shapes"][1]
        @test triangle_parsed["name"] == "triangle"
        @test triangle_parsed["center"] isa Dict{String, Any}
        @test triangle_parsed["center"]["x"] ≈ 0.0
        @test triangle_parsed["center"]["y"] ≈ 0.0
        @test triangle_parsed["vertices"] isa Vector{Any}
        @test length(triangle_parsed["vertices"]) == 3
        @test triangle_parsed["vertices"][1]["x"] ≈ -1.0
        @test triangle_parsed["vertices"][1]["y"] ≈ -1.0
        
        # Check metadata
        @test parsed["metadata"] isa Dict{String, Any}
        @test parsed["metadata"]["author"] == "Alice"
        @test parsed["metadata"]["version"] == 1
        @test parsed["metadata"]["scale"] ≈ 2.5
        
        # Test partial reconstruction (just Point)
        point_data = to_beve(Point(3.14, 2.71))
        reconstructed_point = deser_beve(Point, point_data)
        @test reconstructed_point.x ≈ 3.14
        @test reconstructed_point.y ≈ 2.71
    end
    
    @testset "Mixed Container Types" begin
        struct User
            id::Int
            name::String
            tags::Vector{String}
        end
        
        struct Team
            name::String
            members::Vector{User}
            settings::Dict{String, Any}
        end
        
        # Create mixed structure
        users = [
            User(1, "Alice", ["admin", "developer"]),
            User(2, "Bob", ["developer", "tester"]),
            User(3, "Charlie", ["manager"])
        ]
        
        team = Team("Development Team", 
                   users,
                   Dict("max_members" => 10, 
                        "public" => true,
                        "created_date" => "2024-01-01"))
        
        # Test serialization and deserialization
        beve_data = to_beve(team)
        parsed = from_beve(beve_data)
        
        @test parsed isa Dict{String, Any}
        @test parsed["name"] == "Development Team"
        @test parsed["members"] isa Vector{Any}
        @test length(parsed["members"]) == 3
        
        # Check first member
        alice = parsed["members"][1]
        @test alice["id"] == 1
        @test alice["name"] == "Alice"
        @test alice["tags"] isa Vector{String}
        @test alice["tags"] == ["admin", "developer"]
        
        # Check settings
        @test parsed["settings"] isa Dict{String, Any}
        @test parsed["settings"]["max_members"] == 10
        @test parsed["settings"]["public"] == true
        @test parsed["settings"]["created_date"] == "2024-01-01"

        # Ensure struct reconstruction succeeds
        reconstructed_team = deser_beve(Team, beve_data)
        @test reconstructed_team.name == team.name
        @test reconstructed_team.settings == team.settings
        @test length(reconstructed_team.members) == length(team.members)
        @test all(m isa User for m in reconstructed_team.members)
        @test reconstructed_team.members[1].name == team.members[1].name
        @test reconstructed_team.members[1].tags == team.members[1].tags
    end

    @testset "Struct Reconstruction" begin
        struct Measurement
            value::Float64
            unit::String
        end

        struct SensorReading
            id::Int
            readings::Vector{Measurement}
        end

        struct Panel
            label::String
            sensors::Vector{SensorReading}
            notes::Vector{Union{String, Nothing}}
        end

        sensor_data = [
            SensorReading(1, [Measurement(21.5, "C"), Measurement(22.0, "C")]),
            SensorReading(2, [Measurement(55.0, "%"), Measurement(54.5, "%")])
        ]
        panel = Panel("Env Monitor", sensor_data, ["calibrated", nothing, "online"])

        reconstructed_panel = deser_beve(Panel, to_beve(panel))
        @test reconstructed_panel.label == panel.label
        @test length(reconstructed_panel.sensors) == length(sensor_data)
        @test reconstructed_panel.sensors[1].id == sensor_data[1].id
        @test reconstructed_panel.sensors[1].readings[1].value ≈ sensor_data[1].readings[1].value
        @test reconstructed_panel.notes == panel.notes

        struct Payload
            name::String
            payload::Union{Nothing, Vector{Measurement}}
        end

        payload_with_data = Payload("sensor_payload", [Measurement(1.0, "V"), Measurement(2.0, "V")])
        payload_none = Payload("empty_payload", nothing)

        roundtrip_payload = deser_beve(Payload, to_beve(payload_with_data))
        @test roundtrip_payload.name == payload_with_data.name
        @test length(roundtrip_payload.payload) == length(payload_with_data.payload)
        @test roundtrip_payload.payload[2].value ≈ payload_with_data.payload[2].value

        roundtrip_payload_none = deser_beve(Payload, to_beve(payload_none))
        @test roundtrip_payload_none.name == payload_none.name
        @test roundtrip_payload_none.payload === nothing

        struct Grid
            name::String
            rows::Vector{Vector{Int}}
            columns::Vector{String}
        end

        grid = Grid(
            "heatmap",
            [[1, 2, 3], [4, 5, 6], [7, 8, 9]],
            ["X", "Y", "Z"]
        )

        reconstructed_grid = deser_beve(Grid, to_beve(grid))
        @test reconstructed_grid.name == grid.name
        @test reconstructed_grid.rows == grid.rows
        @test reconstructed_grid.columns == grid.columns

        struct CatalogEntry
            title::String
            attributes::Dict{String, Any}
        end

        struct Catalog
            entries::Vector{CatalogEntry}
        end

        catalog = Catalog([
            CatalogEntry("book", Dict("pages" => 200, "authors" => ["Alice", "Bob"])),
            CatalogEntry("gadget", Dict("weight" => 1.2, "tags" => ["electronics", "portable"]))
        ])

        reconstructed_catalog = deser_beve(Catalog, to_beve(catalog))
        @test length(reconstructed_catalog.entries) == 2
        @test reconstructed_catalog.entries[1].title == "book"
        @test reconstructed_catalog.entries[1].attributes["pages"] == 200
        @test reconstructed_catalog.entries[2].attributes["tags"] == ["electronics", "portable"]
    end
    
    @testset "Optional and Union Fields" begin
        struct OptionalData
            required_field::String
            optional_number::Union{Int, Nothing}
            optional_string::Union{String, Nothing}
        end

        # Test with values present
        data1 = OptionalData("required", 42, "optional")
        beve_data1 = to_beve(data1)
        parsed1 = from_beve(beve_data1)

        @test parsed1["required_field"] == "required"
        @test parsed1["optional_number"] == 42
        @test parsed1["optional_string"] == "optional"

        # Test with nothing values
        data2 = OptionalData("required", nothing, nothing)
        beve_data2 = to_beve(data2)
        parsed2 = from_beve(beve_data2)

        @test parsed2["required_field"] == "required"
        @test parsed2["optional_number"] === nothing
        @test parsed2["optional_string"] === nothing
    end

    @testset "Union Type Coercion" begin
        # Test basic Union coercion with Int and String
        struct UnionHolder
            value::Union{Int, String}
        end

        # Int value should coerce correctly
        int_holder = UnionHolder(42)
        roundtrip_int = deser_beve(UnionHolder, to_beve(int_holder))
        @test roundtrip_int.value == 42
        @test roundtrip_int.value isa Int

        # String value should coerce correctly
        str_holder = UnionHolder("hello")
        roundtrip_str = deser_beve(UnionHolder, to_beve(str_holder))
        @test roundtrip_str.value == "hello"
        @test roundtrip_str.value isa String

        # Test Union{Nothing, T} coercion (common pattern)
        struct NullableHolder
            data::Union{Nothing, Vector{Int}}
        end

        with_data = NullableHolder([1, 2, 3])
        roundtrip_with = deser_beve(NullableHolder, to_beve(with_data))
        @test roundtrip_with.data == [1, 2, 3]

        without_data = NullableHolder(nothing)
        roundtrip_without = deser_beve(NullableHolder, to_beve(without_data))
        @test roundtrip_without.data === nothing

        # Test Union with multiple numeric types - exercises try-catch
        # When coercing an Int to Union{Float64, Int}, both should work
        struct MultiNumericUnion
            num::Union{Float64, Int}
        end

        int_num = MultiNumericUnion(10)
        roundtrip_int_num = deser_beve(MultiNumericUnion, to_beve(int_num))
        @test roundtrip_int_num.num == 10

        float_num = MultiNumericUnion(3.14)
        roundtrip_float_num = deser_beve(MultiNumericUnion, to_beve(float_num))
        @test roundtrip_float_num.num ≈ 3.14

        # Test Union with struct types
        struct TypeA
            a::Int
        end

        struct TypeB
            b::String
        end

        struct UnionStructHolder
            item::Union{TypeA, TypeB}
        end

        holder_a = UnionStructHolder(TypeA(100))
        roundtrip_a = deser_beve(UnionStructHolder, to_beve(holder_a))
        @test roundtrip_a.item isa TypeA
        @test roundtrip_a.item.a == 100

        holder_b = UnionStructHolder(TypeB("test"))
        roundtrip_b = deser_beve(UnionStructHolder, to_beve(holder_b))
        @test roundtrip_b.item isa TypeB
        @test roundtrip_b.item.b == "test"

        # Test Union{Nothing, StructType} - struct value should not become nothing
        # This tests that Nothing is only matched when value is actually nothing,
        # not when the value is a Dict that could be reconstructed as a struct
        struct OptionalPerson
            name::String
            age::Int
        end

        struct PersonHolder
            person::Union{Nothing, OptionalPerson}
        end

        # Struct value should reconstruct correctly (not become nothing)
        holder_with_person = PersonHolder(OptionalPerson("Alice", 30))
        roundtrip_person = deser_beve(PersonHolder, to_beve(holder_with_person))
        @test roundtrip_person.person isa OptionalPerson
        @test roundtrip_person.person.name == "Alice"
        @test roundtrip_person.person.age == 30

        # Nothing value should remain nothing
        holder_without_person = PersonHolder(nothing)
        roundtrip_no_person = deser_beve(PersonHolder, to_beve(holder_without_person))
        @test roundtrip_no_person.person === nothing

        # Test nested Union{Nothing, Struct} - inner struct with optional field
        struct InnerData
            value::Int
            label::String
        end

        struct OuterContainer
            data::Union{Nothing, InnerData}
            count::Int
        end

        outer_with_data = OuterContainer(InnerData(42, "test"), 5)
        roundtrip_outer = deser_beve(OuterContainer, to_beve(outer_with_data))
        @test roundtrip_outer.data isa InnerData
        @test roundtrip_outer.data.value == 42
        @test roundtrip_outer.data.label == "test"
        @test roundtrip_outer.count == 5

        outer_without_data = OuterContainer(nothing, 10)
        roundtrip_outer_nil = deser_beve(OuterContainer, to_beve(outer_without_data))
        @test roundtrip_outer_nil.data === nothing
        @test roundtrip_outer_nil.count == 10

        # Test Vector{Union{Nothing, StructType}}
        struct SimplePoint
            x::Int
            y::Int
        end

        struct PointCollection
            points::Vector{Union{Nothing, SimplePoint}}
        end

        points = PointCollection([SimplePoint(1, 2), nothing, SimplePoint(3, 4), nothing])
        roundtrip_points = deser_beve(PointCollection, to_beve(points))
        @test roundtrip_points.points[1] isa SimplePoint
        @test roundtrip_points.points[1].x == 1
        @test roundtrip_points.points[1].y == 2
        @test roundtrip_points.points[2] === nothing
        @test roundtrip_points.points[3] isa SimplePoint
        @test roundtrip_points.points[3].x == 3
        @test roundtrip_points.points[4] === nothing

        # Test Union in Vector elements
        struct VectorUnionHolder
            items::Vector{Union{Int, String}}
        end

        mixed_vec = VectorUnionHolder(Union{Int, String}[1, "two", 3, "four"])
        roundtrip_vec = deser_beve(VectorUnionHolder, to_beve(mixed_vec))
        @test roundtrip_vec.items[1] == 1
        @test roundtrip_vec.items[2] == "two"
        @test roundtrip_vec.items[3] == 3
        @test roundtrip_vec.items[4] == "four"

        # Test three-way Union
        struct TripleUnion
            val::Union{Int, String, Float64}
        end

        triple_int = TripleUnion(42)
        @test deser_beve(TripleUnion, to_beve(triple_int)).val == 42

        triple_str = TripleUnion("hello")
        @test deser_beve(TripleUnion, to_beve(triple_str)).val == "hello"

        triple_float = TripleUnion(2.718)
        @test deser_beve(TripleUnion, to_beve(triple_float)).val ≈ 2.718

        # Test Union with Nothing and struct - common API pattern
        struct ApiResponse
            success::Bool
            data::Union{Nothing, Dict{String, Any}}
            error_msg::Union{Nothing, String}
        end

        success_response = ApiResponse(true, Dict("id" => 1, "name" => "test"), nothing)
        roundtrip_success = deser_beve(ApiResponse, to_beve(success_response))
        @test roundtrip_success.success == true
        @test roundtrip_success.data["id"] == 1
        @test roundtrip_success.error_msg === nothing

        error_response = ApiResponse(false, nothing, "Not found")
        roundtrip_error = deser_beve(ApiResponse, to_beve(error_response))
        @test roundtrip_error.success == false
        @test roundtrip_error.data === nothing
        @test roundtrip_error.error_msg == "Not found"

        # Test nested Union types
        struct NestedUnionOuter
            inner::Union{Nothing, Vector{Union{Int, String}}}
        end

        nested_with = NestedUnionOuter(Union{Int, String}[1, "a", 2, "b"])
        roundtrip_nested = deser_beve(NestedUnionOuter, to_beve(nested_with))
        @test roundtrip_nested.inner[1] == 1
        @test roundtrip_nested.inner[2] == "a"

        nested_without = NestedUnionOuter(nothing)
        @test deser_beve(NestedUnionOuter, to_beve(nested_without)).inner === nothing
    end

    @testset "Error Message Context" begin
        # Test that error messages identify the struct type with the missing field
        # Use unique struct names to avoid conflicts with earlier testsets
        struct ErrGeoCoordinates
            latitude::Float64
            longitude::Float64
        end

        struct ErrAddress
            street::String
            city::String
            coords::ErrGeoCoordinates
        end

        struct ErrPerson
            name::String
            age::Int
            address::ErrAddress
        end

        # Test missing field error at top level
        incomplete_person = Dict("name" => "Alice")  # missing 'age' and 'address'
        bytes = to_beve(incomplete_person)
        err = nothing
        try
            deser_beve(ErrPerson, bytes; error_on_missing_fields = true)
        catch e
            err = e
        end
        @test err isa BEVE.BeveError
        @test err.msg == "Missing field 'age' for type ErrPerson"

        # Test nested struct error - identifies the nested type
        nested_incomplete = Dict(
            "name" => "Bob",
            "age" => 30,
            "address" => Dict(
                "street" => "123 Main St",
                "city" => "Springfield",
                "coords" => Dict("latitude" => 40.7128)  # missing 'longitude'
            )
        )
        bytes_nested = to_beve(nested_incomplete)
        err_nested = nothing
        try
            deser_beve(ErrPerson, bytes_nested; error_on_missing_fields = true)
        catch e
            err_nested = e
        end
        @test err_nested isa BEVE.BeveError
        @test err_nested.msg == "Missing field 'longitude' for type ErrGeoCoordinates"

        # Test byte position in parsing errors - invalid header
        invalid_bytes = UInt8[0xFF]
        parse_err = nothing
        try
            from_beve(invalid_bytes)
        catch e
            parse_err = e
        end
        @test parse_err isa BEVE.BeveError
        @test parse_err.msg == "Unsupported header: unknown type (0xff) at byte 1"

        # Test truncated data error includes position
        truncated = UInt8[0x04]  # Header byte with no following data
        trunc_err = nothing
        try
            from_beve(truncated)
        catch e
            trunc_err = e
        end
        @test trunc_err isa BEVE.BeveError
        @test occursin("at byte 1", trunc_err.msg)  # Verify error includes byte position

        # Test error in array element - identifies the element type
        struct ErrTeam
            members::Vector{ErrPerson}
        end

        team_incomplete = Dict(
            "members" => [
                Dict("name" => "Alice", "age" => 25, "address" => Dict(
                    "street" => "1 First St", "city" => "Boston",
                    "coords" => Dict("latitude" => 42.3, "longitude" => -71.0)
                )),
                Dict("name" => "Bob", "age" => 30),  # missing 'address' at index 2
                Dict("name" => "Carol", "age" => 28, "address" => Dict(
                    "street" => "3 Third St", "city" => "Chicago",
                    "coords" => Dict("latitude" => 41.8, "longitude" => -87.6)
                ))
            ]
        )
        bytes_team = to_beve(team_incomplete)
        err_team = nothing
        try
            deser_beve(ErrTeam, bytes_team; error_on_missing_fields = true)
        catch e
            err_team = e
        end
        @test err_team isa BEVE.BeveError
        @test err_team.msg == "Missing field 'address' for type ErrPerson"

        # Test deeply nested error - identifies the innermost type
        struct ErrCompany
            name::String
            teams::Vector{ErrTeam}
        end

        company_incomplete = Dict(
            "name" => "Acme Corp",
            "teams" => [
                Dict("members" => [
                    Dict("name" => "Dave", "age" => 35, "address" => Dict(
                        "street" => "HQ", "city" => "NYC",
                        "coords" => Dict("latitude" => 40.7)  # missing 'longitude'
                    ))
                ])
            ]
        )
        bytes_company = to_beve(company_incomplete)
        err_company = nothing
        try
            deser_beve(ErrCompany, bytes_company; error_on_missing_fields = true)
        catch e
            err_company = e
        end
        @test err_company isa BEVE.BeveError
        @test err_company.msg == "Missing field 'longitude' for type ErrGeoCoordinates"
    end

    @testset "Choosetype Union Handling" begin
        # Test StructUtils.@choosetype for custom type selection
        abstract type AbstractMessage end

        struct TextMessage <: AbstractMessage
            content::String
        end

        struct ImageMessage <: AbstractMessage
            url::String
            width::Int
            height::Int
        end

        # Define choosetype to select concrete type based on source data
        StructUtils.@choosetype(AbstractMessage, x -> haskey(x, "url") ? ImageMessage : TextMessage)

        struct MessageHolder
            message::AbstractMessage
        end

        # Test TextMessage selection
        text_data = Dict("message" => Dict("content" => "Hello"))
        text_bytes = to_beve(text_data)
        text_holder = deser_beve(MessageHolder, text_bytes)
        @test text_holder.message isa TextMessage
        @test text_holder.message.content == "Hello"

        # Test ImageMessage selection
        img_data = Dict("message" => Dict("url" => "http://example.com/img.png", "width" => 800, "height" => 600))
        img_bytes = to_beve(img_data)
        img_holder = deser_beve(MessageHolder, img_bytes)
        @test img_holder.message isa ImageMessage
        @test img_holder.message.url == "http://example.com/img.png"
        @test img_holder.message.width == 800

        # Test Union type with @choosetype
        struct TypeX
            x_val::Int
        end

        struct TypeY
            y_val::String
        end

        # Define choosetype for a Union
        StructUtils.@choosetype(Union{TypeX, TypeY}, x -> haskey(x, "x_val") ? TypeX : TypeY)

        struct UnionChooser
            item::Union{TypeX, TypeY}
        end

        x_data = Dict("item" => Dict("x_val" => 42))
        x_bytes = to_beve(x_data)
        x_result = deser_beve(UnionChooser, x_bytes)
        @test x_result.item isa TypeX
        @test x_result.item.x_val == 42

        y_data = Dict("item" => Dict("y_val" => "hello"))
        y_bytes = to_beve(y_data)
        y_result = deser_beve(UnionChooser, y_bytes)
        @test y_result.item isa TypeY
        @test y_result.item.y_val == "hello"

        # Test abstract type with StructUtils.@choosetype
        abstract type Vehicle end

        struct Car <: Vehicle
            make::String
            model::String
        end

        struct Truck <: Vehicle
            make::String
            payload::Float64
        end

        # Define choosetype for abstract type
        StructUtils.@choosetype(Vehicle, x -> haskey(x, "payload") ? Truck : Car)

        struct GarageSlot
            vehicle::Vehicle
        end

        car_data = Dict("vehicle" => Dict("make" => "Toyota", "model" => "Camry"))
        car_bytes = to_beve(car_data)
        car_slot = deser_beve(GarageSlot, car_bytes)
        @test car_slot.vehicle isa Car
        @test car_slot.vehicle.make == "Toyota"
        @test car_slot.vehicle.model == "Camry"

        truck_data = Dict("vehicle" => Dict("make" => "Ford", "payload" => 2000.0))
        truck_bytes = to_beve(truck_data)
        truck_slot = deser_beve(GarageSlot, truck_bytes)
        @test truck_slot.vehicle isa Truck
        @test truck_slot.vehicle.make == "Ford"
        @test truck_slot.vehicle.payload ≈ 2000.0
    end

    @testset "Choosetype Advanced Cases" begin
        # Test 1: Vector of abstract types with choosetype
        abstract type AdvShape end

        struct AdvCircle <: AdvShape
            radius::Float64
        end

        struct AdvRectangle <: AdvShape
            width::Float64
            height::Float64
        end

        StructUtils.@choosetype(AdvShape, x -> haskey(x, "radius") ? AdvCircle : AdvRectangle)

        struct AdvDrawing
            shapes::Vector{AdvShape}
        end

        shapes_data = Dict("shapes" => [
            Dict("radius" => 5.0),
            Dict("width" => 10.0, "height" => 20.0),
            Dict("radius" => 3.0)
        ])
        shapes_bytes = to_beve(shapes_data)
        drawing = deser_beve(AdvDrawing, shapes_bytes)
        @test length(drawing.shapes) == 3
        @test drawing.shapes[1] isa AdvCircle
        @test drawing.shapes[1].radius == 5.0
        @test drawing.shapes[2] isa AdvRectangle
        @test drawing.shapes[2].width == 10.0
        @test drawing.shapes[2].height == 20.0
        @test drawing.shapes[3] isa AdvCircle
        @test drawing.shapes[3].radius == 3.0

        # Test 1b: Direct deser_beve into Vector{AbstractType} (not wrapped in struct)
        direct_shapes_data = [
            Dict("width" => 15.0, "height" => 25.0),
            Dict("radius" => 8.0),
            Dict("width" => 4.0, "height" => 6.0)
        ]
        direct_shapes_bytes = to_beve(direct_shapes_data)
        direct_shapes = deser_beve(Vector{AdvShape}, direct_shapes_bytes)
        @test length(direct_shapes) == 3
        @test direct_shapes[1] isa AdvRectangle
        @test direct_shapes[1].width == 15.0
        @test direct_shapes[1].height == 25.0
        @test direct_shapes[2] isa AdvCircle
        @test direct_shapes[2].radius == 8.0
        @test direct_shapes[3] isa AdvRectangle

        # Test 2: Union{Nothing, AbstractType} with choosetype
        struct OptionalAdvShapeHolder
            shape::Union{Nothing, AdvShape}
        end

        # With a shape
        with_shape_data = Dict("shape" => Dict("radius" => 7.0))
        with_shape_bytes = to_beve(with_shape_data)
        with_shape = deser_beve(OptionalAdvShapeHolder, with_shape_bytes)
        @test with_shape.shape isa AdvCircle
        @test with_shape.shape.radius == 7.0

        # With nothing
        without_shape_data = Dict("shape" => nothing)
        without_shape_bytes = to_beve(without_shape_data)
        without_shape = deser_beve(OptionalAdvShapeHolder, without_shape_bytes)
        @test without_shape.shape === nothing

        # Test 3: Nested abstract types (abstract type containing another abstract type)
        abstract type AdvContainer end

        struct AdvBox <: AdvContainer
            contents::AdvShape
            label::String
        end

        struct AdvBag <: AdvContainer
            contents::AdvShape
            material::String
        end

        StructUtils.@choosetype(AdvContainer, x -> haskey(x, "label") ? AdvBox : AdvBag)

        struct AdvWarehouse
            container::AdvContainer
        end

        # Nested: Warehouse -> Box -> Circle
        nested_data = Dict("container" => Dict(
            "contents" => Dict("radius" => 2.5),
            "label" => "fragile"
        ))
        nested_bytes = to_beve(nested_data)
        warehouse = deser_beve(AdvWarehouse, nested_bytes)
        @test warehouse.container isa AdvBox
        @test warehouse.container.contents isa AdvCircle
        @test warehouse.container.contents.radius == 2.5
        @test warehouse.container.label == "fragile"

        # Test 4: choosetype returning nothing (should fall back to default behavior)
        struct FallbackUnion
            value::Union{Int, String}
        end

        # No choosetype defined for Union{Int, String}, should use default coercion
        int_fallback = Dict("value" => 42)
        int_fb_result = deser_beve(FallbackUnion, to_beve(int_fallback))
        @test int_fb_result.value == 42

        str_fallback = Dict("value" => "hello")
        str_fb_result = deser_beve(FallbackUnion, to_beve(str_fallback))
        @test str_fb_result.value == "hello"

        # Test 5: Multiple abstract type fields in same struct
        struct AdvMultiAbstract
            shape1::AdvShape
            shape2::AdvShape
            container::AdvContainer
        end

        multi_data = Dict(
            "shape1" => Dict("radius" => 1.0),
            "shape2" => Dict("width" => 2.0, "height" => 3.0),
            "container" => Dict("contents" => Dict("radius" => 0.5), "material" => "canvas")
        )
        multi_bytes = to_beve(multi_data)
        multi = deser_beve(AdvMultiAbstract, multi_bytes)
        @test multi.shape1 isa AdvCircle
        @test multi.shape2 isa AdvRectangle
        @test multi.container isa AdvBag
        @test multi.container.contents isa AdvCircle

        # Test 6: Vector of Union with choosetype
        struct MixedTypeA
            a::Int
        end

        struct MixedTypeB
            b::String
        end

        StructUtils.@choosetype(Union{MixedTypeA, MixedTypeB}, x -> haskey(x, "a") ? MixedTypeA : MixedTypeB)

        struct MixedVector
            items::Vector{Union{MixedTypeA, MixedTypeB}}
        end

        mixed_data = Dict("items" => [
            Dict("a" => 1),
            Dict("b" => "two"),
            Dict("a" => 3),
            Dict("b" => "four")
        ])
        mixed_bytes = to_beve(mixed_data)
        mixed = deser_beve(MixedVector, mixed_bytes)
        @test length(mixed.items) == 4
        @test mixed.items[1] isa MixedTypeA
        @test mixed.items[1].a == 1
        @test mixed.items[2] isa MixedTypeB
        @test mixed.items[2].b == "two"
        @test mixed.items[3] isa MixedTypeA
        @test mixed.items[4] isa MixedTypeB

        # Test 6b: Direct deser_beve into Vector{Union{...}} (not wrapped in struct)
        # Serialize actual Union-typed vector, then deserialize back
        original_vec = Union{MixedTypeA, MixedTypeB}[MixedTypeA(100), MixedTypeB("direct"), MixedTypeA(200)]
        direct_vec_bytes = to_beve(original_vec)
        direct_vec = deser_beve(Vector{Union{MixedTypeA, MixedTypeB}}, direct_vec_bytes)
        @test length(direct_vec) == 3
        @test direct_vec[1] isa MixedTypeA
        @test direct_vec[1].a == 100
        @test direct_vec[2] isa MixedTypeB
        @test direct_vec[2].b == "direct"
        @test direct_vec[3] isa MixedTypeA
        @test direct_vec[3].a == 200

        # Test 7: choosetype with error_on_missing_fields
        abstract type StrictAnimal end

        struct StrictDog <: StrictAnimal
            name::String
            breed::String
        end

        struct StrictCat <: StrictAnimal
            name::String
            color::String
        end

        StructUtils.@choosetype(StrictAnimal, x -> haskey(x, "breed") ? StrictDog : StrictCat)

        struct StrictPetOwner
            pet::StrictAnimal
        end

        # Complete data should work
        complete_pet = Dict("pet" => Dict("name" => "Rex", "breed" => "German Shepherd"))
        complete_bytes = to_beve(complete_pet)
        owner = deser_beve(StrictPetOwner, complete_bytes; error_on_missing_fields = true)
        @test owner.pet isa StrictDog
        @test owner.pet.name == "Rex"

        # Missing field should error with error_on_missing_fields
        incomplete_pet = Dict("pet" => Dict("breed" => "Labrador"))  # missing "name"
        incomplete_bytes = to_beve(incomplete_pet)
        @test_throws BEVE.BeveError deser_beve(StrictPetOwner, incomplete_bytes; error_on_missing_fields = true)

        # Test 8: Deep nesting with multiple choosetype levels
        abstract type Level1 end
        abstract type Level2 end

        struct L2A <: Level2
            val::Int
        end

        struct L2B <: Level2
            val::String
        end

        struct L1A <: Level1
            nested::Level2
            tag::String
        end

        struct L1B <: Level1
            nested::Level2
            count::Int
        end

        StructUtils.@choosetype(Level1, x -> haskey(x, "tag") ? L1A : L1B)
        StructUtils.@choosetype(Level2, x -> x["val"] isa Integer ? L2A : L2B)

        struct DeepHolder
            level1::Level1
        end

        deep_data = Dict("level1" => Dict(
            "nested" => Dict("val" => 42),
            "tag" => "test"
        ))
        deep_bytes = to_beve(deep_data)
        deep = deser_beve(DeepHolder, deep_bytes)
        @test deep.level1 isa L1A
        @test deep.level1.nested isa L2A
        @test deep.level1.nested.val == 42
        @test deep.level1.tag == "test"

        # Test with L2B (string value)
        deep_data2 = Dict("level1" => Dict(
            "nested" => Dict("val" => "hello"),
            "count" => 5
        ))
        deep_bytes2 = to_beve(deep_data2)
        deep2 = deser_beve(DeepHolder, deep_bytes2)
        @test deep2.level1 isa L1B
        @test deep2.level1.nested isa L2B
        @test deep2.level1.nested.val == "hello"
        @test deep2.level1.count == 5

        # Test 9: Empty vector of abstract types
        empty_shapes_data = Dict("shapes" => Any[])
        empty_shapes_bytes = to_beve(empty_shapes_data)
        empty_drawing = deser_beve(AdvDrawing, empty_shapes_bytes)
        @test isempty(empty_drawing.shapes)

        # Test 10: Dict field containing abstract type values
        struct AdvShapeRegistry
            shapes::Dict{String, AdvShape}
        end

        registry_data = Dict("shapes" => Dict(
            "main" => Dict("radius" => 10.0),
            "secondary" => Dict("width" => 5.0, "height" => 8.0)
        ))
        registry_bytes = to_beve(registry_data)
        registry = deser_beve(AdvShapeRegistry, registry_bytes)
        @test registry.shapes["main"] isa AdvCircle
        @test registry.shapes["main"].radius == 10.0
        @test registry.shapes["secondary"] isa AdvRectangle

        # Test 11: Roundtrip - serialize struct with abstract field, deserialize back
        original_warehouse = AdvWarehouse(AdvBox(AdvCircle(5.0), "test"))
        roundtrip_bytes = to_beve(original_warehouse)
        roundtrip_warehouse = deser_beve(AdvWarehouse, roundtrip_bytes)
        @test roundtrip_warehouse.container isa AdvBox
        @test roundtrip_warehouse.container.contents isa AdvCircle
        @test roundtrip_warehouse.container.contents.radius == 5.0
        @test roundtrip_warehouse.container.label == "test"

        # Test 12: Union with three+ types and choosetype
        struct TriTypeA
            a::Int
        end
        struct TriTypeB
            b::String
        end
        struct TriTypeC
            c::Float64
        end

        StructUtils.@choosetype(Union{TriTypeA, TriTypeB, TriTypeC}, x -> haskey(x, "a") ? TriTypeA : haskey(x, "b") ? TriTypeB : TriTypeC)

        struct TriHolder
            item::Union{TriTypeA, TriTypeB, TriTypeC}
        end

        tri_a = deser_beve(TriHolder, to_beve(Dict("item" => Dict("a" => 1))))
        @test tri_a.item isa TriTypeA
        @test tri_a.item.a == 1

        tri_b = deser_beve(TriHolder, to_beve(Dict("item" => Dict("b" => "hi"))))
        @test tri_b.item isa TriTypeB
        @test tri_b.item.b == "hi"

        tri_c = deser_beve(TriHolder, to_beve(Dict("item" => Dict("c" => 3.14))))
        @test tri_c.item isa TriTypeC
        @test tri_c.item.c ≈ 3.14
    end

    @testset "Union Edge Cases" begin
        # Test 1: Union with Bool and Int (Bool is a subtype of Integer in Julia)
        struct BoolIntUnion
            value::Union{Bool, Int}
        end

        # Bool should remain Bool, not become Int
        bool_holder = BoolIntUnion(true)
        bool_rt = deser_beve(BoolIntUnion, to_beve(bool_holder))
        @test bool_rt.value === true
        @test bool_rt.value isa Bool

        bool_false = BoolIntUnion(false)
        bool_false_rt = deser_beve(BoolIntUnion, to_beve(bool_false))
        @test bool_false_rt.value === false
        @test bool_false_rt.value isa Bool

        int_holder = BoolIntUnion(42)
        int_rt = deser_beve(BoolIntUnion, to_beve(int_holder))
        @test int_rt.value == 42
        @test int_rt.value isa Int

        # Test 2: Union with multiple Nothing positions
        struct MultiNothing
            a::Union{Nothing, Int}
            b::Union{String, Nothing}
            c::Union{Nothing, Float64, Nothing}  # Redundant but valid
        end

        mn1 = MultiNothing(nothing, "hello", 3.14)
        mn1_rt = deser_beve(MultiNothing, to_beve(mn1))
        @test mn1_rt.a === nothing
        @test mn1_rt.b == "hello"
        @test mn1_rt.c ≈ 3.14

        mn2 = MultiNothing(42, nothing, nothing)
        mn2_rt = deser_beve(MultiNothing, to_beve(mn2))
        @test mn2_rt.a == 42
        @test mn2_rt.b === nothing
        @test mn2_rt.c === nothing

        # Test 3: Union of vectors
        struct VectorUnion
            data::Union{Vector{Int}, Vector{String}}
        end

        int_vec = VectorUnion([1, 2, 3])
        int_vec_rt = deser_beve(VectorUnion, to_beve(int_vec))
        @test int_vec_rt.data == [1, 2, 3]

        str_vec = VectorUnion(["a", "b", "c"])
        str_vec_rt = deser_beve(VectorUnion, to_beve(str_vec))
        @test str_vec_rt.data == ["a", "b", "c"]

        # Test 4: Nested Union in struct field
        struct InnerUnion
            x::Union{Int, String}
        end

        struct OuterUnion
            inner::Union{Nothing, InnerUnion}
        end

        outer1 = OuterUnion(InnerUnion(42))
        outer1_rt = deser_beve(OuterUnion, to_beve(outer1))
        @test outer1_rt.inner isa InnerUnion
        @test outer1_rt.inner.x == 42

        outer2 = OuterUnion(InnerUnion("hello"))
        outer2_rt = deser_beve(OuterUnion, to_beve(outer2))
        @test outer2_rt.inner isa InnerUnion
        @test outer2_rt.inner.x == "hello"

        outer3 = OuterUnion(nothing)
        outer3_rt = deser_beve(OuterUnion, to_beve(outer3))
        @test outer3_rt.inner === nothing

        # Test 5: Union with concrete number types
        struct NumericUnion
            val::Union{Int8, Int16, Int32, Int64}
        end

        for (T, v) in [(Int8, Int8(127)), (Int16, Int16(1000)), (Int32, Int32(100000)), (Int64, Int64(10000000000))]
            nu = NumericUnion(v)
            nu_rt = deser_beve(NumericUnion, to_beve(nu))
            @test nu_rt.val == v
            @test typeof(nu_rt.val) == T
        end

        # Test 6: Union with Float types
        struct FloatUnion
            val::Union{Float32, Float64}
        end

        f32 = FloatUnion(Float32(3.14))
        f32_rt = deser_beve(FloatUnion, to_beve(f32))
        @test f32_rt.val ≈ Float32(3.14)
        @test f32_rt.val isa Float32

        f64 = FloatUnion(Float64(3.14159265359))
        f64_rt = deser_beve(FloatUnion, to_beve(f64))
        @test f64_rt.val ≈ 3.14159265359
        @test f64_rt.val isa Float64

        # Test 7: Dict with Union values
        struct DictUnionValues
            data::Dict{String, Union{Int, String, Nothing}}
        end

        duv = DictUnionValues(Dict("a" => 1, "b" => "two", "c" => nothing))
        duv_rt = deser_beve(DictUnionValues, to_beve(duv))
        @test duv_rt.data["a"] == 1
        @test duv_rt.data["b"] == "two"
        @test duv_rt.data["c"] === nothing

        # Test 8: Empty collections in Union
        struct EmptyCollectionUnion
            arr::Union{Nothing, Vector{Int}}
            dict::Union{Nothing, Dict{String, Int}}
        end

        ecu1 = EmptyCollectionUnion(Int[], Dict{String,Int}())
        ecu1_rt = deser_beve(EmptyCollectionUnion, to_beve(ecu1))
        @test ecu1_rt.arr == Int[]
        @test ecu1_rt.dict == Dict{String,Int}()

        ecu2 = EmptyCollectionUnion(nothing, nothing)
        ecu2_rt = deser_beve(EmptyCollectionUnion, to_beve(ecu2))
        @test ecu2_rt.arr === nothing
        @test ecu2_rt.dict === nothing
    end

    @testset "Choosetype with Union{Nothing, Abstract}" begin
        # Test choosetype when combined with Nothing in Union
        abstract type Notification end

        struct EmailNotif <: Notification
            to::String
            subject::String
        end

        struct SMSNotif <: Notification
            phone::String
            message::String
        end

        StructUtils.@choosetype(Notification, x -> haskey(x, "to") ? EmailNotif : SMSNotif)

        struct NotificationSettings
            primary::Union{Nothing, Notification}
            secondary::Union{Nothing, Notification}
        end

        # Both set
        ns1 = NotificationSettings(
            EmailNotif("user@example.com", "Hello"),
            SMSNotif("+1234567890", "Hi")
        )
        ns1_data = Dict(
            "primary" => Dict("to" => "user@example.com", "subject" => "Hello"),
            "secondary" => Dict("phone" => "+1234567890", "message" => "Hi")
        )
        ns1_rt = deser_beve(NotificationSettings, to_beve(ns1_data))
        @test ns1_rt.primary isa EmailNotif
        @test ns1_rt.primary.to == "user@example.com"
        @test ns1_rt.secondary isa SMSNotif
        @test ns1_rt.secondary.phone == "+1234567890"

        # One nothing
        ns2_data = Dict(
            "primary" => Dict("to" => "test@test.com", "subject" => "Test"),
            "secondary" => nothing
        )
        ns2_rt = deser_beve(NotificationSettings, to_beve(ns2_data))
        @test ns2_rt.primary isa EmailNotif
        @test ns2_rt.secondary === nothing

        # Both nothing
        ns3_data = Dict("primary" => nothing, "secondary" => nothing)
        ns3_rt = deser_beve(NotificationSettings, to_beve(ns3_data))
        @test ns3_rt.primary === nothing
        @test ns3_rt.secondary === nothing

        # Vector of Union{Nothing, Abstract}
        struct NotificationQueue
            queue::Vector{Union{Nothing, Notification}}
        end

        nq_data = Dict("queue" => [
            Dict("to" => "a@a.com", "subject" => "A"),
            nothing,
            Dict("phone" => "+111", "message" => "B"),
            nothing
        ])
        nq_rt = deser_beve(NotificationQueue, to_beve(nq_data))
        @test length(nq_rt.queue) == 4
        @test nq_rt.queue[1] isa EmailNotif
        @test nq_rt.queue[2] === nothing
        @test nq_rt.queue[3] isa SMSNotif
        @test nq_rt.queue[4] === nothing
    end

    @testset "AbstractDict field roundtrip" begin
        # AbstractDict fields should roundtrip when the source is already a concrete Dict
        struct SystemInfo
            name::String
            registers::AbstractDict
        end

        si = SystemInfo("host1", Dict("a" => 1, "b" => "two"))
        si_rt = deser_beve(SystemInfo, to_beve(si))
        @test si_rt.name == "host1"
        @test si_rt.registers isa Dict
        @test si_rt.registers["a"] == 1
        @test si_rt.registers["b"] == "two"

        # Also test with Union{AbstractDict, Nothing}
        struct OptSystemInfo
            name::String
            registers::Union{AbstractDict, Nothing}
        end

        osi1 = OptSystemInfo("host2", Dict("x" => 42))
        osi1_rt = deser_beve(OptSystemInfo, to_beve(osi1))
        @test osi1_rt.registers isa Dict
        @test osi1_rt.registers["x"] == 42

        osi2 = OptSystemInfo("host3", nothing)
        osi2_rt = deser_beve(OptSystemInfo, to_beve(osi2))
        @test osi2_rt.registers === nothing
    end

    @testset "Choosetype Priority and Fallback" begin
        # Case 1: @choosetype always returns PriorityA
        abstract type Priority end

        struct PriorityA <: Priority
            val::Int
        end

        struct PriorityB <: Priority
            val::String
        end

        # Always select PriorityA regardless of content
        StructUtils.@choosetype(Priority, x -> PriorityA)

        struct PriorityHolder
            item::Priority
        end

        # Even though data could match PriorityB, choosetype forces PriorityA
        ph_data = Dict("item" => Dict("val" => 42))
        ph_rt = deser_beve(PriorityHolder, to_beve(ph_data))
        @test ph_rt.item isa PriorityA
        @test ph_rt.item.val == 42

        # Case 2: No @choosetype defined - should error
        abstract type Fallback end

        struct FallbackA <: Fallback
            a::Int
        end

        struct FallbackHolder
            item::Fallback
        end

        # Without @choosetype, abstract type cannot be constructed
        fb_data = Dict("item" => Dict("a" => 1))
        @test_throws BEVE.BeveError deser_beve(FallbackHolder, to_beve(fb_data))
    end

    @testset "Choosetype Error Handling" begin
        # Test 1: Field-level abstract type without @choosetype throws BeveError
        abstract type NoChooseAnimal end
        struct NoChooseDog <: NoChooseAnimal
            name::String
        end

        struct NoChooseOwner
            pet::NoChooseAnimal
        end

        no_choose_data = Dict("pet" => Dict("name" => "Rex"))
        err1 = nothing
        try
            deser_beve(NoChooseOwner, to_beve(no_choose_data))
        catch e
            err1 = e
        end
        @test err1 isa BEVE.BeveError
        @test occursin("Cannot deserialize to abstract type", err1.msg)
        @test occursin("NoChooseAnimal", err1.msg)

        # Test 2: Top-level abstract type without @choosetype throws BeveError
        abstract type TopLevelAbstract end
        struct TopLevelConcrete <: TopLevelAbstract
            x::Int
        end

        top_data = Dict("x" => 42)
        err2 = nothing
        try
            deser_beve(TopLevelAbstract, to_beve(top_data))
        catch e
            err2 = e
        end
        @test err2 isa BEVE.BeveError
        @test occursin("Cannot deserialize to abstract type", err2.msg)

        # Test 3: Vector of abstract type without @choosetype throws BeveError
        abstract type VecNoChoose end
        struct VecNoChooseConcrete <: VecNoChoose
            x::Int
        end

        struct VecNoChooseHolder
            items::Vector{VecNoChoose}
        end

        vec_data = Dict("items" => [Dict("x" => 1), Dict("x" => 2)])
        err6 = nothing
        try
            deser_beve(VecNoChooseHolder, to_beve(vec_data))
        catch e
            err6 = e
        end
        @test err6 isa BEVE.BeveError
        @test occursin("Cannot deserialize to abstract type", err6.msg)

        # Test 4: Valid @choosetype still works (sanity check)
        abstract type ValidAbstract end
        struct ValidConcreteA <: ValidAbstract
            a::Int
        end
        struct ValidConcreteB <: ValidAbstract
            b::String
        end

        StructUtils.@choosetype(ValidAbstract, x -> haskey(x, "a") ? ValidConcreteA : ValidConcreteB)

        struct ValidHolder
            item::ValidAbstract
        end

        valid_data = Dict("item" => Dict("a" => 123))
        valid_result = deser_beve(ValidHolder, to_beve(valid_data))
        @test valid_result.item isa ValidConcreteA
        @test valid_result.item.a == 123

        # Test 5: Valid Union @choosetype still works (sanity check)
        struct ValidUnionA
            val_a::Int
        end
        struct ValidUnionB
            val_b::String
        end

        StructUtils.@choosetype(Union{ValidUnionA, ValidUnionB}, x -> haskey(x, "val_a") ? ValidUnionA : ValidUnionB)

        struct ValidUnionHolder
            item::Union{ValidUnionA, ValidUnionB}
        end

        valid_union_data = Dict("item" => Dict("val_b" => "hello"))
        valid_union_result = deser_beve(ValidUnionHolder, to_beve(valid_union_data))
        @test valid_union_result.item isa ValidUnionB
        @test valid_union_result.item.val_b == "hello"

        # Test 6: Union containing abstract type falls back to concrete members
        abstract type UnionAbstractPart end

        struct UnionWithAbstract
            item::Union{UnionAbstractPart, Int, String}
        end

        # Int value should work - abstract type is skipped
        int_data = Dict("item" => 42)
        int_result = deser_beve(UnionWithAbstract, to_beve(int_data))
        @test int_result.item == 42
        @test int_result.item isa Int

        # String value should work - abstract type is skipped
        str_data = Dict("item" => "hello")
        str_result = deser_beve(UnionWithAbstract, to_beve(str_data))
        @test str_result.item == "hello"
        @test str_result.item isa String
    end

    @testset "StructUtils.@choosetype Compatibility" begin
        structutils_available = try
            Base.require(Base.PkgId(Base.UUID("ec057cc2-7a8d-4b58-b3b3-92acb9f63b42"), "StructUtils"))
            true
        catch err
            @info "Skipping StructUtils tests: StructUtils not available" exception = err
            false
        end

        if structutils_available
            SU = Base.require(Base.PkgId(Base.UUID("ec057cc2-7a8d-4b58-b3b3-92acb9f63b42"), "StructUtils"))

            # Define types for StructUtils test
            abstract type SUAnimal end

            struct SUDog <: SUAnimal
                name::String
                barks::Bool
            end

            struct SUCat <: SUAnimal
                name::String
                meows::Bool
            end

            # Use StructUtils.@choosetype (like JSON3 users would)
            # We need to use invokelatest since we loaded StructUtils dynamically
            # First load StructUtils into Main
            Core.eval(Main, :(using StructUtils))
            # Then define the choosetype
            Core.eval(Main, quote
                StructUtils.@choosetype($SUAnimal, x -> haskey(x, "barks") ? $SUDog : $SUCat)
            end)

            struct SUPetOwner
                pet::SUAnimal
            end

            # Test that BEVE picks up StructUtils.@choosetype
            dog_data = Dict("pet" => Dict("name" => "Rex", "barks" => true))
            dog_bytes = to_beve(dog_data)
            owner = deser_beve(SUPetOwner, dog_bytes)
            @test owner.pet isa SUDog
            @test owner.pet.name == "Rex"
            @test owner.pet.barks == true

            cat_data = Dict("pet" => Dict("name" => "Whiskers", "meows" => true))
            cat_bytes = to_beve(cat_data)
            owner2 = deser_beve(SUPetOwner, cat_bytes)
            @test owner2.pet isa SUCat
            @test owner2.pet.name == "Whiskers"
            @test owner2.pet.meows == true

            # Test Vector of abstract type with StructUtils.@choosetype
            struct SUShelter
                animals::Vector{SUAnimal}
            end

            shelter_data = Dict("animals" => [
                Dict("name" => "Buddy", "barks" => true),
                Dict("name" => "Mittens", "meows" => false),
                Dict("name" => "Max", "barks" => false)
            ])
            shelter_bytes = to_beve(shelter_data)
            shelter = deser_beve(SUShelter, shelter_bytes)
            @test length(shelter.animals) == 3
            @test shelter.animals[1] isa SUDog
            @test shelter.animals[2] isa SUCat
            @test shelter.animals[3] isa SUDog

            # Test Vector{Union{...}} roundtrip with StructUtils.@choosetype
            struct SUTypeX
                x_val::Int
            end

            struct SUTypeY
                y_val::String
            end

            # Define choosetype for Union via StructUtils (like JSON.@choosetype)
            Core.eval(Main, quote
                StructUtils.@choosetype(Union{$SUTypeX, $SUTypeY}, x -> haskey(x, "x_val") ? $SUTypeX : $SUTypeY)
            end)

            # Roundtrip test: serialize actual Union vector, deserialize back
            original_su_vec = Union{SUTypeX, SUTypeY}[SUTypeX(100), SUTypeY("hello"), SUTypeX(200)]
            su_vec_bytes = to_beve(original_su_vec)
            su_vec_result = deser_beve(Vector{Union{SUTypeX, SUTypeY}}, su_vec_bytes)
            @test length(su_vec_result) == 3
            @test su_vec_result[1] isa SUTypeX
            @test su_vec_result[1].x_val == 100
            @test su_vec_result[2] isa SUTypeY
            @test su_vec_result[2].y_val == "hello"
            @test su_vec_result[3] isa SUTypeX
            @test su_vec_result[3].x_val == 200
        end
    end

    @testset "StructUtils.makestruct Override (Post-Construction)" begin
        # A struct with a derived field that must be computed after construction
        @kwarg mutable struct ScaledData
            raw_values::Vector{Float64} = Float64[]
            scale::Float64 = 1.0
            # Derived: computed from raw_values and scale after deserialization
            scaled_values::Vector{Float64} = Float64[]
        end

        BEVE.@skip ScaledData scaled_values

        # Override makestruct to auto-populate scaled_values after construction
        function StructUtils.makestruct(style::BEVE.BeveStyle, ::Type{ScaledData}, source)
            T = ScaledData
            vals = StructUtils.mem(fieldcount(T))
            fsyms = StructUtils.fieldnamesymbols(T)
            st = BEVE.fill_struct_fields!(style, T, vals, source)
            obj = T(; (fsyms[i] => vals[i] for i in 1:fieldcount(T) if isassigned(vals, i))...)
            # Post-construction: compute derived field
            if !isempty(obj.raw_values)
                obj.scaled_values = obj.raw_values .* obj.scale
            end
            return obj, st
        end

        m = ScaledData(raw_values = [1.0, 2.0, 3.0], scale = 10.0, scaled_values = [10.0, 20.0, 30.0])
        bytes = to_beve(m)
        # scaled_values is skipped during serialization
        parsed = from_beve(bytes)
        @test !haskey(parsed, "scaled_values")

        # Deserialize: makestruct override should recompute scaled_values
        rt = deser_beve(ScaledData, bytes)
        @test rt.raw_values == [1.0, 2.0, 3.0]
        @test rt.scale == 10.0
        @test rt.scaled_values == [10.0, 20.0, 30.0]

        # Empty data round-trip
        m_empty = ScaledData()
        rt_empty = deser_beve(ScaledData, to_beve(m_empty))
        @test isempty(rt_empty.scaled_values)

        # Nested struct containing ScaledData
        struct ScaledDataSet
            label::String
            data::ScaledData
        end

        ms = ScaledDataSet("test", ScaledData(raw_values = [5.0], scale = 2.0, scaled_values = [10.0]))
        rt_ms = deser_beve(ScaledDataSet, to_beve(ms))
        @test rt_ms.label == "test"
        @test rt_ms.data.raw_values == [5.0]
        @test rt_ms.data.scale == 2.0
        @test rt_ms.data.scaled_values == [10.0]
    end

    @testset "StructUtils FieldTags" begin
        # Field name remapping via tags: deserialization matches remapped names
        StructUtils.@tags struct APIResponse
            user_name::String &(name=:username,)
            is_active::Bool &(name=:active,)
            score::Int
        end

        # Deserialization from remapped names (e.g., data from an external API/JSON)
        remapped = Dict("username" => "bob", "active" => false, "score" => 99)
        rt_remapped = deser_beve(APIResponse, to_beve(remapped))
        @test rt_remapped.user_name == "bob"
        @test rt_remapped.is_active == false
        @test rt_remapped.score == 99

        # Struct without name tags round-trips normally
        StructUtils.@tags struct SimpleTagged
            label::String
            count::Int
        end

        simple = SimpleTagged("test", 5)
        rt_simple = deser_beve(SimpleTagged, to_beve(simple))
        @test rt_simple.label == "test"
        @test rt_simple.count == 5

        # Field-level lift via tags
        StructUtils.@tags struct WithLift
            label::String
            value::Int &(lift=x -> parse(Int, x) * 2,)
        end

        # Deserialize with lift tag: string "21" → parse → 42
        data = Dict("label" => "test", "value" => "21")
        rt_lift = deser_beve(WithLift, to_beve(data))
        @test rt_lift.label == "test"
        @test rt_lift.value == 42

        # FieldTags + choosetype combined
        abstract type TaggedAnimal end
        struct TaggedDog <: TaggedAnimal
            name::String
        end
        struct TaggedCat <: TaggedAnimal
            name::String
        end

        StructUtils.@tags struct PetShop
            owner::String
            pet::TaggedAnimal &(choosetype=x -> get(x, "species", "") == "dog" ? TaggedDog : TaggedCat,)
        end

        dog_shop = Dict("owner" => "Bob", "pet" => Dict("species" => "dog", "name" => "Rex"))
        rt_dog = deser_beve(PetShop, to_beve(dog_shop))
        @test rt_dog.owner == "Bob"
        @test rt_dog.pet isa TaggedDog
        @test rt_dog.pet.name == "Rex"

        cat_shop = Dict("owner" => "Eve", "pet" => Dict("species" => "cat", "name" => "Whiskers"))
        rt_cat = deser_beve(PetShop, to_beve(cat_shop))
        @test rt_cat.pet isa TaggedCat
        @test rt_cat.pet.name == "Whiskers"
    end

    @testset "Keyword Constructor Fallback" begin
        # Base.@kwdef with defaults — tests the try/catch fallback in BeveStyle.makestruct
        # where _construct fails but keyword constructor succeeds
        Base.@kwdef struct KWConfig
            host::String = "localhost"
            port::Int = 8080
            debug::Bool = false
            label::String
        end

        # Serialize only some fields (simulating partial data)
        partial_data = Dict("label" => "prod")
        rt = deser_beve(KWConfig, to_beve(partial_data))
        @test rt.host == "localhost"
        @test rt.port == 8080
        @test rt.debug == false
        @test rt.label == "prod"

        # Full data round-trip
        full = KWConfig(host = "example.com", port = 443, debug = true, label = "staging")
        rt_full = deser_beve(KWConfig, to_beve(full))
        @test rt_full.host == "example.com"
        @test rt_full.port == 443
        @test rt_full.debug == true
        @test rt_full.label == "staging"

        # All defaults except required field
        minimal = Dict("label" => "min")
        rt_min = deser_beve(KWConfig, to_beve(minimal))
        @test rt_min.host == "localhost"
        @test rt_min.port == 8080
        @test rt_min.label == "min"

        # Missing required field should error
        no_label = Dict("host" => "x", "port" => 1)
        @test_throws Exception deser_beve(KWConfig, to_beve(no_label))

        # error_on_missing catches partial data
        @test_throws BEVE.BeveError deser_beve(KWConfig, to_beve(partial_data);
                                                error_on_missing_fields = true)
    end

    @testset "Absent Field Resolution" begin
        struct NullableFields
            id::Int
            note::Union{Nothing, String}
            score::Union{Missing, Float64}
        end
        rt = deser_beve(NullableFields, to_beve(Dict("id" => 7)))
        @test rt.id == 7
        @test rt.note === nothing
        @test rt.score === missing

        NT = NamedTuple{(:a, :b), Tuple{Int, Int}}
        @test deser_beve(NT, to_beve(Dict("a" => 1, "b" => 2))) == (a = 1, b = 2)
        @test_throws BEVE.BeveError deser_beve(NT, to_beve(Dict("a" => 1)))
    end

    @testset "StructUtils @defaults" begin
        StructUtils.@defaults struct Config
            required::String
            timeout::Int = 30
            retries::Int = 3
        end

        # Full data
        full = Config("api", 60, 5)
        rt_full = deser_beve(Config, to_beve(full))
        @test rt_full.required == "api"
        @test rt_full.timeout == 60
        @test rt_full.retries == 5

        # Partial data — StructUtils fielddefaults should fill in
        partial = Dict("required" => "test")
        rt_partial = deser_beve(Config, to_beve(partial))
        @test rt_partial.required == "test"
        @test rt_partial.timeout == 30
        @test rt_partial.retries == 3

        # Only one default overridden
        partial2 = Dict("required" => "test", "timeout" => 10)
        rt_partial2 = deser_beve(Config, to_beve(partial2))
        @test rt_partial2.required == "test"
        @test rt_partial2.timeout == 10
        @test rt_partial2.retries == 3
    end

    @testset "Enum Deserialization" begin
        @enum Color RED = 1 GREEN = 2 BLUE = 3

        struct ColoredItem
            name::String
            color::Color
        end

        # Enum is serialized as string by BEVE
        item = ColoredItem("ball", GREEN)
        bytes = to_beve(item)
        parsed = from_beve(bytes)
        @test parsed["color"] == "GREEN"

        # Round-trip: string enum should deserialize back
        rt = deser_beve(ColoredItem, bytes)
        @test rt.name == "ball"
        @test rt.color == GREEN

        # All enum values
        for c in (RED, GREEN, BLUE)
            ci = ColoredItem("x", c)
            rt_c = deser_beve(ColoredItem, to_beve(ci))
            @test rt_c.color == c
        end

        # Enum in a vector
        struct Palette
            colors::Vector{Color}
        end

        pal = Palette([RED, BLUE, GREEN])
        rt_pal = deser_beve(Palette, to_beve(pal))
        @test rt_pal.colors == [RED, BLUE, GREEN]

        # Enum in a Union
        struct MaybeColor
            c::Union{Color, Nothing}
        end

        rt_some = deser_beve(MaybeColor, to_beve(MaybeColor(BLUE)))
        @test rt_some.c == BLUE

        rt_none = deser_beve(MaybeColor, to_beve(MaybeColor(nothing)))
        @test rt_none.c === nothing

        # Enums in dictionaries. Enum values serialize as their string name, and
        # enum keys serialize as string keys, so both sides need lifting back.
        val_map = Dict("primary" => RED, "accent" => BLUE)
        key_map = Dict(RED => 1, BLUE => 2)
        both_map = Dict(RED => GREEN)
        nested_map = Dict("warm" => [RED, GREEN])

        # Top level, buffer path
        @test deser_beve(Dict{String, Color}, to_beve(val_map)) == val_map
        @test deser_beve(Dict{Color, Int}, to_beve(key_map)) == key_map
        @test deser_beve(Dict{Color, Color}, to_beve(both_map)) == both_map
        @test deser_beve(Dict{String, Vector{Color}}, to_beve(nested_map)) == nested_map

        # Top level, streaming path
        @test deser_beve(Dict{String, Color}, IOBuffer(to_beve(val_map))) == val_map
        @test deser_beve(Dict{Color, Int}, IOBuffer(to_beve(key_map))) == key_map
        @test deser_beve(Dict{Color, Color}, IOBuffer(to_beve(both_map))) == both_map

        # As struct fields
        struct ColorMaps
            values::Dict{String, Color}
            keys::Dict{Color, Int}
            nested::Dict{String, Vector{Color}}
        end

        maps = ColorMaps(val_map, key_map, nested_map)
        rt_maps = deser_beve(ColorMaps, to_beve(maps))
        @test rt_maps.values == val_map
        @test rt_maps.keys == key_map
        @test rt_maps.nested == nested_map

        rt_maps_stream = deser_beve(ColorMaps, IOBuffer(to_beve(maps)))
        @test rt_maps_stream.values == val_map
        @test rt_maps_stream.keys == key_map
        @test rt_maps_stream.nested == nested_map

        # An unknown name is still rejected in key and value position
        @test_throws Exception deser_beve(Dict{String, Color}, to_beve(Dict("a" => "PURPLE")))
        @test_throws Exception deser_beve(Dict{Color, Int}, to_beve(Dict("PURPLE" => 1)))

        # Invalid enum string should error
        bad_data = Dict("name" => "x", "color" => "PURPLE")
        @test_throws Exception deser_beve(ColoredItem, to_beve(bad_data))
    end

    @testset "@noarg Struct Support" begin
        StructUtils.@noarg mutable struct NoArgSensor
            timestamp::Float64
            value::Float64
            quality::Int = 100
        end

        # Full round-trip
        r = NoArgSensor()
        r.timestamp = 1234.5
        r.value = 42.0
        r.quality = 95
        rt = deser_beve(NoArgSensor, to_beve(r))
        @test rt.timestamp == 1234.5
        @test rt.value == 42.0
        @test rt.quality == 95

        # Partial data — unset fields use defaults from @noarg
        partial = Dict("value" => 3.14)
        rt_partial = deser_beve(NoArgSensor, to_beve(partial))
        @test rt_partial.value == 3.14
        @test rt_partial.quality == 100  # default from @noarg

        # Nested in another struct
        struct NoArgSensorLog
            name::String
            reading::NoArgSensor
        end

        r2 = NoArgSensor()
        r2.timestamp = 999.0
        r2.value = 1.0
        log = NoArgSensorLog("temp", r2)
        rt_log = deser_beve(NoArgSensorLog, to_beve(log))
        @test rt_log.name == "temp"
        @test rt_log.reading.timestamp == 999.0
        @test rt_log.reading.value == 1.0
        @test rt_log.reading.quality == 100
    end

    @testset "Combined StructUtils Features" begin
        # Combine fieldtags (name remapping) + @kwarg defaults + choosetype
        abstract type Transport end
        struct Bus <: Transport
            route::String
            capacity::Int
        end
        struct Train <: Transport
            line::String
            cars::Int
        end

        StructUtils.@choosetype(Transport, d -> get(d, "kind", "") == "bus" ? Bus : Train)

        @kwarg struct Commute
            traveler::String
            transport::Transport
            distance_km::Float64 = 0.0
        end

        # Bus round-trip
        bus_data = Dict(
            "traveler" => "Alice",
            "transport" => Dict("kind" => "bus", "route" => "42", "capacity" => 40),
            "distance_km" => 12.5
        )
        rt_bus = deser_beve(Commute, to_beve(bus_data))
        @test rt_bus.traveler == "Alice"
        @test rt_bus.transport isa Bus
        @test rt_bus.transport.route == "42"
        @test rt_bus.distance_km == 12.5

        # Train with default distance
        train_data = Dict(
            "traveler" => "Bob",
            "transport" => Dict("kind" => "train", "line" => "Red", "cars" => 8)
        )
        rt_train = deser_beve(Commute, to_beve(train_data))
        @test rt_train.transport isa Train
        @test rt_train.transport.line == "Red"
        @test rt_train.distance_km == 0.0

        # Fieldtags name remapping + union types
        StructUtils.@tags struct MappedUnion
            data_type::String &(name=:type,)
            payload::Union{Int, String}
        end

        int_data = Dict("type" => "number", "payload" => 42)
        rt_int = deser_beve(MappedUnion, to_beve(int_data))
        @test rt_int.data_type == "number"
        @test rt_int.payload == 42

        str_data = Dict("type" => "text", "payload" => "hello")
        rt_str = deser_beve(MappedUnion, to_beve(str_data))
        @test rt_str.data_type == "text"
        @test rt_str.payload == "hello"
    end

    @testset "HTTP Extension Loading" begin
        # Test that HTTP functions work when HTTP.jl is loaded
        using HTTP
        
        struct TestData
            value::Int
        end
        
        # Test that basic HTTP functions are available
        test_obj = TestData(42)
        
        # Test registration works
        register_object("/test", test_obj)
        unregister_object("/test")
        @test true  # If we got here without errors, the extension loaded
        
        # Test client creation works
        client = BeveHttpClient("http://localhost:8080")
        @test client !== nothing
        
        # Run the full extension test suite if it exists
        extension_test_file = joinpath(@__DIR__, "test_http_extension.jl")
        if isfile(extension_test_file)
            include(extension_test_file)
        end
    end

    include(joinpath(@__DIR__, "streaming_typed.jl"))

    @testset "StaticArrays roundtrip" begin
        static_arrays_available = try
            @eval using StaticArrays
            true
        catch
            @info "Skipping StaticArrays tests: StaticArrays not available"
            false
        end

        if static_arrays_available
            @testset "serializes as typed array, not object" begin
                mv = MVector{3, Float64}(1.0, 2.0, 3.0)
                bytes = to_beve(mv)
                raw = from_beve(bytes)
                @test raw isa Vector{Float64}
                @test raw == [1.0, 2.0, 3.0]
            end

            @testset "struct with StaticArrays fields" begin
                struct StaticArrayHolder
                    vec::MVector{4, Float64}
                    svec::SVector{3, Int32}
                    bytes::MVector{8, UInt8}
                end

                original = StaticArrayHolder(
                    MVector{4, Float64}(1.0, 2.0, 3.0, 4.0),
                    SVector{3, Int32}(10, 20, 30),
                    MVector{8, UInt8}(0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08),
                )

                bytes = to_beve(original)
                result = deser_beve(StaticArrayHolder, bytes)

                @test result.vec == original.vec
                @test result.svec == original.svec
                @test result.bytes == original.bytes
            end

            @testset "bare MVector roundtrip" begin
                original = MVector{3, Float64}(1.0, 2.0, 3.0)
                bytes = to_beve(original)
                result = deser_beve(MVector{3, Float64}, bytes)
                @test result == original
            end

            @testset "bare SVector roundtrip" begin
                original = SVector{4, Int32}(10, 20, 30, 40)
                bytes = to_beve(original)
                result = deser_beve(SVector{4, Int32}, bytes)
                @test result == original
            end

            @testset "Vector of StaticArrays" begin
                original = [SVector{2, Float64}(1.0, 2.0), SVector{2, Float64}(3.0, 4.0)]
                bytes = to_beve(original)
                result = deser_beve(Vector{SVector{2, Float64}}, bytes)
                @test result == original
            end

            @testset "MVector of zeros" begin
                original = MVector{8, UInt8}(zeros(UInt8, 8)...)
                bytes = to_beve(original)
                result = deser_beve(MVector{8, UInt8}, bytes)
                @test result == original
            end
        end
    end
end
