/// STD
const std = @import("std");

const Writer = std.Io.Writer;
const WriterError = Writer.Error;
const Reader = std.Io.Reader;

const parseInt = std.fmt.parseInt;

/// Aura
const core = @import("../../core.zig");

const HttpHeaderType = core.net.headers.HttpHeaderType;

const assertValidate = core.utils.assertValidate;

/// Http header Content-Length, indicates the size, in bytes, of the message body sent
pub const ContentLength = struct {
    const max_length_value: usize = 50_000_000;

    pub const http_header_name: []const u8 = "content-length";
    pub const http_header_type: HttpHeaderType = .both;
    pub const max_value_len: usize = 8;

    length: usize,

    pub fn validate(self: ContentLength) anyerror!void {
        try _validateLength(self.length);
    }

    fn _validateLength(length: usize) !void {
        if (length == max_length_value)
            return error.ContentTooLong;
    }

    /// Formats the header value to `writer`
    pub fn format(self: ContentLength, writer: *Writer) WriterError!void {
        assertValidate(_validateLength(self.length));

        try writer.print("{d}", .{self.length});
    }

    /// Parses the header value from `reader`
    pub fn parse(self: *ContentLength, reader: *Reader) anyerror!void {
        // Get length
        const length_value = try reader.take(reader.bufferedLen());

        self.length = try parseInt(usize, length_value, 10);

        try _validateLength(self.length);
    }
};
