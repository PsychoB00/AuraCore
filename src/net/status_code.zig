/// STD
const std = @import("std");

const toUpper = std.ascii.toUpper;
const replaceScalar = std.mem.replaceScalar;

/// Third Party
const zap = @import("zap");

const StatusCode = zap.http.StatusCode;

pub fn statusCodeToLower(comptime Status: StatusCode) []const u8 {
    return replaceScalar(u8, @tagName(Status), '_', ' ');
}

pub fn statusCodeToUpper(comptime Status: StatusCode) []const u8 {
    const status_string = @tagName(Status);
    var res: [status_string.len]u8 = undefined;

    for (0..status_string.len) |index| {
        res[index] = toUpper(status_string[index]);
    }

    return res[0..];
}
