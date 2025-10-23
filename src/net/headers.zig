/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;
const Stat = std.fs.File.Stat;
const Writer = std.Io.Writer;
const WriterError = Writer.Error;
const Reader = std.Io.Reader;
const ArrayList = std.ArrayList;

const comptimePrint = std.fmt.comptimePrint;
const assert = std.debug.assert;
const isASCIIChar = std.ascii.isAscii;
const isUTF8Slice = std.unicode.utf8ValidateSlice;
const eqlMem = std.mem.eql;
const eqlIgnoreCase = std.ascii.eqlIgnoreCase;
const parseInt = std.fmt.parseInt;
const parseFloat = std.fmt.parseFloat;
const stringToEnum = std.meta.stringToEnum;
const hasFn = std.meta.hasFn;

/// Aura
const core = @import("../core.zig");

const fieldPtr = core.utils.fieldPtr;
const validateJsonType = core.json.validateJsonType;

/// Third Party
const zeit = @import("zeit");

const Nanoseconds = zeit.Nanoseconds;

pub const HeaderType = enum {
    request,
    response,
    both,
};

pub const USASCII = struct {
    pub const parameter_value = "us-ascii";

    pub fn isASCII(string: []const u8) bool {
        for (string) |char| {
            if (!isASCIIChar(char))
                return false;
        }

        return true;
    }
};

pub const UTF8 = struct {
    pub const parameter_value = "utf-8";

    pub fn isUTF8(string: []const u8) bool {
        return isUTF8Slice(string);
    }
};

const MIMETypeTag = enum {
    text,
    application,
    wildcard,
};

