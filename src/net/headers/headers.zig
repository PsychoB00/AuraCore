/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;

const Writer = std.Io.Writer;
const WriterError = Writer.Error;
const Reader = std.Io.Reader;

const assert = std.debug.assert;
const isAscii = std.ascii.isAscii;
const isAlphanumeric = std.ascii.isAlphanumeric;
const utf8ValidateSlice = std.unicode.utf8ValidateSlice;
const hasMethod = std.meta.hasMethod;
const eql = std.mem.eql;
const eqlIgnoreCase = std.ascii.eqlIgnoreCase;
const trimStart = std.mem.trimStart;

/// Aura
const core = @import("../../core.zig");

const JsonInterpreter = core.json.DefaultJsonInterpreter;

const validateJsonType = JsonInterpreter.validateType;

pub const Host = @import("Host.zig").Host;
pub const UserAgent = @import("UserAgent.zig").UserAgent;

pub const ContentLength = @import("ContentLength.zig").ContentLength;
pub const ContentType = @import("ContentType.zig").ContentType;

pub const Authorization = @import("Authorization.zig").Authorization;

pub const HttpHeaderType = enum {
    request,
    response,
    both,
};

/// Checks if `token` fulfills RFC token definition
///
/// - NOTE: doesn't validate `token.len`
pub fn validateRFCToken(token: []const u8) !void {
    const allowed_characters = "!#$%&'*+-.^_`|~";

    for (token) |character| characters_loop: {
        if (isAlphanumeric(character))
            break :characters_loop;

        inline for (allowed_characters) |allowed_character| {
            if (character == allowed_character)
                break :characters_loop;
        }

        return error.InvalidCharacter;
    }
}

const MediaTypeTag = enum {
    application,
    text,
    wildcard,
};

