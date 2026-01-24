/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;

const Reader = std.Io.Reader;

const comptimePrint = std.fmt.comptimePrint;
const eqlIgnoreCase = std.ascii.eqlIgnoreCase;

/// Aura
const core = @import("../core.zig");

const ParametersType = core.routing.ParametersType;

const Host = core.net.headers.Host;
const UserAgent = core.net.headers.UserAgent;

const ContentLength = core.net.headers.ContentLength;
const ContentType = core.net.headers.ContentType;

const Authorization = core.net.headers.Authorization;

const Accept = core.net.headers.Accept;

const fieldPtr = core.utils.fieldPtr;
const isResourceParameters = core.routing.isResourceParameters;
const isHttpHeader = core.net.headers.isHttpHeader;

/// Third party
const zap = @import("zap");

const Request = zap.Request;

const requireable_headers = [_]type{
    Host,
    UserAgent,
    ContentLength,
    ContentType,
    Authorization,
    Accept,
};

pub const RequiredHeadersTag = enum(u3) {
    pub const BooleanSet = struct {
        has_body_parameters: bool,
        has_authorization: bool,
        has_result_body: bool,
    };

    default = 0b000,
    body = 0b001,
    auth = 0b010,
    body_auth = 0b011,
    result = 0b100,
    body_result = 0b101,
    auth_result = 0b110,
    body_auth_result = 0b111,

    pub fn generate(comptime conditions: BooleanSet) RequiredHeadersTag {
        return @enumFromInt((@as(u3, @intFromBool(conditions.has_result_body)) << 2) |
            (@as(u3, @intFromBool(conditions.has_authorization)) << 1) |
            @as(u3, @intFromBool(conditions.has_body_parameters)));
    }

    /// Checks if `Infered` (defined by HeaderParameters) fulfills `Derived` (defined by APIResource)
    ///
    /// For `Infered` to fulfill `Derived`, `Infered` must be either the same as `Derived` or `Derived`
    /// must have `has_authorization` and `has_result_body` bits set to zero and its `has_body_parameters` bit the same as `Infered`.
    pub fn derivedFulfilled(comptime Derived: RequiredHeadersTag, Infered: RequiredHeadersTag) bool {
        return @intFromEnum(Derived) == @intFromEnum(Infered) or @intFromEnum(Derived) == @intFromEnum(Infered) & 0b001;
    }
};

pub fn RequiredHeaders(comptime Tag: RequiredHeadersTag) type {
    return switch (Tag) {
        // default = no body, no auth, no result
        .default => struct {
            pub const tag = Tag;

            host: Host,
            user_agent: UserAgent,
        },
        // body = body, no auth, no result
        .body => struct {
            pub const tag = Tag;

            host: Host,
            user_agent: UserAgent,

            content_length: ContentLength,
            content_type: ContentType,
        },
        // auth = no body, auth, no result
        .auth => struct {
            pub const tag = Tag;

            host: Host,
            user_agent: UserAgent,

            authorization: Authorization,
        },
        // body_auth = body, auth, no result
        .body_auth => struct {
            pub const tag = Tag;

            host: Host,
            user_agent: UserAgent,

            content_length: ContentLength,
            content_type: ContentType,

            authorization: Authorization,
        },
        // result = no body, no auth, result
        .result => struct {
            pub const tag = Tag;

            host: Host,
            user_agent: UserAgent,

            accept: Accept,
        },
        // body_result = body, no auth, result
        .body_result => struct {
            pub const tag = Tag;

            host: Host,
            user_agent: UserAgent,

            content_length: ContentLength,
            content_type: ContentType,

            accept: Accept,
        },
        // auth = no body, auth, result
        .auth_result => struct {
            pub const tag = Tag;

            host: Host,
            user_agent: UserAgent,

            authorization: Authorization,

            accept: Accept,
        },
        // body_auth = body, auth, result
        .body_auth_result => struct {
            pub const tag = Tag;

            host: Host,
            user_agent: UserAgent,

            content_length: ContentLength,
            content_type: ContentType,

            authorization: Authorization,

            accept: Accept,
        },
    };
}

/// Trait check for HeaderParameters
///
/// - `Type` must be struct
/// - `Type` must have declaration of what tag it is, named "tag"
///     - `tag` must be deleration of RequiredHeadersTag
/// - `Type` must be able to generate `Type` using its declarations and function RequiredHeaders
pub fn isRequiredHeaders(comptime Type: type) bool {
    if (@typeInfo(Type) != .@"struct")
        return false;

    const has_tag =
        @hasDecl(Type, "tag") and
        @TypeOf(Type.tag) == RequiredHeadersTag;

    const can_generate_self =
        has_tag and
        RequiredHeaders(Type.tag) == Type;

    return has_tag and can_generate_self;
}

