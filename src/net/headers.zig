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
const isASCIIDigit = std.ascii.isDigit;
const isASCIIAlphabetic = std.ascii.isAlphabetic;
const isASCIIControl = std.ascii.isControl;
const isASCIIHex = std.ascii.isHex;
const utf8Decode2 = std.unicode.utf8Decode2;
const utf8Decode3 = std.unicode.utf8Decode3;
const utf8Decode4 = std.unicode.utf8Decode4;
const eqlMem = std.mem.eql;
const eqlIgnoreCase = std.ascii.eqlIgnoreCase;
const parseInt = std.fmt.parseInt;
const parseFloat = std.fmt.parseFloat;
const stringToEnum = std.meta.stringToEnum;
const hasFn = std.meta.hasFn;
const containsAtLeastScalar = std.mem.containsAtLeastScalar;

/// Aura
const core = @import("../core.zig");

const fieldPtr = core.utils.fieldPtr;
const charToHex = core.utils.charToHex;
const validateJsonType = core.json.validateJsonType;

/// Third Party
const zeit = @import("zeit");

const Time = zeit.Time;
const Nanoseconds = zeit.Nanoseconds;

pub const HeaderType = enum {
    request,
    response,
    both,
};

fn fieldNameToHeaderParameter(comptime Name: []const u8) []const u8 {
    const res = comptime blk: {
        var buff: [Name.len]u8 = undefined;

        for (Name, 0..) |character, index|
            buff[index] =
                if (character == '_')
                    '-'
                else
                    character;

        break :blk buff;
    };

    return &res;
}

pub fn isTokenValid(token: []const u8) !void {
    const allowed_characters: []const u8 = "!#$%&'*+-.^_`|~";

    for (token) |character| {
        if (!isASCIIChar(character))
            return error.InvalidEncoding;
        if (isASCIIAlphabetic(character) or isASCIIDigit(character))
            continue;

        var valid_character = false;
        inline for (allowed_characters) |allowed_character| {
            if (character == allowed_character)
                valid_character = true;
        }

        if (!valid_character)
            return error.InvalidCharacter;
    }
}

