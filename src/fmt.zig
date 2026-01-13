/// STD
const std = @import("std");

const indexOfScalar = std.mem.indexOfScalar;
const stdParseInt = std.fmt.parseInt;
const stdParseFloat = std.fmt.parseFloat;
const toUpper = std.ascii.toUpper;
const isHex = std.ascii.isHex;
const isDigit = std.ascii.isDigit;

pub fn hexCharToInt(character: u8) !u4 {
    if (!isHex(character))
        return error.NonHexCharacter;

    return if (isDigit(character))
        @as(u4, @truncate(character - '0'))
    else
        @as(u4, @truncate(toUpper(character) - 'A')) + 10;
}

/// Same as `std.fmt.parseInt` in base 10 but `_` is invalid character
pub fn parseInt(comptime Type: type, buffer: []const u8) !Type {
    if (indexOfScalar(u8, buffer, '_') != null)
        return error.InvalidCharacter;
    return stdParseInt(Type, buffer, 10);
}

/// Same as `std.fmt.parseFloat` but `_` is invalid character
pub fn parseFloat(comptime Type: type, buffer: []const u8) !Type {
    if (indexOfScalar(u8, buffer, '_') != null)
        return error.InvalidCharacter;
    return stdParseFloat(Type, buffer);
}