/// Http header token assosiated with Content-Type and Accept
pub const MediaType = union(MediaTypeTag) {
    const ApplicationSubtypeTag = enum {
        json,
        wildcard,
    };

    pub const ApplicationSubtype = union(ApplicationSubtypeTag) {
        pub const max_value_len: usize = 4;

        json: void,
        wildcard: void,

        pub fn validateType(comptime Self: ApplicationSubtype, comptime Type: type) !void {
            switch (Self) {
                .json, .wildcard => try validateJsonType(Type),
            }
        }

        pub fn isWildcard(self: ApplicationSubtype) bool {
            return self == .wildcard;
        }

        pub fn areOverlapping(a: ApplicationSubtype, b: ApplicationSubtype) bool {
            if (a == .wildcard or b == .wildcard)
                return true;

            switch (a) {
                .json => return b == .json,
                .wildcard => unreachable,
            }
        }

        pub fn format(self: ApplicationSubtype, writer: *Writer) WriterError!void {
            switch (self) {
                .json => try writer.writeAll("json"),
                .wildcard => try writer.writeByte('*'),
            }
        }

        pub fn parse(self: *ApplicationSubtype, reader: *Reader) anyerror!void {
            const application_subtype_value = try reader.takeDelimiterExclusive(';');

            if (eqlIgnoreCase(application_subtype_value, "json")) {
                self.* = .json;
            } else if (eql(u8, application_subtype_value, "*")) {
                self.* = .wildcard;
            } else return error.InvalidApplicationSubtype;
        }
    };

    const TextSubtypeTag = enum {
        plain,
        html,
        wildcard,
    };

    pub const TextSubtype = union(TextSubtypeTag) {
        pub const Charset = enum {
            const min_value_len: usize = 5;

            pub const max_value_len: usize = 8;

            utf_8,
            us_ascii,

            pub fn validateText(self: Charset, text: []const u8) !void {
                switch (self) {
                    .utf_8 => {
                        if (!utf8ValidateSlice(text))
                            return error.InvalidEncoding;
                    },
                    .us_ascii => {
                        for (text) |character| {
                            if (!isAscii(character))
                                return error.InvalidEncoding;
                        }
                    },
                }
            }

            pub fn format(self: Charset, writer: *Writer) WriterError!void {
                try writer.writeAll("charset=");

                switch (self) {
                    .utf_8 => try writer.writeAll("utf-8"),
                    .us_ascii => try writer.writeAll("us-ascii"),
                }
            }

            /// If charset value exists in reader this function will parse it
            ///
            /// - `self` must be pointing to null
            pub fn tryParse(self: *?Charset, reader: *Reader) anyerror!void {
                assert(self.* == null);

                if (reader.bufferedLen() < 9 + min_value_len)
                    // `reader` doesn't have minimum nessesary characters
                    return;

                const subtype_parameter_delimiter = try reader.peekByte();

                if (subtype_parameter_delimiter != ';')
                    return error.InvalidSubtypeParameterDelimiter;

                const untrimed_parameter_name_value = reader.peekDelimiterInclusive('=') catch |err| switch (err) {
                    error.EndOfStream => return,
                    else => return err,
                };

                const parameter_name_value = trimStart(u8, untrimed_parameter_name_value[1..], " \t");

                if (!eqlIgnoreCase(parameter_name_value, "charset="))
                    // `reader` doesn't contain charset
                    return;

                reader.toss(untrimed_parameter_name_value.len);

                const parameter_value_value = try reader.takeDelimiterExclusive(';');

                if (eqlIgnoreCase(parameter_value_value, "utf-8")) {
                    self.* = .utf_8;
                } else if (eqlIgnoreCase(parameter_value_value, "us-ascii")) {
                    self.* = .us_ascii;
                } else return error.InvalidCharset;
            }
        };

        pub const max_value_len: usize = 2 + Charset.max_value_len;

        plain: ?Charset,
        html: ?Charset,
        wildcard: void,

        pub fn validateType(comptime Self: TextSubtype, comptime Type: type) !void {
            _ = Self;

            if (Type != []const u8)
                return error.InvalidTextType;
        }

        pub fn validateText(text: []const u8, charset: ?Charset) !void {
            if (charset == null) {
                if (utf8ValidateSlice(text))
                    return;

                for (text) |character| {
                    if (!isAscii(character))
                        return error.InvalidEncoding;
                }
            } else {
                switch (charset.?) {
                    .utf_8 => {
                        if (!utf8ValidateSlice(text))
                            return error.InvalidEncoding;
                    },
                    .us_ascii => {
                        for (text) |character| {
                            if (!isAscii(character))
                                return error.InvalidEncoding;
                        }
                    },
                }
            }
        }

        pub fn isWildcard(self: TextSubtype) bool {
            return self == .wildcard;
        }

        pub fn areOverlapping(a: TextSubtype, b: TextSubtype) bool {
            if (a == .wildcard or b == .wildcard)
                return true;

            switch (a) {
                .plain => |plain| {
                    if (b == .plain) {
                        return plain == null or b.plain == null or plain.? == b.plain.?;
                    } else return false;
                },
                .html => |html| {
                    if (b == .html) {
                        return html == null or b.html == null or html.? == b.html.?;
                    } else return false;
                },
                .wildcard => unreachable,
            }
        }

        pub fn format(self: TextSubtype, writer: *Writer) WriterError!void {
            switch (self) {
                .plain => |plain| {
                    try writer.writeAll("plain");

                    if (plain) |charset|
                        try writer.print("; {f}", .{charset});
                },
                .html => |html| {
                    try writer.writeAll("html");

                    if (html) |charset|
                        try writer.print("; {f}", .{charset});
                },
                .wildcard => try writer.writeByte('*'),
            }
        }

        pub fn parse(self: *TextSubtype, reader: *Reader) anyerror!void {
            const text_subtype_value = try reader.takeDelimiterExclusive(';');

            if (eqlIgnoreCase(text_subtype_value, "plain")) {
                self.* = .{ .plain = null };
                try Charset.tryParse(&self.plain, reader);
            } else if (eqlIgnoreCase(text_subtype_value, "html")) {
                self.* = .{ .html = null };
                try Charset.tryParse(&self.html, reader);
            } else if (eql(u8, text_subtype_value, "*")) {
                self.* = .wildcard;
            } else return error.InvalidTextSubtype;
        }
    };

    pub const max_value_len: usize = 12 + ApplicationSubtype.max_value_len;

    application: ApplicationSubtype,
    text: TextSubtype,
    wildcard: void,

    pub fn validateType(comptime Self: MediaType, comptime Type: type) !void {
        switch (Self) {
            .application => |application| try comptime ApplicationSubtype.validateType(application, Type),
            .text => |text| try comptime TextSubtype.validateType(text, Type),
            .wildcard => {
                try comptime ApplicationSubtype.validateType(ApplicationSubtype{ .wildcard = {} }, Type);
                try comptime TextSubtype.validateType(TextSubtype{ .wildcard = {} }, Type);
            },
        }
    }

    pub fn isWildcard(self: MediaType) bool {
        switch (self) {
            .application => |application| return application.isWildcard(),
            .text => |text| return text.isWildcard(),
            .wildcard => return true,
        }
    }

    pub fn areOverlapping(a: MediaType, b: MediaType) bool {
        if (a == .wildcard or b == .wildcard)
            return true;

        switch (a) {
            .application => |application| {
                if (b != .application)
                    return false;

                return application.areOverlapping(b.application);
            },
            .text => |text| {
                if (b != .text)
                    return false;

                return text.areOverlapping(b.text);
            },
            .wildcard => unreachable,
        }
    }

    pub fn format(self: MediaType, writer: *Writer) WriterError!void {
        switch (self) {
            .application => |application| try writer.print("application/{f}", .{application}),
            .text => |text| try writer.print("text/{f}", .{text}),
            .wildcard => try writer.writeAll("*/*"),
        }
    }

    pub fn parse(self: *MediaType, reader: *Reader) anyerror!void {
        const media_type_value = reader.takeDelimiterInclusive('/') catch |err| switch (err) {
            error.EndOfStream => return error.InvalidTypeSubtypeDelimiter,
            else => return err,
        };

        if (eqlIgnoreCase(media_type_value, "application/")) {
            self.* = @unionInit(MediaType, "application", undefined);
            try self.application.parse(reader);
        } else if (eqlIgnoreCase(media_type_value, "text/")) {
            self.* = @unionInit(MediaType, "text", undefined);
            try self.text.parse(reader);
        } else if (eql(u8, media_type_value, "*/")) {
            if (reader.bufferedLen() < 1)
                return error.MissingSubtype;

            const wildcard_subtype = try reader.takeByte();

            if (wildcard_subtype != '*')
                return error.InvalidWildcardSybtype;

            self.* = .wildcard;
        } else return error.InvalidMediaType;
    }
};

