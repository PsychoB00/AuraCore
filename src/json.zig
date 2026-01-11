/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;
const Scanner = std.json.Scanner;
const ArrayList = std.ArrayList;
const Writer = std.Io.Writer;

const comptimePrint = std.fmt.comptimePrint;
const maxInt = std.math.maxInt;
const floatMantissaBits = std.math.floatMantissaBits;
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

const fromISO8601 = Time.fromISO8601;

pub const JsonInterpreterOptions = struct {
    max_field_name_len: usize = 64,
    max_string_len: usize = 1024,
    array_capacity: usize = 1024,
    array_allocate_capacity: usize = 16,
};

pub fn JsonInterpreter(comptime Options: JsonInterpreterOptions) type {
    return struct {
        pub const options = Options;

        /// Validates `Type` against Options
        pub fn validateType(comptime Type: type) !void {
            switch (@typeInfo(Type)) {
                .bool, .int, .float => {},
                .pointer => |info| {
                    // For string, []const u8 is a slice and u8 is valid json type
                    if (info.size != .slice)
                        return error.NonslicePointer;
                    if (!info.is_const)
                        return error.NonconstPointer;

                    return validateType(info.child);
                },
                .optional => |info| return validateType(info.child),
                .@"enum" => |info| {
                    if (!info.is_exhaustive)
                        return error.InexhaustiveEnum;
                    if (info.fields.len == 0)
                        return error.TooFewEnumLiterals;
                },
                .@"struct" => |info| {
                    if (Type == Time)
                        return;

                    if (info.is_tuple)
                        return error.TupleFound;
                    if (info.fields.len == 0)
                        return error.TooFewFields;

                    inline for (info.fields) |field| {
                        if (field.name.len == 0)
                            return error.FieldNameTooShort;
                        if (field.name.len > Options.max_field_name_len)
                            return error.FieldNameTooLong;

                        return validateType(field.type);
                    }
                },
                else => return error.InvalidType,
            }
        }

        /// Validates `value` of `Type` against Options
        pub fn validateValue(comptime Type: type, value: *const Type) !void {
            // `Type` corretness assertion
            comptime validateType(Type) catch |err|
                @compileError(comptimePrint(
                    "`Type` can't be represented in json, cause {s}",
                    .{@errorName(err)},
                ));

            switch (@typeInfo(Type)) {
                inline .bool, .int, .float => {},
                inline .pointer => |pointer| {
                    if (comptime pointer.child == u8) {
                        // String
                        if (value.*.len == 0)
                            return error.StringTooShort;
                        if (value.*.len > Options.max_string_len)
                            return error.StringTooLong;

                        if (!utf8ValidateSlice(value.*))
                            return error.InvalidEncoding;
                    } else {
                        // Array
                        if (value.*.len == 0)
                            return error.TooFewArrayElements;
                        if (value.*.len > Options.array_capacity)
                            return error.TooManyArrayElements;

                        for (value.*) |*element| {
                            try validateValue(pointer.child, element);
                        }
                    }
                },
                inline .optional => |optional| {
                    if (value.* != null)
                        try validateValue(optional.child, &(value.*.?));
                },
                inline .@"enum" => {},
                inline .@"struct" => |info| {
                    if (comptime Type == Time)
                        return;

                    inline for (info.fields) |field| {
                        const field_ptr = fieldPtr(Type, field.name, value);
                        try validateValue(field.type, field_ptr);
                    }
                },
                inline else => unreachable,
            }
        }

        pub fn calculateMaxValueLen(comptime Type: type) usize {
            switch (@typeInfo(Type)) {
                .bool => return 5,
                .int => return @as(usize, @intFromFloat(@floor(@log10(@as(comptime_float, @floatCast(maxInt(Type))))))) + 1,
                .float => return (floatMantissaBits(Type) + 1) * @log10(2),
                .pointer => |info| if (Type == []const u8)
                    return Options.max_string_len + 2
                else
                    return (Options.array_capacity * (calculateMaxValueLen(info.child) + 1)) + 2,
                .optional => |info| return calculateMaxValueLen(info.child),
                .@"enum" => |info| {
                    var res: usize = 0;

                    inline for (info.fields) |field| field_loop: {
                        if (field.name.len <= res)
                            break :field_loop;

                        res = field.name.len;
                    }

                    return res + 2;
                },
                .@"struct" => |info| {
                    if (Type == Time)
                        return 25 + 2;

                    var res: usize = 0;

                    inline for (info.fields) |field| {
                        res += (Options.max_field_name_len + 1) + 1 + calculateMaxValueLen(field.type) + 1;
                    }

                    return res + 2;
                },
                else => unreachable,
            }
        }

        /// Parses from `src` into `dest`
        ///
        /// `allocator` MUST BE arena allocator or simular
        pub fn parseLeaky(comptime Type: type, src: *const []const u8, dest: *Type, allocator: Allocator) !void {
            comptime validateType(Type) catch |err|
                @compileError(comptimePrint(
                    "`Type` can't be represented in json, cause {s}",
                    .{@errorName(err)},
                ));

            var scanner = Scanner.initCompleteInput(allocator, src.*);
            defer scanner.deinit();

            try _parseLeakyToken(Type, &scanner, dest, allocator);

            const end_of_document_token = try scanner.next();
            if (end_of_document_token != .end_of_document)
                return error.UnclosedDocument;

            try validateValue(Type, dest);
        }

        fn _parseLeakyToken(comptime Type: type, scanner: *Scanner, dest: *Type, allocator: Allocator) !void {
            const token_type = try scanner.peekNextTokenType();

            switch (@typeInfo(Type)) {
                inline .bool => {
                    // Bool
                    if (!(token_type == .false or token_type == .true))
                        return error.InvalidBool;

                    const token = try scanner.next();
                    dest.* = token == .true;
                },
                inline .int => {
                    // Unsigned/signed integer
                    if (token_type != .number)
                        return error.InvalidInt;

                    const token = try scanner.next();
                    dest.* = try parseInt(Type, token.number, 10);
                },
                inline .float => {
                    // Float
                    if (token_type != .number)
                        return error.InvalidFloat;

                    const token = try scanner.next();
                    dest.* = try parseFloat(Type, token.number);
                },
                inline .pointer => |pointer| {
                    if (comptime Type == []const u8) {
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

                        var list = try ArrayList(pointer.child).initCapacity(allocator, Options.array_allocate_capacity);

                        while (true) {
                            const array_token_type = try scanner.peekNextTokenType();

                            if (array_token_type == .array_end) {
                                _ = try scanner.next();
                                break;
                            }

                            const element_ptr = try list.addOne(allocator);
                            try _parseLeakyToken(pointer.child, scanner, element_ptr, allocator);
                        }

                        dest.* = try list.toOwnedSlice(allocator);
                    }
                },
                inline .optional => |optional| {
                    // Optional
                    if (token_type == .null) {
                        _ = try scanner.next();
                        dest.* = null;
                        return;
                    }

                    try _parseLeakyToken(optional.child, scanner, &(dest.*.?), allocator);
                },
                inline .@"enum" => {
                    // Enum
                    if (token_type != .string)
                        return error.InvalidEnum;

                    const token = try scanner.next();
                    dest.* = stringToEnum(Type, token.string) orelse
                        return error.InvalidEnumLiteral;
                },
                inline .@"struct" => |@"struct"| {
                    if (comptime Type == Time) {
                        // Time
                        if (token_type != .string)
                            return error.InvalidTime;

                        const token = try scanner.next();
                        dest.* = try fromISO8601(token.string);
                    } else {
                        // Struct
                        if (token_type != .object_begin)
                            return error.UnopenedObject;
                        _ = try scanner.next();

                        var assigned_fields = [1]bool{false} ** @"struct".fields.len;

                        while (true) while_loop: {
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
                                try _parseLeakyToken(field.type, scanner, field_ptr, allocator);

                                assigned_fields[index] = true;
                                break :while_loop;
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

        /// Formats `src` into `dest`
        ///
        /// `allocator` MUST BE arena allocator or simular
        pub fn formatLeaky(comptime Type: type, src: *const Type, dest: *[]u8, allocator: Allocator) !void {
            comptime validateType(Type) catch |err|
                @compileError(comptimePrint(
                    "`Type` can't be represented in json, cause {s}",
                    .{@errorName(err)},
                ));

            const max_value_len = comptime calculateMaxValueLen(Type);

            try validateValue(Type, src);

            var buffer: [max_value_len]u8 = undefined;
            var writer = Writer.fixed(&buffer);

            try _formatToken(Type, &writer, src);

            dest.* = try allocator.dupe(u8, writer.buffered());
        }

        fn _formatToken(comptime Type: type, writer: *Writer, src: *const Type) !void {
            switch (@typeInfo(Type)) {
                inline .bool => {
                    // Bool
                    try writer.writeAll(if (src.*) "true" else "false");
                },
                inline .int, .float => {
                    // Unsigned/signed integer or float
                    try writer.print("{d}", .{src.*});
                },
                inline .pointer => |pointer| {
                    if (comptime Type != []const u8) {
                        // Array
                        try writer.writeByte('[');

                        for (src.*) |*element| {
                            try _formatToken(pointer.child, writer, element);
                            try writer.writeByte(',');
                        }
                        writer.undo(1);

                        try writer.writeByte(']');
                    } else
                    // String
                    try writer.print("\"{s}\"", .{src.*});
                },
                inline .optional => |optional| {
                    // Optional
                    if (src.* == null) {
                        try writer.writeAll("null");
                        return;
                    }

                    try _formatToken(optional.child, writer, &(src.*.?));
                },
                inline .@"enum" => {
                    // Enum
                    try writer.print("\"{s}\"", .{@tagName(src.*)});
                },
                inline .@"struct" => |@"struct"| {
                    if (comptime Type == Time) {
                        // Time
                        try src.*.strftime(writer, "\"%FT%T");

                        if (src.*.millisecond != 0)
                            try writer.print(".{d:0>3}", .{src.*.millisecond});
                        if (src.*.offset != 0)
                            try src.*.strftime(writer, "%z")
                        else
                            try writer.writeByte('Z');

                        try writer.writeByte('\"');
                        return;
                    }

                    // Struct
                    try writer.writeByte('{');

                    inline for (@"struct".fields) |field| {
                        const field_ptr = fieldPtr(Type, field.name, src);

                        try writer.writeAll("\"" ++ field.name ++ "\":");
                        try _formatToken(field.type, writer, field_ptr);
                        try writer.writeByte(',');
                    }
                    writer.undo(1);

                    try writer.writeByte('}');
                },
                else => unreachable,
            }
        }
    };
}

pub const DefaultJsonInterpreter = JsonInterpreter(.{});
