/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;

const Writer = std.Io.Writer;
const WriterError = Writer.Error;
const Reader = std.Io.Reader;

const isAlphanumeric = std.ascii.isAlphanumeric;
const hasMethod = std.meta.hasMethod;

/// Aura
pub const Host = @import("Host.zig").Host;
pub const UserAgent = @import("UserAgent.zig").UserAgent;

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
