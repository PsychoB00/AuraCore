/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;

const comptimePrint = std.fmt.comptimePrint;
const indexOfScalarPos = std.mem.indexOfScalarPos;
const lastIndexOfScalar = std.mem.lastIndexOfScalar;
const eql = std.mem.eql;
const parseInt = std.fmt.parseInt;

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
    MissingPath,
    MissingParameter,
    MissingValue,
    ExcessPath,
};

/// Parameters defining the Resource's identity
///
/// - Fields of `Structure` represent individual parameters, they are order sensitive.
/// - First field in `Structure` must have the same name as the APIResource using it.
/// - Every parameter can be optional. If any parameter is optional, subsequent parameters must be optional as well.
/// - Parameters can be typed as unsigned integer, string or zeit.Time(ISO 8601).
/// - If any memory needs to be allocated during parsing of `Structure`, it will be allocated with
///   arena allocator provided by zap.Request, so no deallocation is nessesary. However this binds
///   the lifetime of the memory to lifetime of the zap.Request.
pub fn PathParameters(comptime Structure: type) type {
    // `Structure` correctness assertion
    const structure_info = @typeInfo(Structure);
    var has_optional_fields = false;

    if (structure_info != .@"struct")
        @compileError("`Structure` must be struct");
    if (structure_info.@"struct".is_tuple)
        @compileError("`Structure` mustn't be tuple");
    if (structure_info.@"struct".decls.len != 0)
        @compileError("`Structure` mustn't any declarations");
    if (structure_info.@"struct".fields.len < 1)
        @compileError("`Structure` must have at least one field");

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
        const PathParametersType = @This();
        pub const parameters_type: ParametersType = .path;
        pub const structure = Structure;

        data: Structure,

        pub fn parse(comptime StaticPath: []const u8, allocator: Allocator, request: *const Request, dest: *PathParametersType) !void {
            // `StaticPath` correctness assertion
            comptime {
                if (StaticPath.len == 0)
                    @compileError("`StaticPath.len` musn't be zero");
                if (StaticPath[StaticPath.len - 1] == '/')
                    @compileError("`StaticPath` musn't end with '/'");
                if (StaticPath.len < structure_info.@"struct".fields[0].name.len)
                    @compileError("`StaticPath.len` is less then the name length of the first parameter");

                if (lastIndexOfScalar(u8, StaticPath, '/')) |static_parameter_start_index| {
                    if (!eql(u8, StaticPath[(static_parameter_start_index + 1)..], structure_info.@"struct".fields[0].name))
                        @compileError(comptimePrint(
                            "Static parameter name ({s}) doesn't match the name of the first parameter ({s})",
                            .{ StaticPath[(static_parameter_start_index + 1)..], structure_info.@"struct".fields[0].name },
                        ));
                } else {
                    if (!eql(u8, StaticPath, structure_info.@"struct".fields[0].name))
                        @compileError(comptimePrint(
                            "Static parameter name ({s}) doesn't match the name of the first parameter ({s})",
                            .{ StaticPath, structure_info.@"struct".fields[0].name },
                        ));
                }
            }

            if (request.path == null)
                return ParseError.MissingPath;

            var parameter_start_index = StaticPath.len - structure_info.@"struct".fields[0].name.len;
            var parsed_params_count: usize = 0;
            const next_param_count =
                blk: {
                    var count: usize = 0;

                    for (request.path.?[parameter_start_index..]) |char| {
                        if (char == '/')
                            count += 1;
                    }

                    break :blk count;
                };
            var null_optional_found: bool = false;

            inline for (structure_info.@"struct".fields) |field| inline_loop: {
                const field_info = @typeInfo(field.type);
                const field_type =
                    if (field_info == .optional)
                        field_info.optional.child
                    else
                        field.type;

                const field_ptr = fieldPtr(Structure, field.name, &dest.data);

                if (null_optional_found) {
                    if (comptime field_info != .optional)
                        unreachable;

                    field_ptr.* = null;
                    break :inline_loop;
                }

                // Get value of parameter
                var value_start_index: usize = indexOfScalarPos(
                    u8,
                    request.path.?,
                    parameter_start_index,
                    '/',
                ) orelse {
                    if (field_info != .optional)
                        return ParseError.MissingParameter;

                    null_optional_found = true;
                    field_ptr.* = null;
                    break :inline_loop;
                };
                value_start_index += 1;

                if (!eql(u8, request.path.?[parameter_start_index..(value_start_index - 1)], field.name))
                    return ParseError.MissingParameter;

                const parameter_end_index = indexOfScalarPos(
                    u8,
                    request.path.?,
                    value_start_index,
                    '/',
                ) orelse request.path.?.len;

                if (value_start_index >= parameter_end_index)
                    return ParseError.MissingValue;

                const value = request.path.?[value_start_index..parameter_end_index];

                switch (@typeInfo(field_type)) {
                    inline .int => {
                        // Unsigned integer
                        field_ptr.* = try parseInt(field_type, value, 10);
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

                parameter_start_index = parameter_end_index + 1;
                parsed_params_count += 2;
            }

            // Check if any excess parameters exist in `request.path`
            if (next_param_count + 1 != parsed_params_count)
                return ParseError.ExcessPath;
        }
    };
}

pub fn isPathParameters(comptime Type: type) bool {
    return isResourceParameters(Type) and Type.parameters_type == .path and
        PathParameters(Type.structure) == Type;
}