pub const CommonHeaderFields = struct {
    pub const USASCII = struct {
        pub const parameter_value = "us-ascii";
    };

    pub const UTF8 = struct {
        pub const parameter_value = "utf-8";
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

    /// Common structure used to identify client and server software
    pub const Product = struct {
        const max_name_len: usize = 32;
        const max_version_len: usize = 16;
        const comments_capacity: usize = 6;
        const max_comment_len: usize = 128;

        pub const max_format_len: usize = max_name_len + max_version_len + (comments_capacity * (max_comment_len + 3)) + 1;

        name: []const u8,
        version: ?[]const u8 = null,
        comments: ?[]const []const u8 = null,

        pub fn isNameValid(name: []const u8) !void {
            if (name.len == 0)
                return error.NameTooShort;
            if (name.len > max_name_len)
                return error.NameTooLong;

            try isTokenValid(name);
        }

        pub fn isVersionValid(version: []const u8) !void {
            if (version.len == 0)
                return error.VersionTooShort;
            if (version.len > max_version_len)
                return error.VersionTooLong;

            try isTokenValid(version);
        }

        pub fn areCommentsValid(comments: []const []const u8) !void {
            if (comments.len == 0)
                return error.TooFewComments;
            if (comments.len > comments_capacity)
                return error.TooManyComments;

            for (comments) |comment| {
                if (comment.len == 0)
                    return error.CommentTooShort;
                if (comment.len > max_comment_len)
                    return error.CommentTooLong;

                var parentheses_count: usize = 0;
                for (comment) |character| {
                    if (isASCIIControl(character) and character != '\t')
                        return error.InvalidCharacter;

                    if (character == '(')
                        parentheses_count += 1;

                    if (character == ')') {
                        if (parentheses_count == 0)
                            return error.UnclosedParentheses;

                        parentheses_count -= 1;
                    }
                }

                if (parentheses_count != 0)
                    return error.UnclosedParentheses;
            }
        }

        /// Formats `self` as header parameter to `writer`
        pub fn format(self: Product, writer: *Writer) WriterError!void {
            assert(assert_blk: {
                isNameValid(self.name) catch break :assert_blk false;
                break :assert_blk true;
            });
            assert(self.version == null or assert_blk: {
                isVersionValid(self.version.?) catch break :assert_blk false;
                break :assert_blk true;
            });
            assert(self.comments == null or assert_blk: {
                areCommentsValid(self.comments) catch break :assert_blk false;
                break :assert_blk true;
            });

            try writer.writeAll(self.name);

            if (self.version) |version| {
                try writer.print("/{s}", .{version});
            }

            if (self.comments) |comments| {
                for (comments) |comment| {
                    assert(comment.len > 0 and comment.len <= max_comment_len);

                    try writer.print(" ({s})", .{comment});
                }
            }
        }

        /// Parses from `reader` into `self`
        ///
        /// - `reader` must contain valid product.
        /// - `self.name`, `self.version` and `self.comments` can be duplicated and allocated.
        ///   Either pass arena allocator as `allocator` or call `deinit` on `self` after use.
        /// - Any error will free allocated resources in `self`
        pub fn parse(self: *Product, reader: *Reader, allocator: Allocator) !void {
            const name_version_value = try reader.peekDelimiterExclusive(' ');
            const name_value = try reader.peekDelimiterExclusive('/');

            if (name_version_value.len < name_value.len) {
                reader.toss(name_version_value.len);

                self.name = try allocator.dupe(u8, name_version_value);
                self.version = null;
            } else if (name_version_value.len > name_value.len) {
                reader.toss(name_version_value.len);

                self.name = try allocator.dupe(u8, name_value);
                self.version = try allocator.dupe(u8, name_version_value[name_value.len + 1 ..]);
            } else {
                reader.toss(name_value.len);

                self.name = try allocator.dupe(u8, name_value);
                self.version = null;
                self.comments = null;
            }
            errdefer {
                allocator.free(self.name);
                if (self.version != null)
                    allocator.free(self.version.?);
            }

            try isNameValid(self.name);

            if (self.version) |version|
                try isVersionValid(version);

            if (reader.bufferedLen() < 2) {
                self.comments = null;
                return;
            }

            const comments_start_value = try reader.peek(2);

            if (!eqlMem(u8, " (", comments_start_value)) {
                self.comments = null;
                return;
            }

            var comments = try ArrayList([]const u8).initCapacity(allocator, comments_capacity);
            errdefer {
                while (comments.pop()) |comment| {
                    allocator.free(comment);
                }
                comments.deinit(allocator);
            }

            inline for (0..comments_capacity) |index| {
                if (comptime index != 0) {
                    if (reader.bufferedLen() < 2)
                        break;

                    const comment_start_value = try reader.peek(2);

                    if (!eqlMem(u8, " (", comment_start_value))
                        break;
                }

                const remainder = try reader.peek(reader.bufferedLen());
                var comments_len: usize = 1;
                var parentheses_count: usize = 0;

                for (remainder[1..]) |character| {
                    comments_len += 1;

                    if (character == '(')
                        parentheses_count += 1;

                    if (character == ')') {
                        if (parentheses_count == 1) {
                            parentheses_count = 0;
                            break;
                        }

                        parentheses_count -= 1;
                    }
                }

                if (parentheses_count != 0)
                    return error.UnclosedParentheses;

                const comment_value = try reader.take(comments_len);

                if (comment_value.len == 3)
                    return error.CommentTooShort;
                if (comment_value.len > max_comment_len + 3)
                    return error.CommentTooLong;

                comments.appendAssumeCapacity(try allocator.dupe(u8, comment_value[2 .. comment_value.len - 1]));
            }

            self.comments = try comments.toOwnedSlice(allocator);
            errdefer {
                for (self.comments.?) |comment| {
                    allocator.free(comment);
                }
                allocator.free(self.comments.?);
            }

            try areCommentsValid(self.comments);
        }

        /// Frees any memory allocated during `parse`
        pub fn deinit(self: Product, allocator: Allocator) void {
            assert(assert_blk: {
                isNameValid(self.name) catch break :assert_blk false;
                break :assert_blk true;
            });
            assert(self.version == null or assert_blk: {
                isVersionValid(self.version.?) catch break :assert_blk false;
                break :assert_blk true;
            });
            assert(self.comments == null or assert_blk: {
                areCommentsValid(self.comments) catch break :assert_blk false;
                break :assert_blk true;
            });

            self._deinitIgnoreValidity(allocator);
        }

        fn _deinitIgnoreValidity(self: Product, allocator: Allocator) void {
            allocator.free(self.name);
            if (self.version != null)
                allocator.free(self.version.?);
            if (self.comments != null) {
                for (self.comments.?) |comment|
                    allocator.free(comment);

                allocator.free(self.comments.?);
            }
        }
    };
};

/// Host header describes target domain name and optional port number of the server the client wants to communicate with
pub const Host = struct {
    const max_hostname_len: usize = 255;

    pub const header_name: []const u8 = "host";
    pub const header_t: HeaderType = .request;
    pub const max_format_len: usize = max_hostname_len + 6;

    hostname: []const u8,
    port: ?u16 = null,

    pub fn isHostnameValid(hostname: []const u8) !void {
        if (hostname.len == 0)
            return error.HostnameTooShort;
        if (hostname.len > max_hostname_len)
            return error.HostnameTooLong;

        var reader = Reader.fixed(hostname);
        while (reader.takeDelimiterExclusive('.') catch null) |label| {
            if (label.len == 0)
                return error.LabelTooShort;
            if (!(isASCIIDigit(label[0]) or isASCIIAlphabetic(label[0])))
                return error.InvalidLabelStart;
            if (!(isASCIIDigit(label[label.len - 1]) or isASCIIAlphabetic(label[label.len - 1])))
                return error.InvalidLabelEnd;

            for (label) |character| {
                if (!(isASCIIDigit(character) or isASCIIAlphabetic(character) or character == '-'))
                    return error.InvalidCharacter;
            }

            if (reader.bufferedLen() == 0)
                break;

            reader.toss(1);
        }
    }

    /// Formats `self` as header value to `writer`
    ///
    /// Use `Host.header_name` for the header name.
    pub fn format(self: Host, writer: *Writer) WriterError!void {
        assert(assert_blk: {
            isHostnameValid(self.hostname) catch break :assert_blk false;
            break :assert_blk true;
        });

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
    /// - Any error will free allocated resources in `self`
    pub fn parse(self: *Host, reader: *Reader, allocator: Allocator) !void {
        var has_port: bool = undefined;

        self.hostname =
            try hostname_blk: {
                const res = reader.takeDelimiterInclusive(':') catch |err| switch (err) {
                    error.EndOfStream => {
                        has_port = false;
                        break :hostname_blk allocator.dupe(u8, try reader.take(reader.bufferedLen()));
                    },
                    else => break :hostname_blk err,
                };
                has_port = true;
                break :hostname_blk allocator.dupe(u8, res[0..(res.len - 1)]);
            };
        errdefer allocator.free(self.hostname);

        try isHostnameValid(self.hostname);

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
    ///
    /// - DO NOT CALL if `self` has been statically initialized
    pub fn deinit(self: Host, allocator: Allocator) void {
        assert(assert_blk: {
            isHostnameValid(self.hostname) catch break :assert_blk false;
            break :assert_blk true;
        });

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

        us_ascii: CommonHeaderFields.USASCII,
        utf_8: CommonHeaderFields.UTF8,

        /// Formats `self` as header parameter to `writer`
        pub fn format(self: Charset, writer: *Writer) WriterError!void {
            switch (self) {
                .us_ascii => try writer.print("{s}={s}", .{ parameter_name, CommonHeaderFields.USASCII.parameter_value }),
                .utf_8 => try writer.print("{s}={s}", .{ parameter_name, CommonHeaderFields.UTF8.parameter_value }),
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
            .mime = CommonHeaderFields.MIMEType{ .text = .plain },
            .charset = Charset{ .utf_8 = .{} },
        };
        pub const json = ContentType{
            .mime = CommonHeaderFields.MIMEType{ .application = .json },
            .charset = Charset{ .utf_8 = .{} },
        };
    };

    pub const header_name: []const u8 = "content-type";
    pub const header_t: HeaderType = .both;
    pub const max_format_len: usize = _maxFormatLen();

    mime: CommonHeaderFields.MIMEType = .{ .text = .plain },
    charset: ?Charset = .utf_8,

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
        assert(!self.mime.isWildcard());
        assert(self.charset == null or self.mime.isCharsetCompatible());

        try self.mime.format(writer);

        if (self.charset) |charset| {
            try writer.print("; {f}", .{charset});
        }
    }

    fn _maxFormatLen() usize {
        var res: usize = CommonHeaderFields.MIMEType.max_format_len;

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
    pub fn parse(self: *ContentType, reader: *Reader) !void {
        try self.mime.parse(reader);

        if (CommonHeaderFields.MIMEType.isWildcard(self.mime))
            return error.FoundWildcard;

        inline for (@typeInfo(ContentType).@"struct".fields) |field| field_loop: {
            comptime if (field.type == CommonHeaderFields.MIMEType)
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

        const AttachmentTag = enum {
            default,
            unencoded,
            encoded,
        };

        pub const Attachment = union(AttachmentTag) {
            pub const Unencoded = struct {
                const max_filename_len: usize = 255;

                pub const parameter_name = "filename";
                pub const max_format_len: usize = parameter_name.len + max_filename_len + 1;

                filename: []const u8,

                pub fn isFilenameValid(filename: []const u8) !void {
                    if (filename.len == 0)
                        return error.FilenameTooShort;
                    if (filename.len > max_filename_len)
                        return error.FilenameTooLong;

                    var escaped: bool = false;
                    var quote_count: usize = 0;
                    for (filename) |character| {
                        if (!isASCIIChar(character))
                            return error.InvalidEncoding;
                        if (isASCIIControl(character))
                            return error.ControlCharacter;

                        if ((escaped and !(character == '\\' or character == '"')) or (!escaped and character == '"'))
                            return error.UnescapedCharacter;

                        escaped = if (escaped) false else if (character == '\\') true else escaped;

                        if (character == '"')
                            quote_count += 1;
                    }

                    if (quote_count % 2 == 1)
                        return error.UnclosedDoubleQuotes;
                }

                /// Formats `self` as header parameter to `writer`
                pub fn format(self: Unencoded, writer: *Writer) WriterError!void {
                    assert(assert_blk: {
                        isFilenameValid(self.filename) catch break :assert_blk false;
                        break :assert_blk true;
                    });

                    try writer.print("{s}=\"{s}\"", .{ parameter_name, self.filename });
                }

                /// Parses from `reader` into `self`
                ///
                /// - `reader` must contain valid filename type.
                /// - `self.filename` will be duplicated. Either pass arena allocator as `allocator`
                ///   or call `deinit` on `self` after use.
                pub fn parse(self: *Unencoded, reader: *Reader, allocator: Allocator) !void {
                    const filename_value = try reader.takeDelimiterExclusive(';');

                    try isFilenameValid(filename_value[1..(filename_value.len - 1)]);

                    if (!(filename_value[0] == '"' and filename_value[filename_value.len - 1] == '"'))
                        return error.InvalidQuotation;

                    self.filename = try allocator.dupe(u8, filename_value[1..(filename_value.len - 1)]);
                }

                /// Frees any memory allocated during `parse`
                pub fn deinit(self: Unencoded, allocator: Allocator) void {
                    assert(assert_blk: {
                        isFilenameValid(self.filename) catch break :assert_blk false;
                        break :assert_blk true;
                    });

                    self._deinitIgnoreValidity(allocator);
                }

                fn _deinitIgnoreValidity(self: Unencoded, allocator: Allocator) void {
                    allocator.free(self.filename);
                }
            };

            pub const Encoded = struct {
                const CharsetTag = enum {
                    us_ascii,
                    utf_8,
                };

                pub const Charset = union(CharsetTag) {
                    us_ascii: CommonHeaderFields.USASCII,
                    utf_8: CommonHeaderFields.UTF8,
                };

                const max_language_len: usize = 16;
                const max_filename_len: usize = 255 * 4;

                pub const parameter_name = "filename*";
                pub const max_format_len: usize = @This()._maxFormatLen();

                charset: Charset = .utf_8,
                language: ?[]const u8 = null,
                filename: []const u8,

                pub fn isLanguageValid(language: []const u8) !void {
                    if (language.len == 0)
                        return error.LanguageTooShort;
                    if (language.len > max_language_len)
                        return error.LanguageTooLong;

                    var reader = Reader.fixed(language);

                    while (reader.takeDelimiterExclusive('-') catch null) |tag| {
                        if (tag.len == 0 or reader.bufferedLen() == 1)
                            return error.TagTooShort;

                        for (tag) |character| {
                            if (!(isASCIIAlphabetic(character) or isASCIIDigit(character)))
                                return error.InvalidCharacter;
                        }

                        if (reader.bufferedLen() == 0)
                            break;

                        reader.toss(1);
                    }
                }

                pub fn isFilenameValid(filename: []const u8, charset: Charset) !void {
                    if (filename.len == 0)
                        return error.FilenameTooShort;
                    if (filename.len > max_filename_len)
                        return error.FilenameTooLong;

                    var encoded: bool = false;
                    var encoded_nibbles: [2]u4 = undefined;
                    var encoded_nibbles_index: u2 = 0;
                    var encoded_bytes: [4]u8 = undefined;
                    var encoded_bytes_index: u3 = 0;
                    for (filename, 0..filename.len) |character, index| {
                        if ((!(isASCIIAlphabetic(character) or isASCIIDigit(character) or character == '-' or character == '_' or character == '.' or character == '~' or character == '%') and !encoded) or
                            (!isASCIIHex(character) and encoded))
                            return error.InvalidCharacter;

                        if (character == '%') {
                            encoded = true;
                            continue;
                        }

                        if (encoded) {
                            encoded_nibbles[encoded_nibbles_index] = charToHex(character);
                            encoded_nibbles_index += 1;

                            if (encoded_nibbles_index > 1) {
                                encoded_bytes[encoded_bytes_index] = @as(u8, encoded_nibbles[0]) << 4 | @as(u8, encoded_nibbles[1]);
                                encoded_bytes_index += 1;

                                encoded_nibbles_index = 0;
                                encoded = false;

                                switch (charset) {
                                    .us_ascii => {
                                        if (!isASCIIChar(encoded_bytes[0]))
                                            return error.InvalidEncoding;

                                        encoded_bytes_index = 0;
                                    },
                                    .utf_8 => {
                                        if (index == filename.len - 1 or filename[index + 1] != '%') {
                                            switch (encoded_bytes_index) {
                                                0 => unreachable,
                                                1 => {},
                                                2 => _ = utf8Decode2(encoded_bytes[0..2].*) catch return error.InvalidEncoding,
                                                3 => _ = utf8Decode3(encoded_bytes[0..3].*) catch return error.InvalidEncoding,
                                                4 => _ = utf8Decode4(encoded_bytes[0..4].*) catch return error.InvalidEncoding,
                                                else => return error.CodepointTooLong,
                                            }

                                            encoded_bytes_index = 0;
                                        }
                                    },
                                }
                            }
                        }
                    }

                    if (encoded or encoded_nibbles_index != 0 or encoded_bytes_index != 0)
                        return error.PartialCharacter;
                }

                /// Formats `self` as header parameter to `writer`
                pub fn format(self: Encoded, writer: *Writer) WriterError!void {
                    assert(self.language == null or assert_blk: {
                        isLanguageValid(self.language.?) catch break :assert_blk false;
                        break :assert_blk true;
                    });
                    assert(assert_blk: {
                        isFilenameValid(self.filename, self.charset) catch break :assert_blk false;
                        break :assert_blk true;
                    });

                    const charset_value = charset_blk: switch (self.charset) {
                        .us_ascii => break :charset_blk CommonHeaderFields.USASCII.parameter_value,
                        .utf_8 => break :charset_blk CommonHeaderFields.UTF8.parameter_value,
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

                    if (language_value.len > 0)
                        try isLanguageValid(language_value);

                    self.language =
                        if (language_value.len > 0)
                            try allocator.dupe(u8, language_value)
                        else
                            null;
                    errdefer {
                        if (self.language != null)
                            allocator.free(self.language.?);
                    }

                    reader.toss(1);
                    const filename_value = try reader.takeDelimiterExclusive(';');

                    try isFilenameValid(filename_value, self.charset);

                    self.filename = try allocator.dupe(u8, filename_value);
                }

                /// Frees any memory allocated during `parse`
                pub fn deinit(self: Encoded, allocator: Allocator) void {
                    assert(self.language == null or assert_blk: {
                        isLanguageValid(self.language.?) catch break :assert_blk false;
                        break :assert_blk true;
                    });
                    assert(assert_blk: {
                        isFilenameValid(self.filename, self.charset) catch break :assert_blk false;
                        break :assert_blk true;
                    });

                    if (self.language != null)
                        allocator.free(self.language.?);
                    allocator.free(self.filename);
                }

                fn _deinitIgnoreValidity(self: Encoded, allocator: Allocator) void {
                    if (self.language != null)
                        allocator.free(self.language.?);
                    allocator.free(self.filename);
                }
            };

            pub const header_value = "attachment";
            pub const max_format_len: usize = 0;

            default: void,
            unencoded: Unencoded,
            encoded: Encoded,

            /// Formats `self` as header parameter to `writer`
            pub fn format(self: Attachment, writer: *Writer) WriterError!void {
                try writer.print("{s}; ", .{header_value});

                switch (self) {
                    .default => writer.undo(2),
                    .unencoded => |filename| try filename.format(writer),
                    .encoded => |filename| try filename.format(writer),
                }
            }

            /// Parses from `reader` into `self`
            ///
            /// - `reader` must contain valid attachment type.
            /// - Contents of `unencoded` and `encoded` will be duplicated. Either pass arena allocator as `allocator`
            ///   or call `deinit` on `self` after use.
            pub fn parse(self: *Attachment, reader: *Reader, allocator: Allocator) !void {
                const header_value_tag = try reader.takeDelimiterExclusive(';');
                if (!eqlIgnoreCase(header_value, header_value_tag))
                    return error.InvalidHeaderValue;

                switch (reader.bufferedLen()) {
                    0 => {
                        self.* = .default;
                        return;
                    },
                    1, 2 => return error.InvalidParameterName,
                    else => reader.toss(2),
                }

                const parameter_name_value = try reader.takeDelimiterExclusive('=');
                reader.toss(1);

                inline for (@typeInfo(Attachment).@"union".fields) |field| field_loop: {
                    if (comptime field.type == void)
                        break :field_loop;

                    if (!eqlIgnoreCase(field.type.parameter_name, parameter_name_value))
                        break :field_loop;

                    self.* = @unionInit(Attachment, field.name, undefined);
                    try @field(self, field.name).parse(reader, allocator);

                    return;
                }

                return error.InvalidParameterName;
            }

            /// Frees any memory allocated during `parse`
            pub fn deinit(self: Attachment, allocator: Allocator) void {
                switch (self) {
                    .default => {},
                    .unencoded => self.unencoded.deinit(allocator),
                    .encoded => self.encoded.deinit(allocator),
                }
            }

            fn _deinitIgnoreValidity(self: Attachment, allocator: Allocator) void {
                switch (self) {
                    .default => {},
                    .unencoded => self.unencoded._deinitIgnoreValidity(allocator),
                    .encoded => self.encoded._deinitIgnoreValidity(allocator),
                }
            }
        };

        @"inline": Inline,
        attachment: Attachment,
    };

    pub const header_name: []const u8 = "content-disposition";
    pub const header_t: HeaderType = .response;
    pub const max_format_len: usize = _maxFormatLen();

    disposition: DispositionType,

    /// Formats `self` as header value to `writer`
    ///
    /// Use `ContentDisposition.header_name` for the header name.
    pub fn format(self: ContentDisposition, writer: *Writer) WriterError!void {
        switch (self.disposition) {
            .@"inline" => try writer.writeAll(DispositionType.Inline.header_value),
            .attachment => |attachment| try attachment.format(writer),
        }
    }

    fn _maxFormatLen() usize {
        var res: usize = 0;

        inline for (@typeInfo(DispositionType).@"union".fields) |field| {
            const field_max_format_len =
                if (comptime field.type == DispositionType.Inline)
                    field.type.header_value.len
                else
                    field.type.header_value.len + field.type.max_format_len;

            if (field_max_format_len > res)
                res = field_max_format_len;
        }

        return res;
    }

    /// Parses from `reader` into `self`
    ///
    /// - `reader` must contain valid header value and only it.
    /// - `self.disposition` and its contents may need to be duplicated.
    ///   Either pass arena allocator as `allocator` or call `deinit` on `self` after use.
    /// - Any error will free allocated resources in `self`
    pub fn parse(self: *ContentDisposition, reader: *Reader, allocator: Allocator) !void {
        const disposition_tag = try reader.peekDelimiterExclusive(';');

        inline for (@typeInfo(DispositionType).@"union".fields) |field| field_loop: {
            if (!eqlIgnoreCase(field.type.header_value, disposition_tag))
                break :field_loop;

            self.disposition = @unionInit(DispositionType, field.name, undefined);
            if (comptime field.type == DispositionType.Inline) {
                reader.toss(field.type.header_value.len);
                @field(self.disposition, field.name) = field.type{};
            } else try @field(self.disposition, field.name).parse(reader, allocator);
            errdefer self._deinitIgnoreValidity(allocator);

            if (reader.bufferedLen() != 0)
                return error.ExcessHeaderTail
            else
                return;
        }

        return error.InvalidDisposition;
    }

    /// Frees any memory allocated during `init` or `parse`
    ///
    /// - DO NOT CALL if `self` has been statically initialized
    pub fn deinit(self: ContentDisposition, allocator: Allocator) void {
        if (self.disposition == .attachment)
            self.disposition.attachment.deinit(allocator);
    }

    fn _deinitIgnoreValidity(self: ContentDisposition, allocator: Allocator) void {
        if (self.disposition == .attachment)
            self.disposition.attachment._deinitIgnoreValidity(allocator);
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
    pub fn parse(self: *ContentLength, reader: *Reader) !void {
        const header_value = try reader.take(reader.bufferedLen());

        self.length = try parseInt(usize, header_value, 10);

        if (reader.bufferedLen() != 0)
            return error.ExcessHeaderTail;
    }
};

/// Accept header describes what MIMETypes can sender accept as body of response
pub const Accept = struct {
    pub const MediaRange = struct {
        pub const max_format_len = CommonHeaderFields.MIMEType.max_format_len + 9;

        mime: CommonHeaderFields.MIMEType = .wildcard,
        quality: ?f32 = null,

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

    media_ranges: []const MediaRange = &[_]MediaRange{.{}},

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
    /// - `self.media_ranges` need to be allocated.
    ///   Either pass arena allocator as `allocator` or call `deinit` on `self` after use.
    /// - Any error will free allocated resources in `self`
    pub fn parse(self: *Accept, reader: *Reader, allocator: Allocator) !void {
        var res: ArrayList(MediaRange) = try ArrayList(MediaRange).initCapacity(allocator, media_ranges_capacity);
        errdefer res.deinit(allocator);

        inline for (0..media_ranges_capacity) |_| {
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
    ///
    /// - DO NOT CALL if `self` has been statically initialized
    pub fn deinit(self: Accept, allocator: Allocator) void {
        assert(self.media_ranges.len > 0 and self.media_ranges.len <= 16);

        allocator.free(self.media_ranges);
    }
};

/// Server header describes what server is sending response to request
pub const Server = struct {
    const ProductTypeTag = enum {
        secure,
        products,
    };

    pub const ProductType = union(ProductTypeTag) {
        secure: void,
        products: []const CommonHeaderFields.Product,
    };

    const products_capacity: usize = 6;

    pub const header_name: []const u8 = "server";
    pub const header_t: HeaderType = .response;
    pub const max_format_len: usize = _maxFormatLen();

    product: ProductType = .secure,

    /// Formats `self` as header value to `writer`
    ///
    /// Use `Server.header_name` for the header name.
    pub fn format(self: Server, writer: *Writer) WriterError!void {
        assert(self.product == .secure or (self.product.products.len > 0 and self.product.products.len <= products_capacity));

        switch (self.product) {
            .secure => try writer.writeAll("secure"),
            .products => |products| {
                for (products) |product| {
                    try product.format(writer);
                    try writer.writeByte(' ');
                }

                writer.undo(1);
            },
        }
    }

    fn _maxFormatLen() usize {
        const secure_header_value = "secure";
        var res: usize = 0;

        inline for (@typeInfo(ProductType).@"union".fields) |field| field_loop: {
            if (field.type == void and secure_header_value.len > res) {
                res = secure_header_value.len;
                break :field_loop;
            }
            if (field.type != void and field.type.max_format_len > res) {
                res = field.type.max_format_len;
                break :field_loop;
            }
        }

        res += 1;
        res *= products_capacity;

        return res;
    }

    /// Parses from `reader` into `self`
    ///
    /// - `reader` must contain valid header value and only it.
    /// - `self.product` may need to be duplicated.
    ///   Either pass arena allocator as `allocator` or call `deinit` on `self` after use.
    /// - Any error will free allocated resources in `self`
    pub fn parse(self: *Server, reader: *Reader, allocator: Allocator) !void {
        const secure_header_value = "secure";
        const is_secure: bool =
            secure_blk: {
                if (reader.bufferedLen() >= secure_header_value.len) {
                    const header_value = try reader.peek(secure_header_value.len);

                    if (eqlIgnoreCase(secure_header_value, header_value))
                        break :secure_blk true
                    else
                        break :secure_blk false;
                } else break :secure_blk false;
            };

        if (is_secure) {
            reader.toss(secure_header_value.len);
            self.product = .secure;
        } else {
            var products = try ArrayList(CommonHeaderFields.Product).initCapacity(allocator, products_capacity);
            errdefer {
                for (products.items) |product|
                    product.deinit(allocator);
                products.deinit(allocator);
            }

            var product_count: usize = 0;
            inline for (0..products_capacity) |index| {
                var product: CommonHeaderFields.Product = undefined;
                try product.parse(reader, allocator);

                products.appendAssumeCapacity(product);

                if (reader.bufferedLen() == 0) {
                    product_count = index + 1;
                    break;
                }

                const product_delimiter_value = try reader.take(1);

                if (product_delimiter_value[0] != ' ')
                    return error.InvalidProductDelimiter;
            }

            if (product_count == 0)
                return error.TooManyProducts;

            self.product = .{ .products = try products.toOwnedSlice(allocator) };
        }
        errdefer self._deinitIgnoreValidity(allocator);

        if (reader.bufferedLen() != 0)
            return error.ExcessHeaderTail;
    }

    /// Frees any memory allocated during `parse`
    ///
    /// - DO NOT CALL if `self` has been statically initialized
    pub fn deinit(self: Server, allocator: Allocator) void {
        if (self.product == .products) {
            for (self.product.products) |product| {
                product.deinit(allocator);
            }
            allocator.free(self.product.products);
        }
    }

    fn _deinitIgnoreValidity(self: Server, allocator: Allocator) void {
        if (self.product == .products) {
            for (self.product.products) |product| {
                product._deinitIgnoreValidity(allocator);
            }
            allocator.free(self.product.products);
        }
    }
};

/// User-Agent header describes what client is sending request
pub const UserAgent = struct {
    const products_capacity: usize = 6;

    pub const header_name: []const u8 = "user-agent";
    pub const header_t: HeaderType = .request;
    pub const max_format_len: usize = products_capacity * (CommonHeaderFields.Product.max_format_len + 1);

    products: []const CommonHeaderFields.Product,

    /// Formats `self` as header value to `writer`
    ///
    /// Use `UserAgent.header_name` for the header name.
    pub fn format(self: UserAgent, writer: *Writer) WriterError!void {
        assert(self.products.len > 0 and self.products.len <= products_capacity);

        for (self.products) |product| {
            try product.format(writer);
            try writer.writeByte(' ');
        }

        writer.undo(1);
    }

    /// Parses from `reader` into `self`
    ///
    /// - `reader` must contain valid header value and only it.
    /// - `self.products` will be allocated.
    ///   Either pass arena allocator as `allocator` or call `deinit` on `self` after use.
    /// - Any error will free allocated resources in `self`
    pub fn parse(self: *UserAgent, reader: *Reader, allocator: Allocator) !void {
        var res = try ArrayList(CommonHeaderFields.Product).initCapacity(allocator, products_capacity);
        errdefer {
            for (res.items) |product|
                product.deinit(allocator);
            res.deinit(allocator);
        }

        var product_count: usize = 0;
        inline for (0..products_capacity) |index| {
            var product: CommonHeaderFields.Product = undefined;
            try product.parse(reader, allocator);

            res.appendAssumeCapacity(product);

            if (reader.bufferedLen() == 0) {
                product_count = index + 1;
                break;
            }

            const product_delimiter_value = try reader.take(1);

            if (product_delimiter_value[0] != ' ')
                return error.InvalidProductDelimiter;
        }

        self.products = try res.toOwnedSlice(allocator);
        errdefer self._deinitIgnoreValidity(allocator);

        if (reader.bufferedLen() != 0)
            return if (product_count == 0)
                error.TooFewProducts
            else
                error.TooManyProducts;
    }

    /// Frees any memory allocated during `parse`
    ///
    /// - DO NOT CALL if `self` has been statically initialized
    pub fn deinit(self: UserAgent, allocator: Allocator) void {
        for (self.products) |product| {
            product.deinit(allocator);
        }

        allocator.free(self.products);
    }

    fn _deinitIgnoreValidity(self: UserAgent, allocator: Allocator) void {
        for (self.products) |product| {
            product._deinitIgnoreValidity(allocator);
        }

        allocator.free(self.products);
    }
};

/// Date header describes at what time (UTC) was request or response generated
pub const Date = struct {
    pub const header_name: []const u8 = "date";
    pub const header_t: HeaderType = .both;
    pub const max_format_len: usize = 29;

    time: Time,

    /// Formats `self` as header value to `writer`
    ///
    /// Use `Date.header_name` for the header name.
    pub fn format(self: Date, writer: *Writer) WriterError!void {
        assert(self.time.offset == 0);

        self.time.strftime(writer, "%a, %d %b %Y %T GMT") catch return WriterError.WriteFailed;
    }

    /// Parses from `reader` into `self`
    ///
    /// `reader` must contain valid header value and only it.
    pub fn parse(self: *Date, reader: *Reader) !void {
        if (reader.bufferedLen() < max_format_len)
            return error.DateTooShort;
        if (reader.bufferedLen() > max_format_len)
            return error.DateTooLong;

        const header_value = try reader.take(reader.bufferedLen());

        self.time = try Time.fromRFC1123(header_value);
    }
};

/// Connection header describes what client and server should do with connection of request or response
pub const Connection = struct {
    const DirectiveTag = enum {
        close,
        keep_alive,
        upgrade,
        custom,
    };

    pub const Directive = union(DirectiveTag) {
        pub const Close = struct {
            pub const parameter_value = "close";
        };

        pub const KeepAlive = struct {
            pub const parameter_value = "keep-alive";
        };

        pub const Upgrade = struct {
            pub const parameter_value = "upgrade";
        };

        const max_custom_directive_len: usize = 64;

        pub const max_format_len: usize = @This()._maxFormatLen();

        close: Close,
        keep_alive: KeepAlive,
        upgrade: Upgrade,
        custom: []const u8,

        pub fn isCustomDirectiveValid(directive: []const u8) !void {
            if (directive.len == 0)
                return error.DirectiveTooShort;
            if (directive.len > max_custom_directive_len)
                return error.DirectiveTooLong;

            try isTokenValid(directive);
        }

        /// Formats `self` as header parameter to `writer`
        pub fn format(self: Directive, writer: *Writer) WriterError!void {
            assert(self != .custom or assert_blk: {
                isCustomDirectiveValid(self.custom) catch break :assert_blk false;
                break :assert_blk true;
            });

            switch (self) {
                .close => try writer.writeAll(Close.parameter_value),
                .keep_alive => try writer.writeAll(KeepAlive.parameter_value),
                .upgrade => try writer.writeAll(Upgrade.parameter_value),
                .custom => |parameter_value| try writer.writeAll(parameter_value),
            }
        }

        fn _maxFormatLen() usize {
            var res: usize = 0;

            inline for (@typeInfo(Directive).@"union".fields) |field| {
                const max_len =
                    if (field.type == []const u8)
                        max_custom_directive_len
                    else
                        field.type.parameter_value.len;
                if (res < max_len)
                    res = max_len;
            }

            return res;
        }

        /// Parses from `reader` into `self`
        ///
        /// - `reader` must contain valid directive.
        /// - `self.custom` can be duplicated.
        ///   Either pass arena allocator as `allocator` or call `deinit` on `self` after use.
        /// - Any error will free allocated resources in `self`
        pub fn parse(self: *Directive, reader: *Reader, allocator: Allocator) !void {
            const parameter_value = try reader.takeDelimiterExclusive(',');

            inline for (@typeInfo(Directive).@"union".fields) |field| field_loop: {
                if (comptime field.type != []const u8) {
                    if (!eqlIgnoreCase(field.type.parameter_value, parameter_value))
                        break :field_loop;

                    self.* = @unionInit(Directive, field.name, field.type{});
                    return;
                } else {
                    try isCustomDirectiveValid(parameter_value);

                    self.* = @unionInit(Directive, field.name, try allocator.dupe(u8, parameter_value));
                    return;
                }
            }

            return error.InvalidDirective;
        }

        /// Frees any memory allocated during `parse`
        pub fn deinit(self: Directive, allocator: Allocator) void {
            assert(self != .custom or assert_blk: {
                isCustomDirectiveValid(self.custom) catch break :assert_blk false;
                break :assert_blk true;
            });

            if (self == .custom)
                allocator.free(self.custom);
        }

        fn _deinitIgnoreValidity(self: Directive, allocator: Allocator) void {
            if (self == .custom)
                allocator.free(self.custom);
        }

        pub fn isControlDirective(self: Directive) bool {
            switch (self) {
                .close, .keep_alive => return true,
                else => return false,
            }
        }
    };

    const directives_capacity: usize = 8;

    pub const header_name: []const u8 = "connection";
    pub const header_t: HeaderType = .both;
    pub const max_format_len: usize = directives_capacity * Directive.max_format_len;

    directives: []const Directive = &[_]Directive{.close},

    pub fn areDirectivesValid(directives: []const Directive) !void {
        if (directives.len == 0)
            return error.TooFewDirectives;
        if (directives.len > directives_capacity)
            return error.TooManyDirectives;

        for (directives, 0..) |directive, index| {
            if (directive.isControlDirective() and index != 0)
                return error.InvalidDirectiveOrder;

            if (directive == .custom)
                try Directive.isCustomDirectiveValid(directive.custom);
        }
    }

    /// Formats `self` as header value to `writer`
    ///
    /// Use `Connection.header_name` for the header name.
    pub fn format(self: Connection, writer: *Writer) WriterError!void {
        assert(assert_blk: {
            areDirectivesValid(self.directives) catch break :assert_blk false;
            break :assert_blk true;
        });

        for (self.directives) |directive| {
            try directive.format(writer);
            try writer.writeAll(", ");
        }

        writer.undo(2);
    }

    /// Parses from `reader` into `self`
    ///
    /// - `reader` must contain valid header value and only it.
    /// - `self.directives` will be allocated.
    ///   Either pass arena allocator as `allocator` or call `deinit` on `self` after use.
    /// - Any error will free allocated resources in `self`
    pub fn parse(self: *Connection, reader: *Reader, allocator: Allocator) !void {
        var res = try ArrayList(Directive).initCapacity(allocator, directives_capacity);
        errdefer {
            for (res.items) |product|
                product.deinit(allocator);
            res.deinit(allocator);
        }

        var directive_count: usize = 0;
        inline for (0..directives_capacity) |index| {
            var directive: Directive = undefined;
            try directive.parse(reader, allocator);

            res.appendAssumeCapacity(directive);

            if (reader.bufferedLen() < 2) {
                directive_count = index + 1;
                break;
            }

            const directive_delimiter_value = try reader.take(2);

            if (!eqlMem(u8, ", ", directive_delimiter_value))
                return error.InvalidDirectiveDelimiter;
        }

        self.directives = try res.toOwnedSlice(allocator);
        errdefer self._deinitIgnoreValidity(allocator);

        try areDirectivesValid(self.directives);

        if (reader.bufferedLen() != 0)
            return if (directive_count == 0)
                error.TooFewDirectives
            else
                error.TooManyDirectives;
    }

    /// Frees any memory allocated during `parse`
    ///
    /// - DO NOT CALL if `self` has been statically initialized
    pub fn deinit(self: Connection, allocator: Allocator) void {
        assert(assert_blk: {
            areDirectivesValid(self.directives) catch break :assert_blk false;
            break :assert_blk true;
        });

        for (self.directives) |directive| {
            directive.deinit(allocator);
        }
        allocator.free(self.directives);
    }

    fn _deinitIgnoreValidity(self: Connection, allocator: Allocator) void {
        for (self.directives) |directive| {
            directive._deinitIgnoreValidity(allocator);
        }
        allocator.free(self.directives);
    }
};

/// Cache-Control header describes how should client and server cache resources
pub const CacheControl = struct {
    const RevalidationDirectiveTag = enum {
        immutable,
        proxy_revalidate,
        must_revalidate,
    };

    pub const RevalidationDirective = union(RevalidationDirectiveTag) {
        pub const Immutable = struct {
            pub const parameter_value = "immutable";
        };

        pub const ProxyRevalidate = struct {
            pub const parameter_value = "proxy-revalidate";
        };

        pub const MustRevalidate = struct {
            pub const parameter_value = "must-revalidate";
        };

        pub const max_format_len: usize = @This()._maxFormatLen();

        immutable: Immutable,
        proxy_revalidate: ProxyRevalidate,
        must_revalidate: MustRevalidate,

        pub fn isValid(self: RevalidationDirective, comptime Type: HeaderType) !void {
            comptime if (Type == .both)
                @compileError("`Type` must be either request or response");

            if (comptime Type == .request)
                if (self == .immutable)
                    return error.InvalidRequestDirective;
        }

        /// Formats `self` as header value to `writer`
        pub fn format(self: RevalidationDirective, writer: *Writer) WriterError!void {
            switch (self) {
                .immutable => try writer.writeAll(Immutable.parameter_value),
                .proxy_revalidate => try writer.writeAll(ProxyRevalidate.parameter_value),
                .must_revalidate => try writer.writeAll(MustRevalidate.parameter_value),
            }
        }

        fn _maxFormatLen() usize {
            var res: usize = 0;

            inline for (@typeInfo(RevalidationDirective).@"union".fields) |field| {
                if (field.type.parameter_value.len > res)
                    res = field.type.parameter_value.len;
            }

            return res;
        }

        /// Parses from `reader` into `self`
        ///
        /// - `reader` must contain valid revalidation directive.
        pub fn parse(self: *RevalidationDirective, reader: *Reader) !void {
            const header_parameter_value = try reader.takeDelimiterExclusive(',');

            inline for (@typeInfo(RevalidationDirective).@"union".fields) |field| field_loop: {
                if (!eqlIgnoreCase(field.type.parameter_value, header_parameter_value))
                    break :field_loop;

                self.* = @unionInit(RevalidationDirective, field.name, field.type{});

                return;
            }

            return error.InvalidDirective;
        }
    };

    const MaxStaleTag = enum {
        any,
        max_stale,
    };

    pub const MaxStale = union(MaxStaleTag) {
        pub const parameter_value: []const u8 = "max-stale";
        pub const max_format_len = parameter_value.len + 11;

        any: void,
        max_stale: u32,

        /// Formats `self` as header value to `writer`
        pub fn format(self: MaxStale, writer: *Writer) WriterError!void {
            switch (self) {
                .any => try writer.writeAll("max-stale"),
                .max_stale => |max_stale_value| try writer.print("max-stale={d}", .{max_stale_value}),
            }
        }

        /// Parses from `reader` into `self`
        ///
        /// - `reader` must contain valid max stale directive.
        pub fn parse(self: *MaxStale, reader: *Reader) !void {
            const header_parameter_value = try reader.takeDelimiterExclusive(',');

            if (!eqlIgnoreCase(header_parameter_value[0..parameter_value.len], parameter_value))
                return error.InvalidDirective;

            if (header_parameter_value.len == parameter_value.len) {
                self.* = .any;
            } else {
                if (header_parameter_value.len <= parameter_value.len + 1 or header_parameter_value[parameter_value.len] != '=')
                    return error.MissingValue;

                self.* = .{ .max_stale = try parseInt(u32, header_parameter_value[parameter_value.len + 1 ..], 10) };
            }
        }
    };

    const ScopeDirectiveTag = enum {
        no_store,
        private,
        public,
    };

    pub const ScopeDirective = union(ScopeDirectiveTag) {
        pub const NoStore = struct {
            pub const parameter_value: []const u8 = "no-store";
            pub const max_format_len: usize = parameter_value.len;

            /// Formats `self` as header value to `writer`
            pub fn format(_: NoStore, writer: *Writer) WriterError!void {
                try writer.writeAll(parameter_value);
            }
        };

        pub const Private = struct {
            pub const parameter_value: []const u8 = "private";
            pub const max_format_len: usize = @This()._maxFormatLen();

            no_transform: bool = false,
            no_cache: bool = false,
            only_if_cached: bool = false,
            max_age: ?u32 = 3600,
            s_maxage: ?u32 = null,
            stale_while_revalidate: ?u32 = null,
            stale_if_error: ?u32 = null,
            min_fresh: ?u32 = null,
            max_stale: ?MaxStale = null,
            revalidation: ?RevalidationDirective = null,

            pub fn isValid(self: Private, comptime Type: HeaderType) !void {
                switch (Type) {
                    inline .both => @compileError("`Type` must be either request or response"),
                    inline .request => {
                        if (self.s_maxage != null or self.stale_while_revalidate != null or self.stale_if_error != null)
                            return error.InvalidResponseDirective;
                    },
                    inline .response => {
                        if (self.only_if_cached or self.max_age != null or self.min_fresh != null)
                            return error.InvalidResponseDirective;
                    },
                }

                if (self.revalidation) |revalidation|
                    try revalidation.isValid(Type);
            }

            /// Formats `self` as header value to `writer`
            pub fn format(self: Private, writer: *Writer) WriterError!void {
                assert(self.revalidation == null or self.revalidation.? != .proxy_revalidate);

                try writer.writeAll(parameter_value);

                if (self.no_transform)
                    try writer.writeAll(", no-transform");
                if (self.no_cache)
                    try writer.writeAll(", no-cache");
                if (self.only_if_cached)
                    try writer.writeAll(", only-if-cached");
                if (self.max_age) |max_age|
                    try writer.print(", max-age={d}", .{max_age});
                if (self.s_maxage) |s_maxage|
                    try writer.print(", s-maxage={d}", .{s_maxage});
                if (self.stale_while_revalidate) |stale_while_revalidate|
                    try writer.print(", stale-while-revalidate={d}", .{stale_while_revalidate});
                if (self.stale_if_error) |stale_if_error|
                    try writer.print(", stale-if-error={d}", .{stale_if_error});
                if (self.min_fresh) |min_fresh|
                    try writer.print(", min-fresh={d}", .{min_fresh});
                if (self.max_stale) |max_stale| {
                    try writer.print(", {f}", .{max_stale});
                }
                if (self.revalidation) |revalidation|
                    try writer.print(", {f}", .{revalidation});
            }

            fn _maxFormatLen() usize {
                var res: usize = parameter_value.len + 2;

                inline for (@typeInfo(Private).@"struct".fields) |field| {
                    switch (field.type) {
                        bool => res += field.name.len + 2,
                        ?u32 => res += fieldNameToHeaderParameter(field.name).len + 13,
                        else => res += @typeInfo(field.type).optional.child.max_format_len + 2,
                    }
                }

                return res;
            }

            /// Parses from `reader` into `self`
            ///
            /// - `reader` must contain valid private directive.
            pub fn parse(self: *Private, comptime Type: HeaderType, reader: *Reader) !void {
                const info = @typeInfo(Private).@"struct";

                var field_check_array = [1]bool{false} ** info.fields.len;

                while (reader.bufferedLen() > 0) reader_loop: {
                    var has_other_directives: bool = undefined;

                    const header_parameter_value =
                        try parameter_value_blk: {
                            const res = reader.peekDelimiterInclusive(',') catch |err| switch (err) {
                                error.EndOfStream => {
                                    has_other_directives = false;
                                    break :parameter_value_blk try reader.peek(reader.bufferedLen());
                                },
                                else => break :parameter_value_blk err,
                            };
                            has_other_directives = true;
                            break :parameter_value_blk res[0..(res.len - 1)];
                        };

                    inline for (info.fields, 0..) |field, index| field_loop: {
                        switch (field.type) {
                            inline bool => {
                                if (!eqlIgnoreCase(comptime fieldNameToHeaderParameter(field.name), header_parameter_value))
                                    break :field_loop;

                                if (field_check_array[index] == true)
                                    return error.DuplicateParameter;

                                fieldPtr(Private, field.name, self).* = true;

                                reader.toss(header_parameter_value.len);
                            },
                            inline ?u32 => {
                                if (header_parameter_value.len <= field.name.len or !eqlIgnoreCase(comptime fieldNameToHeaderParameter(field.name), header_parameter_value[0..field.name.len]))
                                    break :field_loop;

                                if (field_check_array[index] == true)
                                    return error.DuplicateParameter;

                                if (header_parameter_value.len <= field.name.len + 1)
                                    return error.MissingValue;

                                fieldPtr(Private, field.name, self).* = try parseInt(u32, header_parameter_value[field.name.len + 1 ..], 10);

                                reader.toss(header_parameter_value.len);
                            },
                            inline ?MaxStale => {
                                if (header_parameter_value.len < MaxStale.parameter_value.len or !eqlIgnoreCase(MaxStale.parameter_value, header_parameter_value[0..MaxStale.parameter_value.len]))
                                    break :field_loop;

                                if (field_check_array[index] == true)
                                    return error.DuplicateParameter;

                                try fieldPtr(Private, field.name, self).*.?.parse(reader);
                            },
                            inline ?RevalidationDirective => {
                                inline for (@typeInfo(RevalidationDirective).@"union".fields) |revalidation_field| revalidation_field_loop: {
                                    if (!eqlIgnoreCase(revalidation_field.type.parameter_value, header_parameter_value))
                                        break :revalidation_field_loop;

                                    if (field_check_array[index] == true)
                                        return error.DuplicateParameter;

                                    try fieldPtr(Private, field.name, self).*.?.parse(reader);
                                }
                            },
                            inline else => unreachable,
                        }

                        if (has_other_directives) {
                            if (reader.bufferedLen() <= 2)
                                return error.InvalidDelimiter;

                            const delimiter_value = try reader.take(2);

                            if (!eqlMem(u8, ", ", delimiter_value))
                                return error.InvalidDelimiter;
                        }

                        field_check_array[index] = true;

                        break :reader_loop;
                    }

                    return error.InvalidDirective;
                }

                inline for (info.fields, 0..) |field, index| check_loop: {
                    if (field_check_array[index])
                        break :check_loop;

                    fieldPtr(Private, field.name, self).* = field.defaultValue().?;
                }

                try @This().isValid(self.*, Type);
            }
        };

        pub const Public = struct {
            pub const parameter_value: []const u8 = "public";
            pub const max_format_len: usize = @This()._maxFormatLen();

            no_transform: bool = false,
            no_cache: bool = false,
            only_if_cached: bool = false,
            max_age: ?u32 = 3600,
            s_maxage: ?u32 = null,
            stale_while_revalidate: ?u32 = null,
            stale_if_error: ?u32 = null,
            min_fresh: ?u32 = null,
            max_stale: ?MaxStale = null,
            revalidation: ?RevalidationDirective = null,

            pub fn isValid(self: Public, comptime Type: HeaderType) !void {
                switch (Type) {
                    inline .both => @compileError("`Type` must be either request or response"),
                    inline .request => {
                        if (self.s_maxage != null or self.stale_while_revalidate != null or self.stale_if_error != null)
                            return error.InvalidResponseDirective;
                    },
                    inline .response => {
                        if (self.only_if_cached or self.max_age != null or self.min_fresh != null)
                            return error.InvalidResponseDirective;
                    },
                }

                if (self.revalidation) |revalidation|
                    try revalidation.isValid(Type);
            }

            /// Formats `self` as header value to `writer`
            pub fn format(self: Public, writer: *Writer) WriterError!void {
                try writer.writeAll(parameter_value);

                if (self.no_transform)
                    try writer.writeAll(", no-transform");
                if (self.no_cache)
                    try writer.writeAll(", no-cache");
                if (self.only_if_cached)
                    try writer.writeAll(", only-if-cached");
                if (self.max_age) |max_age|
                    try writer.print(", max-age={d}", .{max_age});
                if (self.s_maxage) |s_maxage|
                    try writer.print(", s-maxage={d}", .{s_maxage});
                if (self.stale_while_revalidate) |stale_while_revalidate|
                    try writer.print(", stale-while-revalidate={d}", .{stale_while_revalidate});
                if (self.stale_if_error) |stale_if_error|
                    try writer.print(", stale-if-error={d}, ", .{stale_if_error});
                if (self.min_fresh) |min_fresh|
                    try writer.print(", min-fresh={d}", .{min_fresh});
                if (self.max_stale) |max_stale| {
                    try writer.print(", {f}", .{max_stale});
                }
                if (self.revalidation) |revalidation|
                    try writer.print(", {f}", .{revalidation});
            }

            fn _maxFormatLen() usize {
                var res: usize = parameter_value.len + 2;

                inline for (@typeInfo(Private).@"struct".fields) |field| {
                    switch (field.type) {
                        bool => res += field.name.len + 2,
                        ?u32 => res += fieldNameToHeaderParameter(field.name).len + 13,
                        else => res += @typeInfo(field.type).optional.child.max_format_len + 2,
                    }
                }

                return res;
            }

            /// Parses from `reader` into `self`
            ///
            /// - `reader` must contain valid public directive.
            pub fn parse(self: *Public, comptime Type: HeaderType, reader: *Reader) !void {
                const info = @typeInfo(Public).@"struct";

                var field_check_array = [1]bool{false} ** info.fields.len;

                while (reader.bufferedLen() > 0) reader_loop: {
                    var has_other_directives: bool = undefined;

                    const header_parameter_value =
                        try parameter_value_blk: {
                            const res = reader.peekDelimiterInclusive(',') catch |err| switch (err) {
                                error.EndOfStream => {
                                    has_other_directives = false;
                                    break :parameter_value_blk try reader.peek(reader.bufferedLen());
                                },
                                else => break :parameter_value_blk err,
                            };
                            has_other_directives = true;
                            break :parameter_value_blk res[0..(res.len - 1)];
                        };

                    inline for (info.fields, 0..) |field, index| field_loop: {
                        switch (field.type) {
                            inline bool => {
                                if (!eqlIgnoreCase(comptime fieldNameToHeaderParameter(field.name), header_parameter_value))
                                    break :field_loop;

                                if (field_check_array[index] == true)
                                    return error.DuplicateParameter;

                                fieldPtr(Public, field.name, self).* = true;

                                reader.toss(header_parameter_value.len);
                            },
                            inline ?u32 => {
                                if (header_parameter_value.len <= field.name.len or !eqlIgnoreCase(comptime fieldNameToHeaderParameter(field.name), header_parameter_value[0..field.name.len]))
                                    break :field_loop;

                                if (field_check_array[index] == true)
                                    return error.DuplicateParameter;

                                if (header_parameter_value.len <= field.name.len + 1)
                                    return error.MissingValue;

                                fieldPtr(Public, field.name, self).* = try parseInt(u32, header_parameter_value[field.name.len + 1 ..], 10);

                                reader.toss(header_parameter_value.len);
                            },
                            inline ?MaxStale => {
                                if (header_parameter_value.len < MaxStale.parameter_value.len or !eqlIgnoreCase(MaxStale.parameter_value, header_parameter_value[0..MaxStale.parameter_value.len]))
                                    break :field_loop;

                                if (field_check_array[index] == true)
                                    return error.DuplicateParameter;

                                try fieldPtr(Public, field.name, self).*.?.parse(reader);
                            },
                            inline ?RevalidationDirective => {
                                inline for (@typeInfo(RevalidationDirective).@"union".fields) |revalidation_field| revalidation_field_loop: {
                                    if (!eqlIgnoreCase(revalidation_field.type.parameter_value, header_parameter_value))
                                        break :revalidation_field_loop;

                                    if (field_check_array[index] == true)
                                        return error.DuplicateParameter;

                                    try fieldPtr(Public, field.name, self).*.?.parse(reader);
                                }
                            },
                            inline else => unreachable,
                        }

                        if (has_other_directives) {
                            if (reader.bufferedLen() <= 2)
                                return error.InvalidDelimiter;

                            const delimiter_value = try reader.take(2);

                            if (!eqlMem(u8, ", ", delimiter_value))
                                return error.InvalidDelimiter;
                        }

                        field_check_array[index] = true;

                        break :reader_loop;
                    }

                    return error.InvalidDirective;
                }

                inline for (info.fields, 0..) |field, index| check_loop: {
                    if (field_check_array[index])
                        break :check_loop;

                    fieldPtr(Public, field.name, self).* = field.defaultValue().?;
                }

                try @This().isValid(self.*, Type);
            }
        };

        no_store: NoStore,
        private: Private,
        public: Public,

        pub fn isValid(self: ScopeDirective, comptime Type: HeaderType) !void {
            comptime if (Type == .both)
                @compileError("`Type` must be either request or response");

            switch (self) {
                .no_store => {},
                .private => |private| try private.isValid(Type),
                .public => |public| try public.isValid(Type),
            }
        }

        /// Formats `self` as header value to `writer`
        pub fn format(self: ScopeDirective, writer: *Writer) WriterError!void {
            switch (self) {
                .no_store => |no_store| try no_store.format(writer),
                .private => |private| try private.format(writer),
                .public => |public| try public.format(writer),
            }
        }

        /// Parses from `reader` into `self`
        ///
        /// - `reader` must contain valid scope directive.
        pub fn parse(self: *ScopeDirective, comptime Type: HeaderType, reader: *Reader) !void {
            const header_parameter_value = try reader.takeDelimiterExclusive(',');

            inline for (@typeInfo(ScopeDirective).@"union".fields) |field| field_loop: {
                if (!eqlIgnoreCase(field.type.parameter_value, header_parameter_value))
                    break :field_loop;

                if (comptime field.type != NoStore) {
                    if (reader.bufferedLen() > 2) {
                        const delimiter_value = try reader.take(2);

                        if (!eqlMem(u8, ", ", delimiter_value))
                            return error.ExcessHeaderTail;
                    }

                    self.* = @unionInit(ScopeDirective, field.name, undefined);
                    try @field(self, field.name).parse(Type, reader);
                } else self.* = @unionInit(ScopeDirective, field.name, field.type{});

                return;
            }

            return error.InvalidScopeDirective;
        }
    };

    pub const header_name: []const u8 = "cache-control";
    pub const header_t: HeaderType = .both;
    pub const max_format_len: usize = _maxFormatLen();

    scope_directive: ScopeDirective = .no_store,

    pub fn isValid(self: CacheControl, comptime Type: HeaderType) !void {
        comptime if (Type == .both)
            @compileError("`Type` must be either request or response");

        try self.scope_directive.isValid(Type);
    }

    /// Formats `self` as header value to `writer`
    ///
    /// - Use `CacheControl.header_name` for the header name.
    /// - This function should be used over `format`, if `Type` is known.
    pub fn formatValidate(self: CacheControl, comptime Type: HeaderType, writer: *Writer) !void {
        assert(assert_blk: {
            self.isValid(Type) catch break :assert_blk false;
            break :assert_blk true;
        });

        try self.format(writer);
    }

    /// Formats `self` as header value to `writer`
    ///
    /// - Use `CacheControl.header_name` for the header name.
    /// - Function to match std.fmt interface, if header type is known, use `formatValidate`
    pub fn format(self: CacheControl, writer: *Writer) WriterError!void {
        try self.scope_directive.format(writer);
    }

    fn _maxFormatLen() usize {
        var res: usize = 0;

        inline for (@typeInfo(ScopeDirective).@"union".fields) |field| {
            if (field.type.max_format_len > res)
                res = field.type.max_format_len;
        }

        return res;
    }

    /// Parses from `reader` into `self`
    ///
    /// `reader` must contain valid header value and only it.
    pub fn parse(self: *CacheControl, comptime Type: HeaderType, reader: *Reader) !void {
        try self.scope_directive.parse(Type, reader);

        if (reader.bufferedLen() != 0)
            return error.ExcessHeaderTail;
    }
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
        (hasFn(Type, "parse") and (@TypeOf(Type.format) == fn (*Type, *Reader) anyerror!void or (@TypeOf(Type.format) == fn (*Type, *Reader, Allocator) anyerror!void and
            hasFn(Type, "deinit") and @TypeOf(Type.deinit) == fn (*Type, Allocator) void)));
}
