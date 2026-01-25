/// STD
const std = @import("std");

const Writer = std.Io.Writer;
const WriterError = Writer.Error;

const toUpper = std.ascii.toUpper;
const replaceScalar = std.mem.replaceScalar;

/// Third Party
const zap = @import("zap");

const StatusCode = zap.http.StatusCode;

pub const max_value_len: usize = 31;

pub fn statusCodeToUpper(comptime Status: StatusCode) []const u8 {
    const status_string = @tagName(Status);
    var res: [status_string.len]u8 = undefined;

    for (0..status_string.len) |index| {
        res[index] = toUpper(status_string[index]);
    }

    return res[0..];
}

pub fn format(self: StatusCode, writer: *Writer) WriterError!void {
    const status_string = @tagName(self);

    for (0..status_string.len) |index| {
        try writer.writeByte(toUpper(status_string[index]));
    }
}

pub fn isSuccess(self: StatusCode) bool {
    return @intFromEnum(self) >= 200 and @intFromEnum(self) < 300;
}

pub fn isRedirect(self: StatusCode) bool {
    return @intFromEnum(self) >= 300 and @intFromEnum(self) < 400;
}
