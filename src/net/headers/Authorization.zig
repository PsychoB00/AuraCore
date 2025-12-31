/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;

const Writer = std.Io.Writer;
const WriterError = Writer.Error;
const Reader = std.Io.Reader;

const Base64Encoder = std.base64.standard.Encoder;
const Base64Decoder = std.base64.standard.Decoder;

const eqlIgnoreCase = std.ascii.eqlIgnoreCase;
const utf8ValidateSlice = std.unicode.utf8ValidateSlice;
const isControl = std.ascii.isControl;

/// Aura
const core = @import("../../core.zig");

const HttpHeaderType = core.net.headers.HttpHeaderType;

const assertValidate = core.utils.assertValidate;

pub const Authorization = struct {
    const SchemeTag = enum {
        basic,
        bearer,
    };

    pub const Scheme = union(SchemeTag) {
        pub const Basic = struct {
            const max_username_len: usize = 255;
            const max_password_len: usize = 128;

            pub const max_value_len: usize = Base64Encoder.calcSize(max_username_len + max_password_len + 1);

            username: ?[]const u8,
            password: ?[]const u8,

            pub fn validate(self: Basic) anyerror!void {
                if (self.username) |username|
                    try _validateUsername(username);
                if (self.password) |password|
                    try _validatePassword(password);
            }

            fn _validateUsername(username: []const u8) anyerror!void {
                if (username.len == 0)
                    return error.UsernameTooShort;
                if (username.len > max_username_len)
                    return error.UsernameTooLong;

                if (!utf8ValidateSlice(username))
                    return error.InvalidEncoding;

                for (username) |character| {
                    if (isControl(character) or character == ':')
                        return error.InvalidCharacter;
                }
            }

            fn _validatePassword(password: []const u8) anyerror!void {
                if (password.len == 0)
                    return error.PasswordTooShort;
                if (password.len > max_password_len)
                    return error.PasswordTooLong;

                if (!utf8ValidateSlice(password))
                    return error.InvalidEncoding;

                for (password) |character| {
                    if (isControl(character) or character == ':')
                        return error.InvalidCharacter;
                }
            }

            pub fn format(self: Basic, writer: *Writer) WriterError!void {
                assertValidate(self.validate());

                var unencoded: [@This().max_value_len]u8 = undefined;
                var unencoded_writer = Writer.fixed(&unencoded);

                if (self.username) |username|
                    try unencoded_writer.writeAll(username);

                try unencoded_writer.writeByte(':');

                if (self.password) |password|
                    try unencoded_writer.writeAll(password);

                try Base64Encoder.encodeWriter(writer, unencoded_writer.buffered());
            }

            pub fn parse(self: *Basic, reader: *Reader, allocator: Allocator) anyerror!void {
                var buffer: [@This().max_value_len]u8 = undefined;
                const decoded_len: usize = try Base64Decoder.calcSizeForSlice(reader.buffered());
                try Base64Decoder.decode(&buffer, reader.buffered());
                var decoded_reader = Reader.fixed(buffer[0..decoded_len]);

                const username_value = try decoded_reader.takeDelimiterInclusive(':');

                self.username =
                    username_blk: {
                        if (username_value.len > 1) {
                            try _validateUsername(username_value[0 .. username_value.len - 1]);

                            break :username_blk try allocator.dupe(u8, username_value[0 .. username_value.len - 1]);
                        } else break :username_blk null;
                    };

                const password_value = try decoded_reader.take(decoded_reader.bufferedLen());

                self.password =
                    password_blk: {
                        if (password_value.len > 0) {
                            try _validatePassword(password_value);

                            break :password_blk try allocator.dupe(u8, password_value);
                        } else break :password_blk null;
                    };
            }
        };

        const max_bearer_len: usize = 2048;

        pub const max_value_len: usize = @max(Basic.max_value_len, max_bearer_len);

        basic: Basic,
        bearer: []const u8,

        fn _validateBearer(bearer: []const u8) !void {
            if (bearer.len == 0)
                return error.BearerTooShort;
            if (bearer.len > max_bearer_len)
                return error.BearerTooLong;
        }

        pub fn validate(self: Scheme) anyerror!void {
            switch (self) {
                .basic => |basic| try basic.validate(),
                .bearer => |bearer| try _validateBearer(bearer),
            }
        }

        pub fn format(self: Scheme, writer: *Writer) WriterError!void {
            switch (self) {
                .basic => |basic| try writer.print("basic {f}", .{basic}),
                .bearer => |bearer| try writer.print("bearer {s}", .{bearer}),
            }
        }

        pub fn parse(self: *Scheme, reader: *Reader, allocator: Allocator) anyerror!void {
            const scheme_value = reader.takeDelimiterInclusive(' ') catch |err| switch (err) {
                error.EndOfStream => return error.InvalidSchemeCredentialsDelimiter,
                else => return err,
            };

            if (eqlIgnoreCase(scheme_value, "basic ")) {
                self.* = @unionInit(Scheme, "basic", undefined);

                try self.basic.parse(reader, allocator);
            } else if (eqlIgnoreCase(scheme_value, "bearer ")) {
                const credentials_value = try reader.take(reader.bufferedLen());

                try _validateBearer(credentials_value);

                self.* = .{ .bearer = try allocator.dupe(u8, credentials_value) };
            } else return error.InvalidScheme;
        }
    };

    pub const http_header_name: []const u8 = "authorization";
    pub const http_header_type: HttpHeaderType = .request;
    pub const max_value_len: usize = Scheme.max_value_len;

    scheme: Scheme,

    pub fn validate(self: Authorization) anyerror!void {
        try self.scheme.validate();
    }

    /// Formats the header value to `writer`
    pub fn format(self: Authorization, writer: *Writer) WriterError!void {
        try self.scheme.format(writer);
    }

    /// Parses the header value from `reader`
    ///
    /// `allocator` MUST BE arena allocator, this parse is leaky
    pub fn parse(self: *Authorization, reader: *Reader, allocator: Allocator) anyerror!void {
        try self.scheme.parse(reader, allocator);
    }
};
