/// STD
const std = @import("std");

const Writer = std.Io.Writer;
const WriterError = Writer.Error;
const Reader = std.Io.Reader;
const Allocator = std.mem.Allocator;

const isAscii = std.ascii.isAscii;
const isAlphanumeric = std.ascii.isAlphanumeric;
const utf8ValidateSlice = std.unicode.utf8ValidateSlice;
const percentEncode = std.Uri.Component.percentEncode;

/// Aura
const core = @import("../../core.zig");

const HttpHeaderType = core.net.headers.HttpHeaderType;
const uri = core.net.uri;

const assertValidate = core.utils.assertValidate;
const decodeUriStringtoUTF8 = uri.decodeUriStringtoUTF8;

/// Http header Location, indicates the URL to redirect a page to
pub const Location = struct {
    const max_url_len: usize = 253;

    pub const http_header_name: []const u8 = "location";
    pub const http_header_type: HttpHeaderType = .response;
    pub const max_value_len: usize = max_url_len;

    url: []const u8,

    fn _validateUrl(url: []const u8) !void {
        if (url.len == 0)
            return error.UrlTooShort;
        if (url.len > max_url_len)
            return error.UrlTooLong;
        if (!utf8ValidateSlice(url))
            return error.InvalidEncoding;

        for (url) |character| character_loop: {
            if (!isAscii(character) or isAlphanumeric(character))
                continue;

            inline for (uri.allowed_uri_characters) |allowed_character| {
                if (character == allowed_character)
                    break :character_loop;
            }

            return error.InvalidCharacter;
        }
    }

    pub fn validate(self: Location) anyerror!void {
        try _validateUrl(self.url);
    }

    /// Formats the header value to `writer`
    pub fn format(self: Location, writer: *Writer) WriterError!void {
        assertValidate(self.validate());

        try percentEncode(writer, self.url, isAscii);
    }

    /// Parses the header value from `reader`
    ///
    /// `allocator` MUST BE arena allocator, this parse is leaky
    pub fn parse(self: *Location, reader: *Reader, allocator: Allocator) anyerror!void {
        const url_value = try reader.take(reader.bufferedLen());

        if (url_value.len > max_url_len)
            return error.UrlToolong;

        self.url = try decodeUriStringtoUTF8(uri.allowed_uri_characters, url_value, allocator);

        try _validateUrl(self.url);
    }
};
