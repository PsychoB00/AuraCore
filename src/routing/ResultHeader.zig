/// STD
const std = @import("std");

const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

const assert = std.debug.assert;
const comptimePrint = std.fmt.comptimePrint;

/// Aura
const core = @import("../core.zig");

const ResultType = core.routing.ResultType;
const Date = core.net.headers.Date;
const ContentLength = core.net.headers.ContentLength;
const ContentType = core.net.headers.ContentType;

const fieldPtr = core.utils.fieldPtr;
const isHttpHeader = core.net.headers.isHttpHeader;
const isResourceResult = core.routing.isResourceResult;

/// Third party
const zap = @import("zap");

const Request = zap.Request;

pub const enforcable_headers = [_]type{
    Date,
    ContentLength,
    ContentType,
};

pub const EnforcedHeadersTag = enum(u1) {
    pub const BooleanSet = struct {
        has_result_body: bool,
    };

    default = 0b0,
    result = 0b1,

    pub fn generate(comptime conditions: BooleanSet) EnforcedHeadersTag {
        return @enumFromInt(@as(u1, @intFromBool(conditions.has_result_body)));
    }

    /// Checks if `Infered` (defined by ResultHeader) fulfills `Derived` (defined by APIResource)
    ///
    /// For `Infered` to fulfill `Derived`, `Infered` must be the same as `Derived`.
    pub fn derivedFulfilled(comptime Derived: EnforcedHeadersTag, Infered: EnforcedHeadersTag) bool {
        return @intFromEnum(Derived) == @intFromEnum(Infered);
    }
};

pub fn EnforcedHeaders(comptime Tag: EnforcedHeadersTag) type {
    return switch (Tag) {
        .default => struct {
            // default = no result
            pub const tag = Tag;

            date: Date,
        },
        .result => struct {
            // result = result
            pub const tag = Tag;

            date: Date,

            content_length: ContentLength,
            content_type: ContentType,
        },
    };
}

/// Trait check for ResultHeader
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

/// Result defining what http headers are expected for response of Resource
///
/// - Fields of `Structure` represent individual result headers, they are order insensitive and
///   field names are irelevant.
/// - `Structure` can be optional.
/// - Every result header except enforced headers can be optional.
/// - Result headers must fulfill the isHttpHeader trait check
/// - Result headers must have http_header_type either response or both
/// - `Structure` mustn't have duplicate headers
/// - Validity of enforced headers for StaticRoute will be checked during generation of
///   said StaticRoute by Router
/// - If any memory needs to be allocated during parsing of `Structure`, it will be allocated with
///   arena allocator provided by zap.Request, so no deallocation is nessesary. However this binds
///   the lifetime of the memory to lifetime of the zap.Request.
pub fn ResultHeader(comptime Structure: type) type {
    const is_structure_optional = @typeInfo(Structure) == .optional;
    const structure_type =
        if (is_structure_optional)
            @typeInfo(Structure).optional.child
        else
            Structure;

    // `Structure` correctness assertion
    const structure_info = @typeInfo(structure_type);

    if (structure_info != .@"struct")
        @compileError("`Structure` must be struct");
    if (structure_info.@"struct".is_tuple)
        @compileError("`Structure` mustn't be tuple");
    if (structure_info.@"struct".fields.len < 1)
        @compileError("`Structure` must have at least one field");

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
                "Result with a type ({}) which isn't header found",
                .{field_type},
            ));

        if (!(field_type.http_header_type == .response or field_type.http_header_type == .both))
            @compileError(comptimePrint(
                "Result header with a type ({}) which can't be response header found",
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
                @compileError("Enforcable headers mustn't be optional");

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
        const ResultHeaderType = @This();
        pub const result_type: ResultType = .header;
        pub const structure = Structure;

        pub const infered_enforced_headers_t = infered_enforced_headers_type;

        data: Structure,

        pub fn format(
            self: *const ResultHeaderType,
            dest: *[structure_info.@"struct".fields.len][]u8,
            allocator: Allocator,
        ) !void {
            if (comptime is_structure_optional)
                assert(self.data != null);

            inline for (@typeInfo(structure_type).@"struct".fields, 0..) |field, index| {
                var buffer: [field.type.max_value_len]u8 = undefined;
                var writer = Writer.fixed(&buffer);

                var header_ptr =
                    fieldPtr(
                        structure_type,
                        field.name,
                        if (comptime is_structure_optional) &self.data.? else &self.data,
                    );

                try header_ptr.format(&writer);

                dest[index] = try allocator.dupe(u8, writer.buffered());
            }
        }
    };
}

/// Trait check for ResultHeader
///
/// - `Type` must fulfill the isResourceResult trait check
/// - Declaration `result_type` from ResourceResult must have value ResultType.header
/// - `Type` must be able to generate `Type` using its declarations and function ResultHeader
pub fn isResultHeader(comptime Type: type) bool {
    if (!isResourceResult(Type))
        return false;

    const is_header_result_type =
        Type.result_type == .header;

    const can_generate_self =
        is_header_result_type and
        ResultHeader(Type.structure) == Type;

    return is_header_result_type and can_generate_self;
}