/// Parameters defining what http headers are expected for request of Resource
///
/// - Fields of `Structure` represent individual parameters, they are order insensitive and
///   parameter names are irelevant.
/// - Every parameter except required parameters can be optional.
/// - Parameters must fulfill the isHttpHeader trait check
/// - Parameters must have http_header_type either request or both
/// - `Structure` mustn't have duplicate headers
/// - Validity of required parameters for StaticRoute will be checked during generation of
///   said StaticRoute by Router
/// - If any memory needs to be allocated during parsing of `Structure`, it will be allocated with
///   arena allocator provided by zap.Request, so no deallocation is nessesary. However this binds
///   the lifetime of the memory to lifetime of the zap.Request.
pub fn HeaderParameters(comptime Structure: type) type {
    // `Structure` correctness assertion
    const structure_info = @typeInfo(Structure);

    if (structure_info != .@"struct")
        @compileError("`Structure` must be struct");
    if (structure_info.@"struct".is_tuple)
        @compileError("`Structure` mustn't be tuple");
    if (structure_info.@"struct".fields.len < 2)
        @compileError("`Structure` must have at least two fields");

    var found_requireable_headers = [1]bool{false} ** requireable_headers.len;
    var required_headers_count: usize = 0;

    for (structure_info.@"struct".fields, 0..) |field, field_index| {
        const field_type =
            if (@typeInfo(field.type) == .optional)
                @typeInfo(field.type).optional.child
            else
                field.type;

        if (!isHttpHeader(field_type))
            @compileError(comptimePrint(
                "Parameter with a type ({}) which isn't header found",
                .{field_type},
            ));

        if (!(field_type.http_header_type == .request or field_type.http_header_type == .both))
            @compileError(comptimePrint(
                "Parameter with a type ({}) which can't be request header found",
                .{field_type},
            ));

        // Duplicate fields validation
        if (field_index < structure_info.@"struct".fields.len - 1) {
            for (structure_info.@"struct".fields[field_index + 1 ..]) |duplicate_field| {
                const duplicate_field_type =
                    if (@typeInfo(duplicate_field.type) == .optional)
                        @typeInfo(duplicate_field.type).optional.child
                    else
                        duplicate_field.type;

                if (duplicate_field_type == field_type)
                    @compileError("`Structure` mustn't have any fields with duplicate type");
            }
        }

        // Requireable headers check
        for (requireable_headers, 0..) |requireable_header, index| requireable_headers_loop: {
            if (requireable_header != field_type)
                break :requireable_headers_loop;

            if (@typeInfo(field.type) == .optional)
                @compileError("Requireable parameters mustn't be optional");

            found_requireable_headers[index] = true;
            required_headers_count += 1;
        }
    }

    // Infering required headers type
    var required_headers_type: ?type = null;

    for (@typeInfo(RequiredHeadersTag).@"enum".fields) |tag_field| tag_loop: {
        const required_headers = RequiredHeaders(@enumFromInt(tag_field.value));
        const required_headers_info = @typeInfo(required_headers);

        if (required_headers_count != required_headers_info.@"struct".fields.len)
            break :tag_loop;

        for (required_headers_info.@"struct".fields) |field| {
            for (requireable_headers, 0..) |requireable_header, index| requireable_headers_loop: {
                if (requireable_header != field.type)
                    break :requireable_headers_loop;

                if (!found_requireable_headers[index])
                    break :tag_loop;
            }
        }

        required_headers_type = required_headers;
        break;
    }

    if (required_headers_type == null)
        @compileError("`Structure` doesn't have inferable required headers");

    const infered_required_headers_type = required_headers_type.?;

    return struct {
        const HeaderParametersType = @This();
        pub const parameters_type: ParametersType = .header;
        pub const structure = Structure;

        pub const infered_required_headers_t = infered_required_headers_type;

        data: Structure,

        pub fn parse(
            comptime Strict: bool,
            request: *const Request,
            dest: *HeaderParametersType,
            allocator: Allocator,
        ) !void {
            var headers = try request.headersToOwnedList(allocator);
            defer headers.deinit();

            var assigned_fields = [1]bool{false} ** structure_info.@"struct".fields.len;

            for (headers.items) |header| headers_loop: {
                inline for (structure_info.@"struct".fields, 0..) |field, index| fields_loop: {
                    const field_type =
                        if (@typeInfo(field.type) == .optional)
                            @typeInfo(field.type).optional.child
                        else
                            field.type;

                    if (!eqlIgnoreCase(field_type.http_header_name, header.key))
                        break :fields_loop;

                    var reader = Reader.fixed(header.value);

                    const field_ptr = fieldPtr(Structure, field.name, &dest.data);
                    if (comptime @TypeOf(field_type.parse) == fn (*field_type, *Reader) anyerror!void)
                        try field_ptr.parse(&reader)
                    else
                        try field_ptr.parse(&reader, allocator);

                    assigned_fields[index] = true;
                    break :headers_loop;
                }

                if (comptime Strict)
                    return error.ExcessHeaderTail;
            }

            inline for (structure_info.@"struct".fields, 0..) |field, index| check_loop: {
                if (assigned_fields[index])
                    break :check_loop;

                if (comptime @typeInfo(field.type) != .optional)
                    if (comptime field.type == Authorization)
                        return error.Unauthorized
                    else
                        return error.MissingValue;

                fieldPtr(HeaderParametersType, field.name, &dest.data).* = null;
            }
        }
    };
}

/// Trait check for HeaderParameters
///
/// - `Type` must fulfill the isResourceParameters trait check
/// - Declaration `parameters_type` from ResourceParameters must have value ParametersType.header
/// - `Type` must be able to generate `Type` using its declarations and function HeaderParameters
pub fn isHeaderParameters(comptime Type: type) bool {
    if (!isResourceParameters(Type))
        return false;

    const is_header_parameters_type =
        Type.parameters_type == .header;

    const can_generate_self =
        is_header_parameters_type and
        HeaderParameters(Type.structure) == Type;

    return is_header_parameters_type and can_generate_self;
}
