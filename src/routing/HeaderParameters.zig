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

const fieldPtr = core.utils.fieldPtr;
const isResourceParameters = core.routing.isResourceParameters;
const isHttpHeader = core.net.headers.isHttpHeader;

/// Third party
const zap = @import("zap");

const Request = zap.Request;

const enforcable_headers = [_]type{
    Host,
    UserAgent,
    ContentLength,
    ContentType,
};

pub const EnforcedHeadersTag = enum(u2) {
    default,
    body,
    auth,
    body_auth,

    pub fn generate(comptime HasAuthentication: bool, comptime HasBodyParameters: bool) EnforcedHeadersTag {
        return @enumFromInt((@as(u2, @intFromBool(HasAuthentication)) << 1) | @as(u2, @intFromBool(HasBodyParameters)));
    }
};

pub fn EnforcedHeaders(comptime Tag: EnforcedHeadersTag) type {
    return switch (Tag) {
        // default = no body, no auth
        .default => struct {
            pub const tag = Tag;

            host: Host,
            user_agent: UserAgent,
        },
        // body = body, no auth
        .body => struct {
            pub const tag = Tag;

            host: Host,
            user_agent: UserAgent,

            content_length: ContentLength,
            content_type: ContentType,
        },
        // auth = no body, auth
        .auth => struct {
            pub const tag = Tag;

            host: Host,
            user_agent: UserAgent,
        },
        // body_auth = body, auth
        .body_auth => struct {
            pub const tag = Tag;

            host: Host,
            user_agent: UserAgent,

            content_length: ContentLength,
            content_type: ContentType,
        },
    };
}

/// Trait check for HeaderParameters
///
/// - `Type` must be struct
/// - `Type` must have declaration of what tag it is, named "tag"
///     - `tag` must be deleration of EnforcedHeadersTag
/// - `Type` must be able to generate `Type` using its declarations and function EnforcedHeaders
pub fn isEnforcedHeaders(comptime Type: type) bool {
    if (@typeInfo(Type) != .@"struct")
        return false;

    const has_tag =
        @hasDecl(Type, "tag") and
        @TypeOf(Type.tag) == EnforcedHeadersTag;

    const can_generate_self =
        has_tag and
        EnforcedHeaders(Type.tag) == Type;

    return has_tag and can_generate_self;
}

/// Parameters defining what http headers are expected for Resource
///
/// - Fields of `Structure` represent individual parameters, they are order insensitive and
///   parameter names are irelevant.
/// - Every parameter except enforced parameters can be optional.
/// - Parameters must fulfill the isHttpHeader trait check
/// - Parameters mustn't have duplicate headers
/// - Validity of enforced parameters for StaticRoute will be checked during generation of
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

    var found_enforcable_headers = [1]bool{false} ** enforcable_headers.len;
    var enforced_headers_count: usize = 0;

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

        // Enforcable headers check
        for (enforcable_headers, 0..) |enforcable_header, index| enforcable_headers_loop: {
            if (enforcable_header != field_type)
                break :enforcable_headers_loop;

            if (@typeInfo(field.type) == .optional)
                @compileError("Enforcable parameters mustn't be optional");

            found_enforcable_headers[index] = true;
            enforced_headers_count += 1;
        }
    }

    // Infering enforced headers type
    var enforced_headers_type: ?type = null;

    for (@typeInfo(EnforcedHeadersTag).@"enum".fields) |tag_field| tag_loop: {
        const enforced_headers = EnforcedHeaders(@enumFromInt(tag_field.value));
        const enforced_headers_info = @typeInfo(enforced_headers);

        if (enforced_headers_count != enforced_headers_info.@"struct".fields.len)
            break :tag_loop;

        for (enforced_headers_info.@"struct".fields) |field| {
            for (enforcable_headers, 0..) |enforcable_header, index| enforcable_headers_loop: {
                if (enforcable_header != field.type)
                    break :enforcable_headers_loop;

                if (!found_enforcable_headers[index])
                    break :tag_loop;
            }
        }

        enforced_headers_type = enforced_headers;
        break;
    }

    if (enforced_headers_type == null)
        @compileError("`Structure` doesn't have inferable enforced headers");

    const infered_enforced_headers_type = enforced_headers_type.?;

    return struct {
        const HeaderParametersType = @This();
        pub const parameters_type: ParametersType = .header;
        pub const structure = Structure;

        pub const infered_enforced_headers_t = infered_enforced_headers_type;

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

                if (@typeInfo(field.type) != .optional)
                    return error.MissingValue;

                fieldPtr(HeaderParametersType, field.name, &dest.data).* = null;
            }
        }
    };
}

/// Trait check for HeaderParameters
///
/// - `Type` must fullfil the isResourceParameters trait check
/// - Declaration `parameters_type` from ResourceParameters must have value ParametersType.header
/// - `Type` must have declaration of infered enforced headers type, named "infered_enforced_headers_t"
///     - `infered_enforced_headers_t` must fulfill the trait check isEnforcedHeaders
/// - `Type` must be able to generate `Type` using its declarations and function HeaderParameters
pub fn isHeaderParameters(comptime Type: type) bool {
    if (!isResourceParameters(Type))
        return false;

    const is_header_parameters_type =
        Type.parameters_type == .header;

    const has_infered_enforced_headers =
        @hasDecl(Type, "infered_enforced_headers_t") and
        isEnforcedHeaders(Type.infered_enforced_headers_t);

    const can_generate_self =
        is_header_parameters_type and
        HeaderParameters(Type.structure) == Type;

    return is_header_parameters_type and has_infered_enforced_headers and can_generate_self;
}
