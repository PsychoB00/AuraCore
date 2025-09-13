/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;

const indexOf = std.mem.indexOf;
const indexOfScalarPos = std.mem.indexOfScalarPos;
const eqlIgnoreCase = std.ascii.eqlIgnoreCase;
const parseInt = std.fmt.parseInt;
const parseFloat = std.fmt.parseFloat;
const stringToEnum = std.meta.stringToEnum;

/// Aura
const core = @import("../core.zig");

const ParametersType = core.routing.ParametersType;

const fieldPtr = core.utils.fieldPtr;
const isResourceParameters = core.routing.isResourceParameters;

/// Third Party
const zap = @import("zap");
const Request = zap.Request;

const zeit = @import("zeit");
const Time = zeit.Time;

pub const ParseError = error{
    MissingQuery,
    MissingParameter,
    MissingValue,
    InvalidBool,
    InvalidEnum,
    ExcessQuery,
};

/// Parameters defining the Resource's filters
///
/// - Fields of `Structure` represent individual parameters, they are order insensitive.
/// - Every parameter can be optional.
/// - Parameters can be typed as bool, integer, float, enum, string or zeit.Time(ISO 8601).
/// - Parameters can have default values, if parameter is optional and no default value is provided,
///   null will be assigned.
/// - If any memory needs to be allocated during parsing of `Structure`, it will be allocated with
///   arena allocator provided by zap.Request, so no deallocation is nessesary. However this binds
///   the lifetime of the memory to lifetime of the zap.Request.
pub fn QueryParameters(comptime Structure: type) type {
    // `Structure` correctness assertion
    const structure_info = @typeInfo(Structure);
    var has_non_optional_fields = false;

    if (structure_info != .@"struct")
        @compileError("`Structure` must be struct");
    if (structure_info.@"struct".is_tuple)
        @compileError("`Structure` mustn't be tuple");
    if (structure_info.@"struct".decls.len != 0)
        @compileError("`Structure` mustn't any declarations");
    if (structure_info.@"struct".fields.len < 1)
        @compileError("`Structure` must have at least one field");

    for (structure_info.@"struct".fields) |field| {
        const field_type = blk: {
            if (@typeInfo(field.type) == .optional)
                break :blk @typeInfo(field.type).optional.child
            else {
                has_non_optional_fields = true;
                break :blk field.type;
            }
        };

        switch (@typeInfo(field_type)) {
            .bool, .int, .float => {},
            .@"enum" => |info| {
                if (!info.is_exhaustive)
                    @compileError("Unexhaustive enum field type found");
                if (info.decls.len != 0)
                    @compileError("Enum field type with declarations found");
            },
            else => {
                if (field_type != []const u8 and field_type != Time)
                    @compileError("Unsupported field type found");
            },
        }
    }

    const has_endorced_parameters = has_non_optional_fields;

    return struct {
        const QueryParametersType = @This();
        pub const parameters_type: ParametersType = .query;
        pub const structure = Structure;

        data: Structure,

        /// Parse QueryParameters from `request`
        pub fn parse(allocator: Allocator, request: *const Request, dest: *QueryParametersType) !void {
            if (comptime has_endorced_parameters)
                if (request.query == null)
                    return ParseError.MissingQuery;

            var parsed_params_count: usize = 0;
            const next_param_count =
                if (request.query == null)
                    0
                else blk: {
                    var count: usize = 0;

                    for (request.query.?) |char| {
                        if (char == '&')
                            count += 1;
                    }

                    break :blk count;
                };

            inline for (structure_info.@"struct".fields) |field| inline_loop: {
                const field_info = @typeInfo(field.type);
                const field_ptr = fieldPtr(Structure, field.name, &dest.data);

                if (request.query == null) {
                    if (comptime field_info != .optional)
                        unreachable;

                    field_ptr.* = null;
                    break :inline_loop;
                }

                const param_name = field.name ++ "=";
                const field_type =
                    if (field_info == .optional)
                        field_info.optional.child
                    else
                        field.type;

                // Get value of parameter
                var value_start_index = indexOf(u8, request.query.?, param_name) orelse {
                    if (comptime field.default_value_ptr == null) {
                        if (comptime field_info == .optional) {
                            field_ptr.* = null;
                            break :inline_loop;
                        }
                        return ParseError.MissingParameter;
                    }

                    field_ptr.* = field.defaultValue().?;
                    break :inline_loop;
                };
                value_start_index += param_name.len;

                const parameter_end_index = indexOfScalarPos(
                    u8,
                    request.query.?,
                    value_start_index,
                    '&',
                ) orelse request.query.?.len;

                if (value_start_index >= parameter_end_index)
                    return ParseError.MissingValue;

                const value = request.query.?[value_start_index..parameter_end_index];

                switch (@typeInfo(field_type)) {
                    inline .bool => {
                        // Bool
                        const is_true = eqlIgnoreCase(value, "true");
                        const is_false = eqlIgnoreCase(value, "false");

                        if (!(is_true or is_false))
                            return ParseError.InvalidBool;
                        field_ptr.* = is_true;
                    },
                    inline .int => {
                        // Integer
                        field_ptr.* = try parseInt(field_type, value, 10);
                    },
                    inline .float => {
                        // Float
                        field_ptr.* = try parseFloat(field_type, value);
                    },
                    inline .@"enum" => {
                        // Enum
                        field_ptr.* = stringToEnum(field_type, value) orelse
                            return ParseError.InvalidEnum;
                    },
                    inline else => {
                        if (comptime field_type == []const u8)
                            // String
                            field_ptr.* = try allocator.dupe(u8, value)
                        else if (comptime field_type == Time)
                            // Time
                            field_ptr.* = try Time.fromISO8601(value)
                        else
                            unreachable;
                    },
                }

                parsed_params_count += 1;
            }

            // Check if any excess parameters exist in `request.query`
            if (next_param_count + 1 != parsed_params_count)
                return ParseError.ExcessQuery;
        }
    };
}

pub fn isQueryParameters(comptime Type: type) bool {
    return isResourceParameters(Type) and Type.parameters_type == .query and
        QueryParameters(Type.structure) == Type;
}
