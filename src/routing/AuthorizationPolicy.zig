/// STD
const std = @import("std");

const Writer = std.Io.Writer;
const WriterError = Writer.Error;
const Reader = std.Io.Reader;

const Allocator = std.mem.Allocator;

const eql = std.mem.eql;
const isPrint = std.ascii.isPrint;
const isAlphanumeric = std.ascii.isAlphanumeric;

/// Aura
const core = @import("../core.zig");

const assertValidate = core.utils.assertValidate;

pub const Realm = struct {
    pub const max_realm_len: usize = 64;

    pub fn validate(realm: []const u8) anyerror!void {
        if (realm.len == 0)
            return error.RealmTooShort;
        if (realm.len > max_realm_len)
            return error.RealmTooLong;

        var quotes_count: usize = 0;
        for (realm) |character| {
            if (!isPrint(character))
                return error.InvalidCharacter;

            if (character == '"')
                quotes_count += 1;
        }

        if (quotes_count % 2 != 0)
            return error.UnclosedQuotes;
    }

    pub fn format(realm: []const u8, writer: *Writer) WriterError!void {
        assertValidate(validate(realm));

        var escaped = false;
        for (realm) |character| {
            if (!escaped and character == '\\') {
                escaped = true;
                continue;
            }

            if (escaped)
                escaped = false;

            try writer.writeByte(character);
        }
    }

    pub fn parse(realm: *[]const u8, reader: *Reader, allocator: Allocator) anyerror!void {
        if (reader.bufferedLen() == 0)
            return error.UnopenedQuotes;

        const opening_quote_value = try reader.takeByte();

        if (opening_quote_value != '"')
            return error.UnopenedQuotes;

        var buffer: [max_realm_len]u8 = undefined;
        var buffered_len: usize = 0;

        if (reader.bufferedLen() == 0)
            return error.MissingRealm;

        for (0..max_realm_len) |_| {
            const buffer_till_quote = try reader.peekDelimiterExclusive('"');
            const buffer_till_backslash = try reader.peekDelimiterExclusive('\\');

            var realm_value: []const u8 = undefined;

            if (buffer_till_quote.len < buffer_till_backslash.len + 1) {
                reader.toss(buffer_till_quote.len);

                if (buffer_till_quote[buffer_till_quote.len - 1] == '\\')
                    realm_value = buffer_till_quote[0 .. buffer_till_quote.len - 1]
                else
                    realm_value = buffer_till_quote;
            } else {
                reader.toss(buffer_till_backslash.len);

                if (reader.bufferedLen() < 3)
                    return error.UnclosedQuotes;

                reader.toss(1);

                const double_backslash_value = try reader.peek(2);

                if (!eql(u8, double_backslash_value, "\\\\"))
                    return error.UnescapedBackslash;

                realm_value = buffer_till_backslash;
            }

            if (realm_value.len + buffered_len > max_realm_len)
                return error.RealmTooLong;

            @memmove((&buffer)[buffered_len..realm_value.len], realm_value);
            buffered_len += buffer_till_quote.len;

            if (reader.bufferedLen() == 0)
                return error.UnclosedQuotes;

            reader.toss(1);

            if (buffer_till_quote[buffer_till_quote.len - 1] != '\\')
                break;
        }

        try validate(buffer[0..buffered_len]);

        realm.* = try allocator.dupe(u8, buffer[0..buffered_len]);
    }
};

pub const Requirement = struct {
    pub const max_requirement_len: usize = 128;

    fn _validateRequirementChar(character: u8) !void {
        const allowed_characters = "-_.:";

        if (isAlphanumeric(character))
            return;

        inline for (allowed_characters) |allowed_character| {
            if (allowed_character == character)
                return;
        }

        return error.InvalidCharacter;
    }

    pub fn validate(requirement: []const u8) !void {
        if (requirement.len == 0)
            return error.RequirementTooShort;
        if (requirement.len > max_requirement_len)
            return error.RequirementTooLong;

        for (requirement) |character| {
            try _validateRequirementChar(character);
        }
    }
};

pub const AuthorizationPolicy = struct {
    pub const requirements_capacity: usize = 32;

    realm: []const u8,
    requirements: []const []const u8,

    pub fn validateRequirements(requirements: []const []const u8) !void {
        if (requirements.len == 0)
            return error.TooFewRequirements;
        if (requirements.len > requirements_capacity)
            return error.TooManyRequirements;

        for (requirements, 0..) |requirement, index| {
            try Requirement.validate(requirement);

            for (requirements[(index + 1)..]) |check_requirement| {
                if (eql(u8, requirement, check_requirement))
                    return error.DuplicateRequirements;
            }
        }
    }

    pub fn validate(self: AuthorizationPolicy) !void {
        try Realm.validate(self.realm);

        try validateRequirements(self.requirements);
    }
};
