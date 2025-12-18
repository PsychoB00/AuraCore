/// Aura
pub const Host = @import("Host.zig").Host;

pub const HttpHeaderType = enum {
    request,
    response,
    both,
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
pub fn isHttpHeader(comptime Type: type) bool {
    const is_struct = @typeInfo(Type) == .@"struct";

    const has_http_header_name =
        @hasDecl(Type, "http_header_name") and
        @TypeOf(Type.http_header_name) == []const u8;

    const has_http_header_type =
        @hasDecl(Type, "http_header_type") and
        @TypeOf(Type.http_header_type) == HttpHeaderType;

    const has_max_value_len =
        @hasDecl(Type, "max_value_len") and
        @TypeOf(Type.max_value_len) == HttpHeaderType;

    return is_struct and has_http_header_name and has_http_header_type and has_max_value_len;
}