/// Common structure used to specify media type of body
pub const MIMEType = union(MIMETypeTag) {
    const TextTypeTag = enum {
        html,
        plain,
        wildcard,
    };

    pub const TextType = union(TextTypeTag) {
        pub const HTMLSubtype = struct {
            pub const subtype_name = "html";

            pub fn validateType(comptime Type: type) void {
                if (Type != []const u8)
                    @compileError("`Type` must be []const u8");
            }
        };

        pub const PlainSubtype = struct {
            pub const subtype_name = "plain";

            pub fn validateType(comptime Type: type) void {
                if (Type != []const u8)
                    @compileError("`Type` must be []const u8");
            }
        };

        pub const type_name = "text";

        html: HTMLSubtype,
        plain: PlainSubtype,
        wildcard: void,
    };

    const ApplicationTypeTag = enum {
        json,
        wildcard,
    };

    pub const ApplicationType = union(ApplicationTypeTag) {
        pub const JsonSubtype = struct {
            pub const subtype_name = "json";

            pub fn validateType(comptime Type: type) void {
                validateJsonType(Type);
            }
        };

        pub const type_name = "application";

        json: JsonSubtype,
        wildcard: void,
    };

    pub const max_format_len: usize = _maxFormatLen();

    text: TextType,
    application: ApplicationType,
    wildcard: void,

    /// Checks if `Type` is a valid type for subtype from `Self`
    pub fn validateType(comptime Self: MIMEType, comptime Type: type) void {
        inline for (@typeInfo(MIMEType).@"union".fields) |field| field_loop: {
            if (!eqlMem(u8, field.name, @tagName(Self)))
                break :field_loop;

            if (comptime field.type == void)
                @compileError("MIME type wildcard can't validate type");

            const field_value: field.type = @field(Self, field.name);

            inline for (@typeInfo(field.type).@"union".fields) |subfield| subfield_loop: {
                if (!eqlMem(u8, subfield.name, @tagName(field_value)))
                    break :subfield_loop;

                if (comptime subfield.type == void)
                    @compileError("MIME subtype wildcard can't validate type");

                subfield.type.validateType(Type);
                return;
            }

            unreachable;
        }

        unreachable;
    }

    /// Formats `self` as MIME type to `writer`
    ///
    /// Header Content-Type is not only MIME type, use ContentType.format for
    /// header formating.
    pub fn format(self: MIMEType, writer: *Writer) WriterError!void {
        switch (self) {
            .text => |@"type"| {
                switch (@"type") {
                    .html => try writer.print(
                        "{s}/{s}",
                        .{ TextType.type_name, TextType.HTMLSubtype.subtype_name },
                    ),
                    .plain => try writer.print(
                        "{s}/{s}",
                        .{ TextType.type_name, TextType.PlainSubtype.subtype_name },
                    ),
                    .wildcard => try writer.print(
                        "{s}/*",
                        .{TextType.type_name},
                    ),
                }
            },
            .application => |@"type"| {
                switch (@"type") {
                    .json => try writer.print(
                        "{s}/{s}",
                        .{ ApplicationType.type_name, ApplicationType.JsonSubtype.subtype_name },
                    ),
                    .wildcard => try writer.print(
                        "{s}/*",
                        .{ApplicationType.type_name},
                    ),
                }
            },
            .wildcard => try writer.writeAll("*/*"),
        }
    }

    fn _maxFormatLen() usize {
        var res: usize = 0;

        inline for (@typeInfo(MIMEType).@"union".fields) |field| field_loop: {
            if (comptime field.type == void)
                break :field_loop;

            inline for (@typeInfo(field.type).@"union".fields) |subfield| subfield_loop: {
                if (comptime subfield.type == void)
                    break :subfield_loop;

                if (field.type.type_name.len + subfield.type.subtype_name.len > res)
                    res = field.type.type_name.len + subfield.type.subtype_name.len;
            }
        }

        return res;
    }

    /// Parses from `reader` into `self`
    ///
    /// `reader` must contain valid MIME type.
    /// Header Content-Type is not only MIME type, use ContentType.parse for
    /// header parsing.
    pub fn parse(self: *MIMEType, reader: *Reader) !void {
        const type_tag = try reader.takeDelimiterExclusive('/');

        inline for (@typeInfo(MIMEType).@"union".fields) |field| field_loop: {
            const type_name =
                if (comptime field.type == void)
                    "*"
                else
                    field.type.type_name;

            if (!eqlIgnoreCase(type_name, type_tag))
                break :field_loop;

            reader.toss(1);
            const subtype_tag = try reader.takeDelimiterExclusive(';');

            if (comptime field.type == void) {
                if (!eqlIgnoreCase("*", subtype_tag))
                    return error.InvalidWildcard;

                self.* = .wildcard;
                return;
            }

            inline for (@typeInfo(field.type).@"union".fields) |subfield| subfield_loop: {
                const subtype_name =
                    if (comptime subfield.type == void)
                        "*"
                    else
                        subfield.type.subtype_name;

                if (!eqlIgnoreCase(subtype_name, subtype_tag))
                    break :subfield_loop;

                const @"type" = @unionInit(field.type, subfield.name, subfield.type{});
                self.* = @unionInit(MIMEType, field.name, @"type");

                return;
            }

            return error.UnimplementedMIMESubtype;
        }

        return error.UnimplementedMIMEType;
    }

    /// Checks if `self` can have charset parameter
    pub fn isCharsetCompatible(self: MIMEType) bool {
        switch (self) {
            .text => |@"type"| {
                switch (@"type") {
                    .wildcard => return false,
                    else => return true,
                }
            },
            .application => |@"type"| {
                switch (@"type") {
                    .json => return true,
                    else => return false,
                }
            },
            .wildcard => return false,
        }
    }

    pub fn isWildcard(self: MIMEType) bool {
        switch (self) {
            .text => |@"type"| {
                switch (@"type") {
                    .wildcard => return true,
                    else => return false,
                }
            },
            .application => |@"type"| {
                switch (@"type") {
                    .wildcard => return true,
                    else => return false,
                }
            },
            .wildcard => return true,
        }
    }
};

