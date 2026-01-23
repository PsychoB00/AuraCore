/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;

const Writer = std.Io.Writer;
const WriterError = Writer.Error;
const Reader = std.Io.Reader;

const isAlphanumeric = std.ascii.isAlphanumeric;
const isWhitespace = std.ascii.isWhitespace;
const isPrint = std.ascii.isPrint;
const isAscii = std.ascii.isAscii;
const percentEncode = std.Uri.Component.percentEncode;
const utf8ValidateSlice = std.unicode.utf8ValidateSlice;
const eqlIgnoreCase = std.ascii.eqlIgnoreCase;

/// Aura
const core = @import("../../core.zig");

const HttpHeaderType = core.net.headers.HttpHeaderType;
const Realm = core.routing.Realm;
const Requirement = core.routing.Requirement;
const AuthorizationPolicy = core.routing.AuthorizationPolicy;
const AuthScheme = core.net.headers.AuthScheme;
const uri = core.net.uri;

const assertValidate = core.utils.assertValidate;
const validateRealm = Realm.validate;
const validateRequirements = AuthorizationPolicy.validateRequirements;
const validateRequirement = Requirement.validate;
const formatRealm = Realm.format;
const parseRealm = Realm.parse;
const decodeUriStringtoUTF8 = uri.decodeUriStringtoUTF8;

