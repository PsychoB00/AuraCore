/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;
const Scanner = std.json.Scanner;
const ArrayList = std.ArrayList;

const comptimePrint = std.fmt.comptimePrint;
const parseInt = std.fmt.parseInt;
const parseFloat = std.fmt.parseFloat;
const eql = std.mem.eql;
const stringToEnum = std.meta.stringToEnum;
const utf8ValidateSlice = std.unicode.utf8ValidateSlice;

/// Aura
const core = @import("core.zig");

const fieldPtr = core.utils.fieldPtr;

/// Third Party
const zeit = @import("zeit");
const Time = zeit.Time;

/// Validates `Type` against AuraStandard
pub fn validateJsonType(comptime Type: type) !void {
    switch (@typeInfo(Type)) {
        .bool, .int, .float => {},
        .pointer => |info| {
            // For string, []const u8 is a slice and u8 is valid json type
            if (info.size != .slice)
                return error.NonslicePointer;
            if (!info.is_const)
                return error.NonconstPointer;

            return validateJsonType(info.child);
        },
        .optional => |info| return validateJsonType(info.child),
        .@"enum" => |info| {
            if (!info.is_exhaustive)
                return error.InexhaustiveEnum;
        },
        .@"struct" => |info| {
            if (Type == Time)
                return;

            if (info.is_tuple)
                return error.TupleFound;

            inline for (info.fields) |field| {
                return validateJsonType(field.type);
            }
        },
        else => return error.InvalidType,
    }
}

/// Validates `value` of `Type` against AuraStandard
pub fn validateValue(comptime Type: type, value: *const Type) !void {
    switch (@typeInfo(Type)) {
        inline .bool, .int, .float => {},
        inline .pointer => |pointer| {
            // For string, []const u8 is a slice and u8 is valid json type
            if (comptime pointer.size != .slice)
                return error.NonslicePointer;
            if (comptime !pointer.is_const)
                return error.NonconstPointer;

            if (comptime pointer.child == u8) {
                if (value.*.len == 0)
                    return error.StringTooShort;

                if (!utf8ValidateSlice(value.*))
                    return error.InvalidEncoding;
            } else {
                if (value.*.len == 0)
                    return error.ArrayToShort;

                for (value.*) |*element| {
                    try validateValue(pointer.child, element);
                }
            }
        },
        inline .optional => |optional| {
            if (value.* != null)
                try validateValue(optional.child, &(value.*.?));
        },
        inline .@"enum" => |@"enum"| {
            if (comptime !@"enum".is_exhaustive)
                return error.InexhaustiveEnum;
        },
        inline .@"struct" => |info| {
            if (comptime Type == Time)
                return;

            if (comptime info.is_tuple)
                return error.TupleFound;

            inline for (info.fields) |field| {
                const field_ptr = fieldPtr(Type, field.name, value);
                try validateValue(field.type, field_ptr);
            }
        },
        inline else => return error.InvalidType,
    }
}

/// Parses from `scanner` into `dest`
///
/// `allocator` MUST BE arena allocator
pub fn parseLeaky(comptime Type: type, comptime ArrayCapacity: usize, scanner: *Scanner, dest: *Type, allocator: Allocator) !void {
    comptime validateJsonType(Type) catch |err|
        @compileError(comptimePrint(
            "`Type` can't be represented in json, cause {s}",
            .{@errorName(err)},
        ));

    const token_type = try scanner.peekNextTokenType();

    switch (@typeInfo(Type)) {
        .bool => {
            // Bool
            if (!(token_type == .false or token_type == .true))
                return error.InvalidBool;

            const token = try scanner.next();
            dest.* = token == .true;
        },
        .int => {
            // Unsigned/signed integers
            if (token_type != .number)
                return error.InvalidInt;

            const token = try scanner.next();
            dest.* = try parseInt(Type, token.number, 10);
        },
        .float => {
            // Floats
            if (token_type != .number)
                return error.InvalidFloat;

            const token = try scanner.next();
            dest.* = try parseFloat(Type, token.number);
        },
        .pointer => |pointer| {
            if (Type == []const u8) {
                // String
                if (token_type != .string)
                    return error.InvalidString;

                const token = try scanner.next();
                dest.* = try allocator.dupe(u8, token.string);
            } else {
                // Array
                if (token_type != .array_begin)
                    return error.UnopenedArray;
                _ = try scanner.next();

                var list = try ArrayList(pointer.child).initCapacity(allocator, ArrayCapacity);

                while (true) {
                    const array_token_type = try scanner.peekNextTokenType();

                    if (array_token_type == .array_end) {
                        _ = try scanner.next();
                        break;
                    }

                    const element_ptr = try list.addOne(allocator);
                    try parseLeaky(pointer.child, ArrayCapacity, scanner, element_ptr, allocator);
                }

                dest.* = try list.toOwnedSlice(allocator);
            }
        },
        .optional => |optional| {
            // Optional
            if (token_type == .null) {
                _ = try scanner.next();
                dest.* = null;
                return;
            }

            try parseLeaky(optional.child, ArrayCapacity, scanner, &(dest.*.?), allocator);
        },
        .@"enum" => {
            // Enum
            if (token_type == .string)
                return error.InvalidEnum;

            const token = try scanner.next();
            dest.* = stringToEnum(Type, token.string) orelse
                return error.InvalidEnumLiteral;
        },
        .@"struct" => |@"struct"| {
            if (Type == Time) {
                // Time
                if (token_type == .string)
                    return error.InvalidTime;

                const token = try scanner.next();
                dest.* = try Time.fromISO8601(token.string);
            } else {
                // Struct
                if (token_type != .object_begin)
                    return error.UnopenedObject;
                _ = try scanner.next();

                var assigned_fields = [1]bool{false} ** @"struct".fields.len;

                while (true) {
                    const object_token_type = try scanner.peekNextTokenType();

                    if (object_token_type == .object_end) {
                        _ = try scanner.next();
                        break;
                    }
                    if (object_token_type != .string)
                        return error.MissingFieldName;

                    const field_name_token = try scanner.next();

                    inline for (@"struct".fields, 0..) |field, index| field_loop: {
                        if (!eql(u8, field.name, field_name_token.string))
                            break :field_loop;

                        const field_ptr = fieldPtr(Type, field.name, dest);
                        try parseLeaky(field.type, ArrayCapacity, scanner, field_ptr, allocator);

                        assigned_fields[index] = true;
                    }
                }

                inline for (@"struct".fields, 0..) |field, index| field_loop: {
                    if (assigned_fields[index])
                        break :field_loop;

                    if (@typeInfo(field.type) != .optional and field.defaultValue() == null)
                        return error.MissingField;

                    const field_ptr = fieldPtr(Type, field.name, dest);
                    field_ptr.* =
                        if (comptime @typeInfo(field.type) == .optional)
                            null
                        else
                            field.defaultValue().?;
                }
            }
        },
        else => unreachable,
    }
}