/// Host header describes target domain name and optional port number of the server the client wants to communicate with
pub const Host = struct {
    const max_hostname_len: usize = 255;

    pub const header_name: []const u8 = "host";
    pub const header_t: HeaderType = .request;
    pub const max_format_len: usize = max_hostname_len + 6;

    hostname: []const u8,
    port: ?u16,

    /// Formats `self` as header value to `writer`
    ///
    /// Use `Host.header_name` for the header name.
    pub fn format(self: Host, writer: *Writer) WriterError!void {
        assert(self.hostname.len > 0 and self.hostname.len <= max_format_len);

        try writer.writeAll(self.hostname);

        if (self.port) |port| {
            try writer.print(":{d}", .{port});
        }
    }

    /// Parses from `reader` into `self`
    ///
    /// - `reader` must contain valid header value and only it.
    /// - `self.hostname` will be duplicated. Either pass arena allocator as `allocator`
    ///   or call `deinit` on `self` after use.
    pub fn parse(self: *Host, reader: *Reader, allocator: Allocator) !void {
        var has_port: bool = true;

        self.hostname =
            try hostname_blk: {
                const res = reader.takeDelimiterInclusive(':') catch |err| switch (err) {
                    error.EndOfStream => {
                        has_port = false;
                        break :hostname_blk allocator.dupe(u8, reader.take(reader.bufferedLen()));
                    },
                    else => break :hostname_blk err,
                };
                break :hostname_blk allocator.dupe(u8, res[0..(res.len - 1)]);
            };

        if (self.hostname.len > 0)
            return error.HostnameTooShort;
        if (self.hostname.len < max_hostname_len)
            return error.HostnameTooLong;

        self.port =
            if (has_port)
                try port_blk: {
                    if (reader.bufferedLen() == 0)
                        break :port_blk error.MissingPort;
                    const buffer_end = try reader.take(reader.bufferedLen());
                    break :port_blk parseInt(u16, buffer_end, 10);
                }
            else
                null;

        if (reader.bufferedLen() != 0)
            return error.ExcessHeaderTail;
    }

    /// Frees any memory allocated during `parse`
    pub fn deinit(self: *Host, allocator: Allocator) void {
        allocator.free(self.hostname);
    }
};

/// Content-Type header describes what MIMEType is in the body http message
pub const ContentType = struct {
    const CharsetTag = enum {
        us_ascii,
        utf_8,
    };

    pub const Charset = union(CharsetTag) {
        const parameter_name = "charset";

        us_ascii: USASCII,
        utf_8: UTF8,

        /// Formats `self` as header parameter to `writer`
        pub fn format(self: Charset, writer: *Writer) WriterError!void {
            switch (self) {
                .us_ascii => try writer.print("{s}={s}", .{ parameter_name, USASCII.parameter_value }),
                .utf_8 => try writer.print("{s}={s}", .{ parameter_name, UTF8.parameter_value }),
            }
        }

        /// Parses from `reader` into `self`
        ///
        /// `parser` must containe `parameter_name` and parameter_value seperated by '='
        pub fn parse(self: *Charset, reader: *Reader) !void {
            const parameter_name_value = try reader.takeDelimiterExclusive('=');
            if (!eqlIgnoreCase(parameter_name, parameter_name_value))
                return error.InvalidParameterName;

            reader.toss(1);
            const parameter_value = try reader.takeDelimiterExclusive(';');

            inline for (@typeInfo(Charset).@"union".fields) |field| field_loop: {
                if (!eqlIgnoreCase(field.type.parameter_value, parameter_value))
                    break :field_loop;

                self.* = @unionInit(Charset, field.name, field.type{});

                return;
            }

            return error.UnimplementedCharset;
        }
    };

    pub const Common = struct {
        pub const text = ContentType{
            .mime = MIMEType{ .text = .plain },
            .charset = Charset{ .utf_8 = .{} },
        };
        pub const json = ContentType{
            .mime = MIMEType{ .application = .json },
            .charset = Charset{ .utf_8 = .{} },
        };
    };

    pub const header_name: []const u8 = "content-type";
    pub const header_t: HeaderType = .both;
    pub const max_format_len: usize = _maxFormatLen();

    mime: MIMEType,
    charset: ?Charset,

    /// Checks if `Type` is a valid type for `Self`
    pub fn validateType(comptime Self: ContentType, comptime Type: type) void {
        Self.mime.validateType(Type);
        if (!(Self.charset == null or Self.mime.isCharsetCompatible()))
            @compileError("`Self.charset` is not compatible with `Self.mime`");
    }

    /// Formats `self` as header value to `writer`
    ///
    /// Use `ContentType.header_name` for the header name.
    pub fn format(self: ContentType, writer: *Writer) WriterError!void {
        assert(!MIMEType.isWildcard(self.mime));
        assert(self.charset == null or self.mime.isCharsetCompatible());

        try self.mime.format(writer);

        if (self.charset) |charset| {
            try writer.print("; {f}", .{charset});
        }
    }

    fn _maxFormatLen() usize {
        var res: usize = MIMEType.max_format_len;

        // Lenght of "; " at the start of charset
        res += 2;

        res += Charset.parameter_name.len + 1;

        var max_len: usize = 0;
        inline for (@typeInfo(Charset).@"union".fields) |field| {
            if (field.type.parameter_value.len > max_len)
                max_len = field.type.parameter_value.len;
        }
        res += max_len;

        return res;
    }

    /// Parses from `reader` into `self`
    ///
    /// - `reader` must contain valid header value and only it.
    /// - No allocations, Allocator parameter is only to match isHTTPHeader.
    pub fn parse(self: *ContentType, reader: *Reader, _: Allocator) !void {
        try self.mime.parse(reader);

        if (MIMEType.isWildcard(self.mime))
            return error.FoundWildcard;

        inline for (@typeInfo(ContentType).@"struct".fields) |field| field_loop: {
            comptime if (field.type == MIMEType)
                break :field_loop;

            const field_type = @typeInfo(field.type).optional.child;
            const field_ptr = fieldPtr(ContentType, field.name, self);

            if (reader.bufferedLen() <= 2 + field_type.parameter_name.len) {
                field_ptr.* = null;
                break :field_loop;
            }

            const parameter_name = try reader.peek(2 + field_type.parameter_name.len);

            if (!eqlIgnoreCase("; " ++ field_type.parameter_name, parameter_name)) {
                field_ptr.* = null;
                break :field_loop;
            }

            if (comptime field_type == Charset)
                if (!self.mime.isCharsetCompatible())
                    return error.CharsetIncompatible;

            reader.toss(2);

            try field_ptr.*.?.parse(reader);
        }
    }
};