pub const WWWAuthenticate = struct {
    pub const Challenge = union(AuthScheme) {
        pub const Basic = struct {
            pub const max_value_len: usize = 25 + Realm.max_realm_len;

            realm: []const u8,
            charset: bool,

            pub fn validate(self: Basic) !void {
                try validateRealm(self.realm);
            }

            pub fn format(self: Basic, writer: *Writer) WriterError!void {
                assertValidate(self.validate());

                try writer.writeAll("realm=\"");
                try formatRealm(self.realm, writer);
                try writer.writeByte('"');

                if (self.charset)
                    try writer.writeAll(", charset=\"utf-8\"");
            }

            pub fn parse(self: *Basic, reader: *Reader, allocator: Allocator) anyerror!void {
                self.charset = false;

                var has_realm = false;
                var has_charset = false;

                for (0..2) |_| {
                    const parameter_name_value = try reader.peekDelimiterInclusive('=');

                    if (eqlIgnoreCase(parameter_name_value, "realm=")) {
                        // Realm
                        if (has_realm)
                            return error.DuplicateRealm;

                        reader.toss(parameter_name_value.len);

                        try parseRealm(&self.realm, reader, allocator);

                        has_realm = true;
                    } else if (eqlIgnoreCase(parameter_name_value, "charset=")) {
                        // Charset
                        if (has_charset)
                            return error.DuplicateCharset;

                        reader.toss(parameter_name_value.len);

                        if (reader.bufferedLen() < 7)
                            return error.MissingCharset;

                        const charset_value = try reader.take(7);

                        if (!eqlIgnoreCase(charset_value, "\"utf-8\""))
                            return error.InvalidCharset;

                        self.charset = true;

                        has_charset = true;
                    } else break;

                    if (reader.bufferedLen() == 0)
                        break;

                    const comma_value = try reader.takeByte();

                    if (comma_value != ',')
                        return error.MissingComma;

                    const whitespace_value = try reader.peekByte();

                    if (isWhitespace(whitespace_value))
                        reader.toss(1);

                    const buffer_till_space = try reader.peekDelimiterExclusive(' ');
                    const buffer_till_equal = try reader.peekDelimiterExclusive('=');

                    if (buffer_till_space.len < buffer_till_equal.len)
                        break;
                }

                if (!has_realm)
                    return error.MissingRealm;
            }
        };

        pub const Bearer = struct {
            const max_err_len: usize = 32;
            const max_error_description_len: usize = 128;
            const max_error_uri_len: usize = 253;

            pub const max_value_len: usize =
                60 + Realm.max_realm_len + max_err_len + max_error_description_len + max_error_uri_len +
                (AuthorizationPolicy.requirements_capacity * (Requirement.max_requirement_len + 1));

            realm: []const u8,
            scope: ?[]const []const u8 = null,
            err: ?[]const u8 = null,
            error_description: ?[]const u8 = null,
            error_uri: ?[]const u8 = null,

            fn _validateErr(err: []const u8) !void {
                if (err.len == 0)
                    return error.ErrorTooShort;
                if (err.len > max_err_len)
                    return error.ErrorTooLong;

                for (err) |character| {
                    if (!(isAlphanumeric(character) or character == '_'))
                        return error.InvalidCharacter;
                }
            }

            fn _validateErrorDescription(error_description: []const u8) !void {
                if (error_description.len == 0)
                    return error.ErrorDescriptionTooShort;
                if (error_description.len > max_error_description_len)
                    return error.ErrorDescriptionTooLong;

                for (error_description) |character| {
                    if (!(isPrint(character) and character != '\\' and character != '"'))
                        return error.InvalidCharacter;
                }
            }

            fn _validateErrorUri(error_uri: []const u8) !void {
                if (error_uri.len == 0)
                    return error.ErrorUriTooShort;
                if (error_uri.len >= max_error_uri_len)
                    return error.ErrorUriTooLong;
                if (!utf8ValidateSlice(error_uri))
                    return error.InvalidEncoding;

                for (error_uri) |character| character_loop: {
                    if (!isAscii(character) or isAlphanumeric(character))
                        continue;

                    inline for (uri.allowed_uri_characters) |allowed_character| {
                        if (character == allowed_character)
                            break :character_loop;
                    }

                    return error.InvalidCharacter;
                }
            }

            pub fn validate(self: Bearer) !void {
                try validateRealm(self.realm);

                if (self.scope) |scope|
                    try validateRequirements(scope);
                if (self.err) |err|
                    try _validateErr(err);
                if (self.error_description) |error_description| {
                    if (self.err == null)
                        return error.MissingError;

                    try _validateErrorDescription(error_description);
                }
                if (self.error_uri) |error_uri| {
                    if (self.err == null)
                        return error.MissingError;

                    try _validateErrorUri(error_uri);
                }
            }

            pub fn format(self: Bearer, writer: *Writer) WriterError!void {
                assertValidate(self.validate());

                try writer.writeAll("realm=\"");
                try formatRealm(self.realm, writer);
                try writer.writeByte('"');

                if (self.scope) |scope| {
                    try writer.writeAll(", scope=\"");

                    for (scope) |requirement| {
                        try writer.print("{s} ", .{requirement});
                    }
                    writer.undo(1);

                    try writer.writeByte('"');
                }
                if (self.err) |err|
                    try writer.print(", error=\"{s}\"", .{err});
                if (self.error_description) |error_description|
                    try writer.print(", error_description=\"{s}\"", .{error_description});
                if (self.error_uri) |error_uri| {
                    try writer.writeAll(", error_uri=\"");
                    try percentEncode(writer, error_uri, isAscii);
                    try writer.writeByte('"');
                }
            }

            pub fn parse(self: *Bearer, reader: *Reader, allocator: Allocator) anyerror!void {
                self.scope = null;
                self.err = null;
                self.error_description = null;
                self.error_uri = null;

                var has_realm = false;
                var has_scope = false;
                var has_error = false;
                var has_error_description = false;
                var has_error_uri = false;

                for (0..5) |_| {
                    const parameter_name_value = try reader.peekDelimiterInclusive('=');

                    if (eqlIgnoreCase(parameter_name_value, "realm=")) {
                        // Realm
                        if (has_realm)
                            return error.DuplicateRealm;

                        reader.toss(parameter_name_value.len);

                        try parseRealm(&self.realm, reader, allocator);

                        has_realm = true;
                    } else if (eqlIgnoreCase(parameter_name_value, "scope=")) {
                        // Scope
                        if (has_scope)
                            return error.DuplicateScope;

                        reader.toss(parameter_name_value.len);

                        if (reader.bufferedLen() < 3)
                            return error.MissingScope;

                        const opening_quote_value = try reader.takeByte();

                        if (opening_quote_value != '"')
                            return error.UnopenedQuotes;

                        const scope_value = try reader.takeDelimiterInclusive('"');
                        var scope_reader = Reader.fixed(scope_value[0 .. scope_value.len - 1]);

                        var scope: [AuthorizationPolicy.requirements_capacity][]const u8 = undefined;
                        var index: usize = 0;

                        while (index < AuthorizationPolicy.requirements_capacity) {
                            const requirement_value = try scope_reader.takeDelimiterExclusive(' ');

                            try validateRequirement(requirement_value);

                            scope[index] = try allocator.dupe(u8, requirement_value);
                            index += 1;

                            if (scope_reader.bufferedLen() == 0)
                                break;

                            scope_reader.toss(1);
                        }

                        if (index == 0)
                            return error.TooFewRequirements;
                        if (scope_reader.bufferedLen() != 0)
                            return error.TooManyRequirements;

                        self.scope = try allocator.dupe([]const u8, scope[0..index]);

                        has_scope = true;
                    } else if (eqlIgnoreCase(parameter_name_value, "error=")) {
                        // Error
                        if (has_error)
                            return error.DuplicateError;

                        reader.toss(parameter_name_value.len);

                        if (reader.bufferedLen() < 3)
                            return error.MissingError;

                        const opening_quote_value = try reader.takeByte();

                        if (opening_quote_value != '"')
                            return error.UnopenedQuotes;

                        const error_value = try reader.takeDelimiterInclusive('"');

                        try _validateErr(error_value[0 .. error_value.len - 1]);

                        self.err = try allocator.dupe(u8, error_value[0 .. error_value.len - 1]);

                        has_error = true;
                    } else if (eqlIgnoreCase(parameter_name_value, "error_description=")) {
                        // Error description
                        if (has_error_description)
                            return error.DuplicateErrorDescription;

                        reader.toss(parameter_name_value.len);

                        if (reader.bufferedLen() < 3)
                            return error.MissingErrorDescription;

                        const opening_quotes_value = try reader.takeByte();

                        if (opening_quotes_value != '"')
                            return error.UnopenedQuotes;

                        const error_description_value = try reader.takeDelimiterInclusive('"');

                        try _validateErrorDescription(error_description_value[0 .. error_description_value.len - 1]);

                        self.error_description = try allocator.dupe(u8, error_description_value[0 .. error_description_value.len - 1]);

                        has_error_description = true;
                    } else if (eqlIgnoreCase(parameter_name_value, "error_uri=")) {
                        // Error uri
                        if (has_error_uri)
                            return error.DuplicateErrorUri;

                        reader.toss(parameter_name_value.len);

                        if (reader.bufferedLen() < 3)
                            return error.MissingErrorDescription;

                        const opening_quotes_value = try reader.takeByte();

                        if (opening_quotes_value != '"')
                            return error.UnopenedQuotes;

                        const error_uri_value = try reader.takeDelimiterInclusive('"');

                        self.error_uri = try decodeUriStringtoUTF8(uri.allowed_uri_characters, error_uri_value[0 .. error_uri_value.len - 1], allocator);

                        has_error_uri = true;
                    } else break;

                    if (reader.bufferedLen() == 0)
                        break;

                    const comma_value = try reader.takeByte();

                    if (comma_value != ',')
                        return error.MissingComma;

                    const whitespace_value = try reader.peekByte();

                    if (isWhitespace(whitespace_value))
                        reader.toss(1);

                    const buffer_till_space = try reader.peekDelimiterExclusive(' ');
                    const buffer_till_equal = try reader.peekDelimiterExclusive('=');

                    if (buffer_till_space.len < buffer_till_equal.len)
                        break;
                }

                if (!has_realm)
                    return error.MissingRealm;
                if ((has_error_description or has_error_uri) and !has_error)
                    return error.MissingError;
            }
        };

        pub const max_value_len: usize = 7 + Bearer.max_value_len;

        basic: Basic,
        bearer: Bearer,

        pub fn validate(self: Challenge) !void {
            switch (self) {
                .basic => |basic| try basic.validate(),
                .bearer => |bearer| try bearer.validate(),
            }
        }

        pub fn format(self: Challenge, writer: *Writer) WriterError!void {
            switch (self) {
                .basic => |basic| try writer.print("basic {f}", .{basic}),
                .bearer => |bearer| try writer.print("bearer {f}", .{bearer}),
            }
        }

        pub fn parse(self: *Challenge, reader: *Reader, allocator: Allocator) anyerror!void {
            const scheme_value = try reader.takeDelimiterInclusive(' ');

            if (eqlIgnoreCase(scheme_value, "basic ")) {
                self.* = @unionInit(Challenge, "basic", undefined);
                try self.basic.parse(reader, allocator);
            } else if (eqlIgnoreCase(scheme_value, "bearer ")) {
                self.* = @unionInit(Challenge, "bearer", undefined);
                try self.bearer.parse(reader, allocator);
            } else return error.InvalidScheme;
        }
    };

    pub const challenges_capacity: usize = 4;

    pub const http_header_name: []const u8 = "www-authenticate";
    pub const http_header_type: HttpHeaderType = .response;
    pub const max_value_len: usize = challenges_capacity * (Challenge.max_value_len + 2);

    challenges: []const Challenge,

    fn _validateChallenges(challenges: []const Challenge) !void {
        if (challenges.len == 0)
            return error.TooFewChallenges;
        if (challenges.len > challenges_capacity)
            return error.TooManyChallenges;

        for (challenges) |challenge| {
            try challenge.validate();
        }
    }

    pub fn validate(self: WWWAuthenticate) !void {
        try _validateChallenges(self.challenges);
    }

    /// Formats the header value to `writer`
    pub fn format(self: WWWAuthenticate, writer: *Writer) WriterError!void {
        assertValidate(_validateChallenges(self.challenges));

        for (self.challenges) |challenge| {
            try writer.print("{f}, ", .{challenge});
        }

        writer.undo(2);
    }

    /// Parses the header value from `reader`
    ///
    /// `allocator` MUST BE arena allocator, this parse is leaky
    pub fn parse(self: *WWWAuthenticate, reader: *Reader, allocator: Allocator) anyerror!void {
        var challenges: [challenges_capacity]Challenge = undefined;
        var index: usize = 0;

        while (index < max_value_len) {
            try challenges[index].parse(reader, allocator);

            index += 1;

            if (reader.bufferedLen() == 0)
                // `reader` is empty
                break;
            if (reader.bufferedLen() < 7)
                // `reader` doesn't have minimal nessesary bytes for Challenge
                return error.ExcessHeaderTail;
        }

        // Products validation reduced from `_validateChallenges` to avoid duplicate checks
        if (challenges.len == 0)
            return error.TooFewChallenges;
        if (challenges.len > challenges_capacity)
            return error.TooManyChallenges;

        self.challenges = try allocator.dupe(Challenge, challenges[0..index]);
    }
};
