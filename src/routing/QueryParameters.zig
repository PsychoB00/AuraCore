/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;

const indexOf = std.mem.indexOf;
const indexOfScalarPos = std.mem.indexOfScalarPos;
const eql = std.mem.eql;
const eqlIgnoreCase = std.ascii.eqlIgnoreCase;
const stringToEnum = std.meta.stringToEnum;

/// Aura
const core = @import("../core.zig");

const ParametersType = core.routing.ParametersType;

const fieldPtr = core.utils.fieldPtr;
const decodeUriStringtoUTF8 = core.net.uri.decodeUriStringtoUTF8;
const isResourceParameters = core.routing.isResourceParameters;
const validateTime = core.time.validate;
const parseFloat = core.fmt.parseFloat;
const parseInt = core.fmt.parseInt;

const allowed_path_characters = core.net.uri.allowed_path_characters;

/// Third Party
const zap = @import("zap");
const Request = zap.Request;

const zeit = @import("zeit");
const Time = zeit.Time;

/// Parameters defining the Resource's filters
///
/// - Fields of `Structure` represent individual parameters, they are order insensitive and case sensitive.
/// - Every parameter can be optional.
/// - Parameters can be typed as bool, integer, float, enum, []const u8 or zeit.Time(ISO 8601).
/// - If a parameter is typed as []const u8, it will be in utf-8 encoded.
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
        @compileError("`Structure` must have at least one fields");

    for (structure_info.@"struct".fields) |field| {
        const field_type = blk: {
            if (@typeInfo(field.type) == .optional)
                break :blk @typeInfo(field.type).optional.child
            else {
                has_non_optional_fields = field.defaultValue() == null;
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

    const has_enforced_parameters = has_non_optional_fields;

    return struct {
        const QueryParametersType = @This();
        pub const parameters_type: ParametersType = .query;
        pub const structure = Structure;

        data: Structure,

        pub fn parse(
            request: *const Request,
            dest: *QueryParametersType,
            allocator: Allocator,
        ) !void {
            if (comptime has_enforced_parameters)
                if (request.query == null)
                    return error.MissingQuery;

            var assigned_fields = [1]bool{false} ** structure_info.@"struct".fields.len;
            var reader = Reader.fixed(request.query orelse "");

            reader_loop: while (true) {
                if (reader.bufferedLen() == 0)
                    break :reader_loop;
                if (reader.bufferedLen() < 3)
                    // `reader` doesn't have minimal nessesary bytes for parameter
                    return error.ExcessQueryTail;

                // Validating parameter name
                const parameter_name_value = reader.takeDelimiterInclusive('=') catch |err| switch (err) {
                    error.EndOfStream => return error.MissingNameValueDelimiter,
                    else => return err,
                };

                var is_valid_name: bool = false;

                inline for (structure_info.@"struct".fields, 0..) |field, field_index| field_loop: {
                    if (!eql(u8, parameter_name_value, field.name ++ "="))
                        break :field_loop;

                    if (assigned_fields[field_index])
                        return error.DuplicateParameters;

                    const field_type =
                        if (@typeInfo(field.type) == .optional)
                            @typeInfo(field.type).optional.child
                        else
                            field.type;
                    const field_ptr = fieldPtr(Structure, field.name, &dest.data);

                    // Getting parameter value
                    const parameter_value_value = reader.takeDelimiterExclusive('&') catch |err| switch (err) {
                        error.EndOfStream => return error.MissingValue,
                        else => return err,
                    };

                    if (parameter_value_value.len == 0)
                        return error.MissingValue;

                    switch (@typeInfo(field_type)) {
                        inline .bool => {
                            // Bool
                            const is_true = eqlIgnoreCase(parameter_value_value, "true");
                            const is_false = eqlIgnoreCase(parameter_value_value, "false");

                            if (!(is_true or is_false))
                                return error.InvalidBool;
                            field_ptr.* = is_true;
                        },
                        inline .int => {
                            // Integer
                            field_ptr.* = try parseInt(field_type, parameter_value_value);
                        },
                        inline .float => {
                            // Float
                            field_ptr.* = try parseFloat(field_type, parameter_value_value);
                        },
                        inline .@"enum" => {
                            // Enum
                            field_ptr.* = stringToEnum(field_type, parameter_value_value) orelse
                                return error.InvalidEnum;
                        },
                        inline else => {
                            const decoded_value = try decodeUriStringtoUTF8(allowed_path_characters, parameter_value_value, allocator);

                            if (comptime field_type == Time) {
                                // Time
                                field_ptr.* = try Time.fromISO8601(decoded_value);
                                try validateTime(field_ptr.*);
                            } else if (comptime field_type == []const u8)
                                // String
                                field_ptr.* = decoded_value
                            else
                                unreachable;
                        },
                    }

                    is_valid_name = true;
                    assigned_fields[field_index] = true;

                    // Validate interparameter delimiter
                    if (reader.bufferedLen() >= 3) {
                        const interparameter_delimiter = try reader.takeByte();

                        if (interparameter_delimiter != '&')
                            return error.MissingInterparameterDelimiter;
                    }
                }

                if (!is_valid_name)
                    return error.InvalidName;
            }

            // Reader is empty, handle optional fields
            inline for (structure_info.@"struct".fields, 0..) |field, index| check_loop: {
                if (assigned_fields[index])
                    break :check_loop;

                const info = @typeInfo(field.type);

                if (!(info == .optional or field.defaultValue() != null))
                    return error.MissingParameter;

                const field_ptr = fieldPtr(Structure, field.name, &dest.data);

                if (field.defaultValue()) |default_value| {
                    field_ptr.* = default_value;
                } else {
                    field_ptr.* = null;
                }
            }
        }
    };
}

/// Trait check for QueryParameters
///
/// - `Type` must fullfil the isResourceParameters trait check
/// - Declaration `parameters_type` from ResourceParameters must have value ParametersType.query
/// - `Type` must be able to generate `Type` using its declarations and function QueryParameters
pub fn isQueryParameters(comptime Type: type) bool {
    if (!isResourceParameters(Type))
        return false;

    const is_query_parameters_type =
        Type.parameters_type == .query;

    const can_generate_self =
        is_query_parameters_type and
        QueryParameters(Type.structure) == Type;

    return is_query_parameters_type and can_generate_self;
}
