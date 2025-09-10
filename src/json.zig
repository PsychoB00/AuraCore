/// STD
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const comptimePrint = std.fmt.comptimePrint;

/// Aura
const core = @import("core.zig");

/// Third Party
const zeit = @import("zeit");
const Time = zeit.Time;

pub const ParseError = error{
    InvalidValueFormatting,
};

pub const ValidateTypeError = error{
    NonSlicePointer,
    InexhaustiveEnum,
    FoundTuple,
    UnsupportedType,
};

/// Validates `Type` against AuraStandard
///
/// - If is `AsValue` true, function returns error as ValidateTypeError, else compile error is thrown
pub fn validateJsonType(comptime Type: type, comptime AsValue: bool) if (AsValue) ValidateTypeError!void else void {
    switch (@typeInfo(Type)) {
        .bool, .int, .float => {},
        .pointer => |info| {
            // For string, []const u8 is a slice and u8 is valid json type
            if (info.size != .slice)
                if (AsValue)
                    return ValidateTypeError.NonSlicePointer
                else
                    @compileError(comptimePrint(
                        "Non-slice pointer found as {}",
                        .{Type},
                    ));

            return validateJsonType(info.child, AsValue);
        },
        .optional => |info| return validateJsonType(info.child, AsValue),
        .@"enum" => |info| {
            if (!info.is_exhaustive)
                if (AsValue)
                    return ValidateTypeError.InexhaustiveEnum
                else
                    @compileError(comptimePrint(
                        "Inexhaustive enum found as {}",
                        .{Type},
                    ));
        },
        .@"struct" => |info| {
            if (Type == Time)
                return;

            if (info.is_tuple)
                if (AsValue)
                    return ValidateTypeError.FoundTuple
                else
                    @compileError(comptimePrint(
                        "Tuple found as {}",
                        .{Type},
                    ));

            for (info.fields) |field| {
                return validateJsonType(field.type, AsValue);
            }
        },
        else => {
            if (AsValue)
                return ValidateTypeError.UnsupportedType
            else
                @compileError(comptimePrint(
                    "Unsupported type found as {}",
                    .{Type},
                ));
        },
    }
}

/// Parse json AnyValue to a value of `Type`
///
/// String values and array values allocated by this functions are owned by result, free them accordingly
pub fn asAny(comptime ParserType: type, comptime Type: type, value: *const ParserType.AnyValue, allocator: *const Allocator) !Type {
    assert(comptime assert_blk: {
        validateJsonType(ParserType, true) catch
            break :assert_blk false;
        break :assert_blk true;
    });

    switch (@typeInfo(Type)) {
        inline .bool => {
            // Bool
            if (value.* != .bool)
                return ParserType.Error.IncorrectType;

            return value.*.bool;
        },
        inline .int => {
            // Signed/Unsigned integer
            if (value.* != .number or value.*.number == .double)
                return ParserType.Error.IncorrectType;

            if (value.*.number.cast(Type)) |number|
                return number;

            return ParserType.Error.NumberOutOfRange;
        },
        inline .float => {
            // Floating point number
            if (value.* != .number)
                return ParserType.Error.IncorrectType;

            return value.*.number.lossyCast(Type);
        },
        inline .pointer => |info| {
            if (comptime Type == []const u8) {
                // String
                if (value.* != .string)
                    return ParserType.Error.IncorrectType;

                const string_value = try value.*.string.getTemporal();
                return try allocator.dupe(u8, string_value);
            }

            // Array
            if (value.* != .array)
                return ParserType.Error.IncorrectType;

            const array_len = try value.*.array.getSize();
            var res =
                std.ArrayList(info.child).initCapacity(allocator.*, array_len) catch
                    return ParserType.Error.OutOfMemory;
            var it = value.*.array.iterator();

            while (try it.next()) |elem| {
                const elem_value = try elem.asAny();
                res.appendAssumeCapacity(try asAny(
                    ParserType,
                    info.child,
                    &elem_value,
                    allocator,
                ));
            }

            return res.toOwnedSlice(allocator.*) catch return ParserType.Error.OutOfMemory;
        },
        inline .optional => |info| {
            // Default for optionals is null
            if (value.* == .null)
                return null;

            return try asAny(ParserType, info.child, value, allocator);
        },
        inline .@"enum" => {
            // Enum
            if (value.* != .string)
                return ParserType.Error.IncorrectType;

            const enum_value = try value.*.string.getTemporal();
            return std.meta.stringToEnum(Type, enum_value) orelse
                return ParseError.InvalidValueFormatting;
        },
        inline .@"struct" => |info| {
            if (comptime Type == Time) {
                // Time
                if (value.* != .string)
                    return ParserType.Error.IncorrectType;

                const time_value = try value.*.string.getTemporal();
                return Time.fromISO8601(time_value) catch
                    return ParseError.InvalidValueFormatting;
            }

            // Struct
            if (value.* != .object)
                return ParserType.Error.IncorrectType;

            var field_check_array = [1]bool{false} ** info.fields.len;

            var res: Type = undefined;
            var it = value.*.object.iterator();

            // Assign fields in json
            while (try it.next()) |json_field| {
                const field_name = try json_field.key.get();
                var field_found = false;

                inline for (info.fields, 0..) |field, index| field_loop: {
                    if (!std.mem.eql(u8, field_name, field.name))
                        break :field_loop;

                    field_found = true;
                    field_check_array[index] = true;
                    const field_value = try json_field.value.asAny();

                    core.utils.fieldPtr(
                        Type,
                        field.name,
                        &res,
                    ).* = try asAny(
                        ParserType,
                        field.type,
                        &field_value,
                        allocator,
                    );
                }

                if (!field_found)
                    return ParserType.Error.MissingField;
            }

            // Check for unassined field and assign defaults to them
            inline for (info.fields, 0..) |field, index| check_loop: {
                if (field_check_array[index])
                    break :check_loop;

                if (comptime field.default_value_ptr == null) {
                    if (comptime @typeInfo(field.type) == .optional) {
                        // Default for optionals is null
                        core.utils.fieldPtr(Type, field.name, &res).* = null;
                        break :check_loop;
                    }
                    return ParserType.Error.IncompleteObject;
                }

                core.utils.fieldPtr(Type, field.name, &res).* = field.defaultValue().?;
            }

            return res;
        },
        inline else => unreachable,
    }
}
