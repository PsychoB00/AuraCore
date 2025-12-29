/// STD
const std = @import("std");

const Writer = std.Io.Writer;
const WriterError = Writer.Error;

const Reader = std.Io.Reader;

/// Aura
const core = @import("../../core.zig");

const HttpHeaderType = core.net.headers.HttpHeaderType;
const MediaType = core.net.headers.MediaType;

const assertValidate = core.utils.assertValidate;

/// Http header Content-Type, is used to indicate the original media type of a resource
pub const ContentType = struct {
    pub const http_header_name: []const u8 = "content-type";
    pub const http_header_type: HttpHeaderType = .both;
    pub const max_value_len: usize = MediaType.max_value_len;

    media_type: MediaType,

    pub fn validate(self: ContentType) anyerror!void {
        if (self.media_type.isWildcard())
            return error.WildcardFound;
    }

    /// Formats the header value to `writer`
    pub fn format(self: ContentType, writer: *Writer) WriterError!void {
        assertValidate(self.validate());

        try self.media_type.format(writer);
    }

    /// Parses the header value from `reader`
    pub fn parse(self: *ContentType, reader: *Reader) anyerror!void {
        try self.media_type.parse(reader);

        try self.validate();
    }
};
