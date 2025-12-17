/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;

const comptimePrint = std.fmt.comptimePrint;
const indexOfScalarPos = std.mem.indexOfScalarPos;
const lastIndexOfScalar = std.mem.lastIndexOfScalar;
const eql = std.mem.eql;
const parseInt = std.fmt.parseInt;

/// Aura
const core = @import("../core.zig");

const ParametersType = core.routing.ParametersType;

const fieldPtr = core.utils.fieldPtr;
const decodeUriStringtoUTF8 = core.net.decodeUriStringtoUTF8;
const isResourceParameters = core.routing.isResourceParameters;

/// Third Party
const zap = @import("zap");
const Request = zap.Request;

const zeit = @import("zeit");
const Time = zeit.Time;

/// Parameters defining the Resource's identity
///
/// - Fields of `Structure` represent individual parameters, they are order and case sensitive.
/// - First field in `Structure` must have the same name as the APIResource using it.
/// - Every parameter can be optional. If any parameter is optional, subsequent parameters must be optional as well.
/// - Parameters can be typed as unsigned integer, []const u8 or zeit.Time(ISO 8601).
/// - If a parameter is typed as []const u8, it will be in utf-8 encoding
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
                if (!(field_type == []const u8 or field_type == Time))
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
                return error.MissingPath;

            var reader = Reader.fixed(request.path.?[(StaticPath.len - structure_info.@"struct".fields[0].name.len) - 1 ..]);

            // Assign to fields of `dest.data`
            inline for (@typeInfo(Structure).@"struct".fields) |field| field_loop: {
                const info = @typeInfo(field.type);
                const field_type =
                    if (info == .optional)
                        info.optional.child
                    else
                        field.type;
                const field_ptr = fieldPtr(Structure, field.name, &dest.data);

                if (reader.bufferedLen() == 0) {
                    // Reader is empty, handle optional fields
                    if (info != .optional)
                        return error.MissingParameter;

                    field_ptr.* = null;
                    break :field_loop;
                } else if (reader.bufferedLen() < 4)
                    // Reader doesn't have minimal nessesary bytes for parameter
                    return error.ExcessPathTail;

                // Validate parameter leading delimiter
                const parameter_leading_delimiter_value = try reader.take(1);

                if (parameter_leading_delimiter_value[0] != '/')
                    return error.MissingLeadingDelimiter;

                // Validating parameter name
                const parameter_name_value = reader.takeDelimiterInclusive('/') catch |err| switch (err) {
                    error.EndOfStream => return error.MissingNameValueDelimiter,
                    else => return err,
                };

                if (!eql(u8, parameter_name_value, field.name ++ "/"))
                    return error.InvalidName;

                // Getting parameter value
                const parameter_value_value = reader.takeDelimiterExclusive('/') catch |err| switch (err) {
                    error.EndOfStream => return error.MissingValue,
                    else => return err,
                };

                if (parameter_value_value.len == 0)
                    return error.MissingValue;

                switch (@typeInfo(field_type)) {
                    // Unsigned integer
                    inline .int => field_ptr.* = try parseInt(field_type, parameter_value_value, 10),
                    inline else => {
                        const decoded_value = try decodeUriStringtoUTF8(parameter_value_value);

                        if (comptime field_type == []const u8)
                            // String
                            field_ptr.* = try allocator.dupe(u8, decoded_value)
                        else if (comptime field_type == Time)
                            // Time
                            field_ptr.* = try Time.fromISO8601(decoded_value)
                        else
                            unreachable;
                    },
                }
            }

            if (reader.bufferedLen() != 0)
                return error.ExcessPathTail;
        }
    };
}

/// Trait check for PathParameters
///
/// - `Type` must fullfil the isResourceParameters trait check
/// - Declaration `parameters_type` from ResourceParameters must have value ParametersType.path
/// - `Type` must be able to generate `Type` using its declarations and function PathParameters
pub fn isPathParameters(comptime Type: type) bool {
    const is_resource_parameters = isResourceParameters(Type);

    const is_path_parameters_type =
        is_resource_parameters and
        Type.parameters_type == .path;

    const can_generate_self =
        is_path_parameters_type and
        PathParameters(Type.structure) == Type;

    return is_resource_parameters and is_path_parameters_type and can_generate_self;
}