pub const CommonMediaTypes = struct {
    pub const all = MediaType{ .wildcard = {} };
    pub const text = MediaType{ .text = .{ .plain = .utf_8 } };
    pub const json = MediaType{ .application = .{ .json = {} } };
};

/// Trait check for HttpHeader
///
/// - `Type` must be struct
/// - `Type` must have declaration for header name, named "http_header_name"
///     - `http_header_name` must be declaration of []const u8
/// - `Type` must have declaration for which header type it is, named "http_header_type"
///     - `http_header_type` must be declaration of a HttpHeaderType
/// - `Type` must have declaration for maximal length of it's value, named "max_value_len"
///     - `max_value_len` must be declaration of usize
/// - `Type` must have method decleration for validation, named "validate"
///     - `validate` must have funtion signature fn (Type) anyerror!void
/// - `Type` must have method decleration for formating, named "format"
///     - `format` must have funtion signature fn (Type, *Writer) WriterError!void
/// - `Type` must have method decleration for parsing, named "parse"
///     - `parse` must have funtion signature of either:
///         - fn (*Type, *Writer) anyerror!void
///         - fn (*Type, *Writer, Allocator) anyerror!void
pub fn isHttpHeader(comptime Type: type) bool {
    if (@typeInfo(Type) != .@"struct")
        return false;

    const has_http_header_name =
        @hasDecl(Type, "http_header_name") and
        @TypeOf(Type.http_header_name) == []const u8;

    const has_http_header_type =
        @hasDecl(Type, "http_header_type") and
        @TypeOf(Type.http_header_type) == HttpHeaderType;

    const has_max_value_len =
        @hasDecl(Type, "max_value_len") and
        @TypeOf(Type.max_value_len) == usize;

    const has_validation =
        hasMethod(Type, "validate") and
        @TypeOf(Type.validate) == fn (Type) anyerror!void;

    const has_formating =
        hasMethod(Type, "format") and
        @TypeOf(Type.format) == fn (Type, *Writer) WriterError!void;

    const has_parsing =
        hasMethod(Type, "parse") and
        (@TypeOf(Type.parse) == fn (*Type, *Reader) anyerror!void or @TypeOf(Type.parse) == fn (*Type, *Reader, Allocator) anyerror!void);

    return has_http_header_name and has_http_header_type and has_max_value_len and
        has_validation and has_formating and has_parsing;
}
