/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;

const assert = std.debug.assert;
const isAlphanumeric = std.ascii.isAlphanumeric;
const utf8Decode2 = std.unicode.utf8Decode2;
const utf8Decode3 = std.unicode.utf8Decode3;
const utf8Decode4 = std.unicode.utf8Decode4;

/// Aura
const core = @import("../core.zig");

const hexCharToInt = core.utils.hexCharToInt;

pub const allowed_path_characters: []const u8 = "-._~!$&'()*+,;=:@/";

/// Tries to decode `string` to utf-8
///
/// `string` mustn't be longer the 253 bytes
pub fn decodeUriStringtoUTF8(comptime allowed_characters: []const u8, string: []const u8, allocator: Allocator) ![]const u8 {
    var buffer: [253]u8 = undefined;
    var index_offset: usize = 0;
    var current_percent_index: ?usize = null;
    var current_codepoints: [4]u8 = undefined;
    var current_codepoint_count: usize = 0;

    for (string, 0..) |character, index| {
        if (current_percent_index) |percent_index| {
            if (percent_index - index_offset >= 253)
                return error.StringTooLong;

            const current_index_offset: u3 = @truncate(index - percent_index);
            buffer[percent_index - index_offset] |=
                @as(u8, try hexCharToInt(character)) << ((current_index_offset % 2) * 4);

            if (current_index_offset == 2) {
                current_codepoints[current_codepoint_count] = buffer[percent_index - index_offset];
                current_codepoint_count += 1;

                if (index == string.len - 1 or string[index + 1] != '%') {
                    _ = switch (current_codepoint_count) {
                        1 => @as(u21, current_codepoints[0]),
                        2 => utf8Decode2(current_codepoints[0..2].*),
                        3 => utf8Decode3(current_codepoints[0..3].*),
                        4 => utf8Decode4(current_codepoints[0..4].*),
                        else => return error.InvalidEncoding,
                    } catch return error.InvalidEncoding;

                    current_codepoint_count = 0;
                }

                current_percent_index = null;
                index_offset += 2;
            }

            continue;
        }

        if (index - index_offset >= 253)
            return error.StringTooLong;

        if (character == '%') {
            buffer[index - index_offset] = 0;
            current_percent_index = index;
            continue;
        }

        if (!isAlphanumeric(character)) allowed_characters_blk: {
            inline for (allowed_characters) |allowed_character| {
                if (allowed_character == character)
                    break :allowed_characters_blk;
            }

            return error.InvalidCharacter;
        }

        buffer[index - index_offset] = character;
    }

    return try allocator.dupe(u8, buffer[0 .. string.len - index_offset]);
}