/// Content-Disposition header describes if browsers should display or download the resource
pub const ContentDisposition = struct {
    const DispositionTypeTag = enum {
        @"inline",
        attachment,
    };

    pub const DispositionType = union(DispositionTypeTag) {
        pub const Inline = struct {
            pub const header_value = "inline";
        };

        pub const Attachment = struct {
            pub const header_value = "attachment";
        };

        @"inline": Inline,
        attachment: Attachment,

        /// Formats `self` as disposition type to `writer`
        ///
        /// Header Content-Disposition is not only disposition type, use ContentDisposition.format for
        /// header formating.
        pub fn format(self: DispositionType, writer: *Writer) WriterError!void {
            switch (self) {
                .@"inline" => try writer.writeAll(Inline.header_value),
                .attachment => try writer.writeAll(Attachment.header_value),
            }
        }

        /// Parses from `reader` into `self`
        ///
        /// `reader` must contain valid disposition type.
        /// Header Content-Disposition is not only disposition type, use ContentDisposition.parse for
        /// header parsing.
        pub fn parse(self: *DispositionType, reader: *Reader) !void {
            const disposition_tag = try reader.takeDelimiterExclusive(';');

            inline for (@typeInfo(DispositionType).@"union".fields) |field| field_loop: {
                if (!eqlIgnoreCase(field.type.header_value, disposition_tag))
                    break :field_loop;

                self.* = @unionInit(DispositionType, field.name, field.type{});

                return;
            }

            return error.UnimplementedDisposition;
        }

        /// Checks if `self` can have filename parameter
        pub fn isFilenameCompatible(self: DispositionType) bool {
            switch (self) {
                .@"inline" => return false,
                .attachment => return true,
            }
        }
    };

    const FilenameTag = enum {
        unencoded,
        encoded,
    };

    pub const Filename = union(FilenameTag) {
        pub const Unencoded = struct {
            const max_filename_len: usize = 255;

            pub const parameter_name = "filename";
            pub const max_format_len: usize = parameter_name.len + max_filename_len + 1;

            filename: []const u8,

            /// Formats `self` as header parameter to `writer`
            pub fn format(self: Unencoded, writer: *Writer) WriterError!void {
                assert(self.filename.len > 0 and self.filename.len <= max_filename_len);
                assert(USASCII.isASCII(self.filename));

                try writer.print("{s}=\"{s}\"", .{ parameter_name, self.filename });
            }

            /// Parses from `reader` into `self`
            ///
            /// - `reader` must contain valid filename type.
            /// - `self.filename` will be duplicated. Either pass arena allocator as `allocator`
            ///   or call `deinit` on `self` after use.
            pub fn parse(self: *Unencoded, reader: *Reader, allocator: Allocator) !void {
                const filename_value = try reader.takeDelimiterExclusive(';');

                if (filename_value.len <= 2)
                    return error.FilenameTooShort;
                if (filename_value.len > max_filename_len + 2)
                    return error.FilenameTooLong;
                if (!(filename_value[0] == '"' and filename_value[filename_value.len - 1] == '"'))
                    return error.InvalidQuotation;
                if (!USASCII.isASCII(filename_value[1..(filename_value.len - 1)]))
                    return error.InvalidEncoding;

                self.filename = allocator.dupe(u8, filename_value[1..(filename_value.len - 1)]);
            }

            /// Frees any memory allocated during `parse`
            pub fn deinit(self: *Unencoded, allocator: Allocator) void {
                allocator.free(self.filename);
            }
        };

        pub const Encoded = struct {
            const CharsetTag = enum {
                us_ascii,
                utf_8,
            };

            pub const Charset = union(CharsetTag) {
                us_ascii: USASCII,
                utf_8: UTF8,
            };

            const max_language_len: usize = 5;
            const max_filename_len: usize = 255 * 4;

            pub const parameter_name = "filename*";
            pub const max_format_len: usize = @This()._maxFormatLen();

            charset: Charset,
            language: ?[]const u8,
            filename: []const u8,

            /// Formats `self` as header parameter to `writer`
            pub fn format(self: Encoded, writer: *Writer) WriterError!void {
                assert(self.language == null or (self.language.?.len > 0 and self.language.?.len <= max_language_len));
                assert(self.filename.len > 0 and self.filename.len <= max_filename_len);
                assert(assert_blk: {
                    switch (self.charset) {
                        .us_ascii => break :assert_blk USASCII.isASCII(self.filename),
                        .utf_8 => break :assert_blk UTF8.isUTF8(self.filename),
                    }
                });

                const charset_value = charset_blk: switch (self.charset) {
                    .us_ascii => break :charset_blk USASCII.parameter_value,
                    .utf_8 => break :charset_blk UTF8.parameter_value,
                };
                const language_value =
                    if (self.language) |language|
                        language
                    else
                        "";

                try writer.print("{s}={s}'{s}'{s}", .{
                    parameter_name,
                    charset_value,
                    language_value,
                    self.filename,
                });
            }

            fn _maxFormatLen() usize {
                var res: usize = parameter_name.len + 1;

                var max_len: usize = 0;
                inline for (@typeInfo(Charset).@"union".fields) |field| {
                    if (field.type.parameter_value.len > max_len)
                        max_len = field.type.parameter_value.len;
                }

                res += max_len + max_language_len + max_filename_len + 2;

                return res;
            }

            /// Parses from `reader` into `self`
            ///
            /// - `reader` must contain valid encoded filename.
            /// - `self.language` and `self.filename` can be duplicated. Either pass arena allocator as `allocator`
            ///   or call `deinit` on `self` after use.
            pub fn parse(self: *Encoded, reader: *Reader, allocator: Allocator) !void {
                const charset_value = try reader.takeDelimiterExclusive('\'');
                var charset_assigned = false;

                inline for (@typeInfo(Charset).@"union".fields) |field| filed_loop: {
                    if (!eqlIgnoreCase(field.type.parameter_value, charset_value))
                        break :filed_loop;

                    charset_assigned = true;

                    self.charset = @unionInit(Charset, field.name, field.type{});
                }

                if (!charset_assigned)
                    return error.UnimplemenetedCharset;

                reader.toss(1);
                const language_value = try reader.takeDelimiterExclusive('\'');

                if (language_value.len > max_language_len)
                    return error.LanguageTooLong;

                self.language =
                    if (language_value.len > 0)
                        try allocator.dupe(u8, language_value)
                    else
                        null;

                reader.toss(1);
                const filename_value = try reader.takeDelimiterExclusive(';');

                // Check of filename.len == 0 is done by reader.takeDelimiterExclusive
                if (filename_value.len > max_filename_len)
                    return error.FilenameTooLong;
                switch (self.charset) {
                    .us_ascii => {
                        if (!USASCII.isASCII(filename_value))
                            return error.InvalidEncoding;
                    },
                    .utf_8 => {
                        if (!UTF8.isUTF8(filename_value))
                            return error.InvalidEncoding;
                    },
                }

                self.filename = allocator.dupe(u8, filename_value);
            }

            /// Frees any memory allocated during `parse`
            pub fn deinit(self: *Encoded, allocator: Allocator) void {
                if (self.language != null)
                    allocator.free(self.language.?);
                allocator.free(self.filename);
            }
        };

        unencoded: Unencoded,
        encoded: Encoded,

        /// Formats `self` as header parameter to `writer`
        pub fn format(self: Filename, writer: *Writer) WriterError!void {
            switch (self) {
                .unencoded => |filename| try filename.format(writer),
                .encoded => |filename| try filename.format(writer),
            }
        }

        /// Parses from `reader` into `self`
        ///
        /// - `reader` must contain valid filename type.
        /// - Contents of `unencoded` and `encoded` will be duplicated. Either pass arena allocator as `allocator`
        ///   or call `deinit` on `self` after use.
        pub fn parse(self: *Filename, reader: *Reader, allocator: Allocator) !void {
            const parameter_name_value = try reader.takeDelimiterExclusive('=');
            reader.toss(1);

            inline for (@typeInfo(Filename).@"union".fields) |field| field_loop: {
                if (!eqlIgnoreCase(field.type.parameter_name, parameter_name_value))
                    break :field_loop;

                self.* = @unionInit(Filename, field.name, undefined);
                try @field(self, field.name).parse(reader, allocator);

                return;
            }

            return error.InvalidParameterName;
        }

        /// Frees any memory allocated during `parse`
        pub fn deinit(self: *Filename, allocator: Allocator) void {
            switch (self.*) {
                .unencoded => |unencoded| unencoded.deinit(allocator),
                .encoded => |encoded| encoded.deinit(allocator),
            }
        }
    };

    pub const header_name: []const u8 = "content-disposition";
    pub const header_t: HeaderType = .response;
    pub const max_format_len: usize = _maxFormatLen();

    disposition: DispositionType,
    filename: ?Filename,

    /// Formats `self` as header value to `writer`
    ///
    /// Use `ContentType.header_name` for the header name.
    pub fn format(self: ContentDisposition, writer: *Writer) WriterError!void {
        assert(self.filename == null or DispositionType.isFilenameCompatible(self.disposition));

        try self.disposition.format(writer);

        if (self.filename) |filename|
            try writer.print("; {f}", .{filename});
    }

    fn _maxFormatLen() usize {
        var res: usize = 0;

        var max_len: usize = 0;
        inline for (@typeInfo(DispositionType).@"union".fields) |field| {
            if (field.type.header_value.len > max_len)
                max_len = field.type.header_value.len;
        }
        res += max_len;

        // Lenght of "; " at the start of filename
        res += 2;

        max_len = 0;
        inline for (@typeInfo(Filename).@"union".fields) |field| {
            if (field.type.max_format_len > max_len)
                max_len = field.type.max_format_len;
        }
        res += max_len;

        return res;
    }

    /// Parses from `reader` into `self`
    ///
    /// - `reader` must contain valid header value and only it.
    /// - `self.filename` and its contents may need to be duplicated.
    ///   Either pass arena allocator as `allocator` or call `deinit` on `self` after use.
    pub fn parse(self: *ContentDisposition, reader: *Reader, allocator: Allocator) !void {
        try self.disposition.parse(reader);

        filename_blk: {
            const filename_parameter_name = "; filename";
            if (reader.bufferedLen() < (filename_parameter_name.len)) {
                self.filename = null;
                break :filename_blk;
            }

            const parameter_name_value = try reader.peek(filename_parameter_name.len);

            if (!eqlIgnoreCase(filename_parameter_name, parameter_name_value)) {
                self.filename = null;
                break :filename_blk;
            }

            if (!DispositionType.isFilenameCompatible(self.disposition))
                return error.FilenameIncompatible;

            reader.toss(2);

            try Filename.parse(&self.filename.?, reader, allocator);
        }

        if (reader.bufferedLen() != 0)
            return error.ExcessHeaderTail;
    }

    /// Frees any memory allocated during `parse`
    pub fn deinit(self: *ContentDisposition, allocator: Allocator) void {
        self.filename.deinit(allocator);
    }
};

