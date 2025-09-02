/// STD
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Aura
pub const json = @This();

const core = @import("core.zig");

/// Third Party
const zimdjson = @import("zimdjson");

const zeit = @import("zeit");
const Time = zeit.Time;

pub fn asAny(comptime ParserType: type, comptime Type: type, value: *const ParserType.AnyValue, allocator: *const Allocator) !Type {
    switch (@typeInfo(Type)) {
        inline .bool => {
            if (value.* != .bool)
                return ParserType.Error.IncorrectType;

            return value.*.bool;
        },
        inline .int => {
            if (value.* != .number or value.*.number == .double)
                return ParserType.Error.IncorrectType;

            if (value.*.number.cast(Type)) |number|
                return number;

            return ParserType.Error.NumberOutOfRange;
        },
        inline .float => {
            if (value.* != .number)
                return ParserType.Error.IncorrectType;

            return value.*.number.lossyCast(Type);
        },
        inline .optional => |info| {
            if (value.* == .null)
                return null;

            return try asAny(ParserType, info.child, value, allocator);
        },
        inline .@"struct" => |info| {
            if (comptime Type == Time) {
                if (value.* != .string)
                    return ParserType.Error.IncorrectType;

                const time_value = try value.*.string.get();
                return Time.fromISO8601(time_value) catch
                    return ParserType.Error.IncorrectType;
            }

            if (value.* != .object)
                return ParserType.Error.IncorrectType;

            var field_check_array = [1]bool{false} ** info.fields.len;

            var res: Type = undefined;
            var it = value.*.object.iterator();

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

            inline for (info.fields, 0..) |field, index| check_loop: {
                if (field_check_array[index])
                    break :check_loop;

                if (comptime field.default_value_ptr == null) {
                    if (comptime @typeInfo(field.type) == .optional) {
                        core.utils.fieldPtr(Type, field.name, &res).* = null;
                        break :check_loop;
                    }
                    return ParserType.Error.IncompleteObject;
                }

                core.utils.fieldPtr(Type, field.name, &res).* = field.defaultValue().?;
            }

            return res;
        },
        inline .pointer => |info| {
            if (comptime Type == []const u8) {
                if (value.* != .string)
                    return ParserType.Error.IncorrectType;

                return try value.*.string.get();
            }

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
        inline else => unreachable,
    }
}
