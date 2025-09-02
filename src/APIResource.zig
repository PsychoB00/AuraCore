/// STD
const std = @import("std");
const comptimePrint = std.fmt.comptimePrint;

/// Third Party
const zeit = @import("zeit");
const Time = zeit.Time;

pub const api_resource = struct {
    pub const ParametersType = enum {
        path,
        query,
        body,
    };

    pub const ResourceParametersError = error{
        NotFound,
        BadRequest,
    };

    /// Parameters defining the Resource's identity
    ///
    /// - Fields of `Structure` represent individual parameters, they are order sensitive.
    /// - First field in `Structure` must have the same name as the APIResource using it.
    /// - Every parameter can be optional. If any parameter is optional, subsequent parameters must be optional as well.
    /// - Parameters can be typed as unsigned integer, string or zeit.Time(ISO 8601).
    pub fn PathParameters(comptime Structure: type) type {
        // `Structure` correctness assertion
        _validateURIStructure(Structure);

        const structure_info = @typeInfo(Structure);
        var has_optional_fields = false;

        for (structure_info.@"struct".fields) |field| {
            var field_type = field.type;
            if (@typeInfo(field.type) != .optional) {
                if (has_optional_fields)
                    @compileError("Non-optional field found after optional field");
            } else {
                has_optional_fields = true;
                field_type = @typeInfo(field.type).optional.child;
            }

            switch (@typeInfo(field_type)) {
                .int => {
                    if (@typeInfo(field_type).int.signedness == .signed)
                        @compileError("Signed field type found");
                },
                else => {
                    if (field_type != []const u8 and field_type != Time)
                        @compileError("Unsupported field type found");
                },
            }
        }

        return struct {
            pub const parameters_type: ParametersType = .path;
            pub const structure = Structure;

            data: Structure,
        };
    }

    /// Parameters defining the Resource's filters
    ///
    /// - Fields of `Structure` represent individual parameters, they are order insensitive.
    /// - Every parameter can be optional.
    /// - Parameters can be typed as bool, integer, float, enum, string or zeit.Time(ISO 8601).
    pub fn QueryParameters(comptime Structure: type) type {
        // `Structure` correctness assertion
        _validateURIStructure(Structure);

        const structure_info = @typeInfo(Structure);

        for (structure_info.@"struct".fields) |field| {
            const field_type =
                if (@typeInfo(field.type) == .optional)
                    @typeInfo(field.type).optional.child
                else
                    field.type;

            switch (@typeInfo(field_type)) {
                .bool, .int, .float => {},
                .@"enum" => {
                    const field_enum = @typeInfo(field_type).@"enum";
                    if (!field_enum.is_exhaustive)
                        @compileError("Unexhaustive enum field type found");
                    if (field_enum.decls.len != 0)
                        @compileError("Enum field type with declarations found");
                },
                else => {
                    if (field_type != []const u8 and field_type != Time)
                        @compileError("Unsupported field type found");
                },
            }
        }

        return struct {
            pub const parameters_type: ParametersType = .query;
            pub const structure = Structure;

            data: Structure,
        };
    }

    /// Parameters for larger and more complex data
    ///
    /// - `Structure` is a type representing content of the body, can be optional type.
    /// - Form of parsing is derived from header "Content-Type" of the request. `Structure`
    ///   can be incompatible with "Content-Type", in which case request status will be "BAD_REQUEST".
    /// - Supported MIME types are:
    ///     - `text/plain`
    ///         - extention: .txt
    ///         - compatible types: []const u8
    ///     - `application/json`
    ///         - extention: .json
    ///         - compatible types:
    ///             - JSON compatible types
    ///             - []const u8 for date and time, formated to ISO 8601
    /// - If any memory needs to be allocated during parsing of `Structure`, it will be allocated with
    ///   arena allocator provided by zap.Request, so no deallocation is nessesary. However this binds
    ///   the lifetime of the memory to lifetime of the zap.Request.
    pub fn BodyParameters(comptime Structure: type) type {
        // Generated BodyParameters tools
        const Gen = struct {
            /// Validates type of or inside `Structure`, based on supported MIME types
            fn _validateType(comptime Type: type) void {
                switch (@typeInfo(Type)) {
                    .bool, .int, .float => {},
                    .pointer => |info| {
                        if (info.size != .slice)
                            @compileError("Non-slice pointer type found");

                        _validateType(info.child);
                    },
                    .optional => |info| {
                        _validateType(info.child);
                    },
                    .@"struct" => |info| {
                        if (Type == Time)
                            return;

                        if (info.is_tuple)
                            @compileError("Tuple type found");
                        if (info.decls.len > 0)
                            @compileError("Struct type with declarations found");

                        for (info.fields) |field| {
                            _validateType(field.type);
                        }
                    },
                    else => @compileError("Unsupported type found"),
                }
            }
        };

        // `Structure` correctness assertion
        const structure_type =
            if (@typeInfo(Structure) == .optional)
                @typeInfo(Structure).optional.child
            else
                Structure;

        Gen._validateType(structure_type);

        return struct {
            pub const parameters_type: ParametersType = .body;
            pub const structure = Structure;

            data: Structure,
        };
    }

    pub fn isResourceParameters(comptime Type: type) bool {
        return @hasDecl(Type, "parameters_type") and @TypeOf(Type.parameters_type) == ParametersType and
            @hasDecl(Type, "structure") and @TypeOf(Type.structure) == type and
            @hasField(Type, "data") and @FieldType(Type, "data") == Type.structure;
    }

    /// Validates common asspects for URI ResourceParameters.structure
    fn _validateURIStructure(comptime Structure: type) void {
        const structure_info = @typeInfo(Structure);

        if (structure_info != .@"struct")
            @compileError("`Structure` must be struct");
        if (structure_info.@"struct".is_tuple)
            @compileError("`Structure` mustn't be tuple");
        if (structure_info.@"struct".decls.len != 0)
            @compileError("`Structure` mustn't any declarations");
        if (structure_info.@"struct".fields.len < 1)
            @compileError("`Structure` must have at least one field");
    }
};