/// Content-Length header describes how long is body in bytes
pub const ContentLength = struct {
    pub const header_name: []const u8 = "content-length";
    pub const header_t: HeaderType = .both;
    pub const max_format_len: usize = 20;

    length: usize,

    /// Formats `self` as header value to `writer`
    ///
    /// Use `ContentType.header_name` for the header name.
    pub fn format(self: ContentLength, writer: *Writer) WriterError!void {
        try writer.print("{d}", .{self.length});
    }

    /// Parses from `reader` into `self`
    ///
    /// - `reader` must contain valid header value and only it.
    /// - No allocations, Allocator parameter is only to match isHTTPHeader.
    pub fn parse(self: *ContentLength, reader: *Reader, _: Allocator) !void {
        const header_value = try reader.take(reader.bufferedLen());

        self.length = try parseInt(usize, header_value, 10);

        if (reader.bufferedLen() != 0)
            return error.ExcessHeaderTail;
    }
};

/// Accept header describes what MIMETypes can sender accept as body of response
pub const Accept = struct {
    pub const MediaRange = struct {
        pub const max_format_len = MIMEType.max_format_len + 9;

        mime: MIMEType,
        quality: ?f32,

        /// Formats `self` as header value to `writer`
        pub fn format(self: MediaRange, writer: *Writer) WriterError!void {
            assert(self.quality == null or (self.quality.? >= 0 and self.quality.? <= 1.0 and @as(f32, @floor(self.quality.? * 1000)) == @as(f32, (self.quality.? * 1000))));

            try self.mime.format(writer);
            if (self.quality) |quality| {
                if (@as(f32, (quality * 10)) - @as(f32, @floor(quality * 10)) < 0.01)
                    try writer.print("; q={d:.1}", .{quality})
                else
                    try writer.print("; q={d}", .{@as(f32, @round(quality * 1000) / 1000)});
            }
        }

        /// Parses from `reader` into `self`
        ///
        /// - `reader` must contain valid media range.
        pub fn parse(self: *MediaRange, reader: *Reader) !void {
            try self.mime.parse(reader);

            quality_blk: {
                const quality_parameter_name = "; q=";
                if (reader.bufferedLen() < (quality_parameter_name.len)) {
                    self.quality = null;
                    break :quality_blk;
                }

                const parameter_name_value = try reader.peek(quality_parameter_name.len);

                if (!eqlIgnoreCase(quality_parameter_name, parameter_name_value)) {
                    self.quality = null;
                    break :quality_blk;
                }

                reader.toss(quality_parameter_name.len);
                const quality_parameter_value = try reader.takeDelimiterExclusive(',');

                self.quality = try parseFloat(f32, quality_parameter_value);

                if (!(self.quality.? >= 0 and self.quality.? <= 1.0 and @as(f32, @floor(self.quality.? * 1000)) == @as(f32, (self.quality.? * 1000))))
                    return error.InvalidQuality;
            }
        }
    };

    const media_ranges_capacity: usize = 16;

    pub const header_name: []const u8 = "accept";
    pub const header_t: HeaderType = .request;
    pub const max_format_len: usize = media_ranges_capacity * (MediaRange.max_format_len + 2);

    media_ranges: []const MediaRange,

    /// Formats `self` as header value to `writer`
    ///
    /// Use `Accept.header_name` for the header name.
    pub fn format(self: Accept, writer: *Writer) WriterError!void {
        assert(self.media_ranges.len > 0 and self.media_ranges.len <= 16);

        for (self.media_ranges) |media_range| {
            try media_range.format(writer);

            try writer.writeAll(", ");
        }

        if (self.media_ranges.len > 0)
            writer.undo(2);
    }

    /// Parses from `reader` into `self`
    ///
    /// - `reader` must contain valid header value and only it.
    /// - `self.media_ranges` and need to be allocated.
    ///   Either pass arena allocator as `allocator` or call `deinit` on `self` after use.
    pub fn parse(self: *Accept, reader: *Reader, allocator: Allocator) !void {
        var res: ArrayList(MediaRange) = try ArrayList(MediaRange).initCapacity(allocator, media_ranges_capacity);

        for (0..media_ranges_capacity) |_| {
            var media_range: MediaRange = undefined;
            try media_range.parse(reader);
            res.appendAssumeCapacity(media_range);

            if (reader.bufferedLen() == 0)
                break;

            if (reader.bufferedLen() >= 2) {
                const delimiter = try reader.take(2);

                if (!eqlMem(u8, ", ", delimiter))
                    return error.InvalidDelimiter;
            }
        }

        if (reader.bufferedLen() != 0)
            return error.ExcessHeaderTail;

        self.media_ranges = try res.toOwnedSlice(allocator);
    }

    /// Frees any memory allocated during `parse`
    pub fn deinit(self: *Accept, allocator: Allocator) void {
        allocator.free(self.media_ranges);
    }
};

/// Cache-Control header describes if or how, to cache a resource
pub const CacheControl = union(CacheControlTag) {
    pub const CacheSetting = struct {
        pub const MaxStale = union(enum) {
            use: bool,
            Setting: u32,
        };

        max_age: ?u32 = null,
        s_maxage: ?u32 = null,
        max_stale: MaxStale = .{ .use = false },
        min_fresh: ?u32 = null,

        must_revalidate: bool = false,
        proxy_revalidate: bool = false,
        stale_while_revalidate: ?u32 = null,
        stale_if_error: ?u32 = null,

        imutable: bool = false,
        only_if_cached: bool = false,

        pub fn toString(comptime Setting: CacheSetting) []const u8 {
            var res: []const u8 = "";

            if (Setting.max_age != null)
                res = res ++ comptimePrint("max-age={}, ", .{Setting.max_age.?});
            if (Setting.s_maxage != null)
                res = res ++ comptimePrint("s-maxage={}, ", .{Setting.s_maxage.?});
            if (Setting.max_stale == .use and Setting.max_stale.use)
                res = res ++ "max-stale, "
            else if (Setting.max_stale == .Setting)
                res = res ++ comptimePrint("max-stale={}, ", .{Setting.max_stale.Setting});
            if (Setting.min_fresh != null)
                res = res ++ comptimePrint("min-fresh={}, ", .{Setting.min_fresh.?});

            if (Setting.must_revalidate)
                res = res ++ "must-revalidate, ";
            if (Setting.proxy_revalidate)
                res = res ++ "proxy-revalidate, ";
            if (Setting.stale_while_revalidate != null)
                res = res ++ comptimePrint("stale-while-revalidate={}, ", .{Setting.stale_while_revalidate.?});
            if (Setting.stale_if_error != null)
                res = res ++ comptimePrint("stale-if-error={}, ", .{Setting.stale_if_error.?});

            if (Setting.imutable)
                res = res ++ "imutable, ";
            if (Setting.only_if_cached)
                res = res ++ "only-if-cached, ";

            return if (res.len >= 2)
                res[0..(res.len - 2)]
            else
                "";
        }
    };

    no_store: void,
    no_cache: void,
    private: CacheSetting,
    public: CacheSetting,

    pub fn toString(comptime Header: CacheControl) []const u8 {
        switch (Header) {
            .no_store => return "no-store",
            .no_cache => return "no-cache",
            .private => |cache_setting| {
                const cache_setting_string = CacheSetting.toString(cache_setting);
                return if (cache_setting_string.len == 0)
                    "private"
                else
                    "private, " ++ cache_setting_string;
            },
            .public => |cache_setting| {
                const cache_setting_string = comptime CacheSetting.toString(cache_setting);
                return if (cache_setting_string.len == 0)
                    "public"
                else
                    "public, " ++ cache_setting_string;
            },
        }
    }
};

const CacheControlTag = enum {
    no_store,
    no_cache,
    private,
    public,
};

/// LastModified header describes when was a resource last altered
pub const LastModified = struct {
    /// Length of `dest` must be 29 bytes or longer
    pub fn toString(stat: Stat, dest: []u8) !void {
        assert(dest.len >= 29);

        const instant = try zeit.instant(.{ .source = .{ .unix_nano = stat.mtime } });
        var writer = Writer.fixed(dest);

        try instant.time().strftime(&writer, "%a, %d %b %Y %T %Z");

        try writer.flush();
    }
};

pub fn isHTTPHeader(comptime Type: type) bool {
    return @hasDecl(Type, "header_name") and @TypeOf(Type.header_name) == []const u8 and
        @hasDecl(Type, "header_t") and @TypeOf(Type.header_t) == HeaderType and
        @hasDecl(Type, "max_format_len") and @TypeOf(Type.max_format_len) == usize and
        hasFn(Type, "format") and @TypeOf(Type.format) == fn (Type, *Writer) WriterError!void and
        hasFn(Type, "parse") and @TypeOf(Type.format) == fn (*Type, *Reader, Allocator) anyerror!void;
}
