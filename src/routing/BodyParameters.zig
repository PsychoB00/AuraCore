/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;

const comptimePrint = std.fmt.comptimePrint;
const utf8ValidateSlice = std.unicode.utf8ValidateSlice;
const isAscii = std.ascii.isAscii;

/// Aura
const core = @import("../core.zig");

const ParametersType = core.routing.ParametersType;
const MediaType = core.net.headers.MediaType;

const ContentLength = core.net.headers.ContentLength;
const ContentType = core.net.headers.ContentType;

const isResourceParameters = core.routing.isResourceParameters;

const asAny = core.json.asAny;

/// Third Party
const zap = @import("zap");
const Request = zap.Request;

const zimdjson = @import("zimdjson");
const JsonParser = zimdjson.ondemand.FullParser(.default);

/// Parameters for larger and more complex data
///
/// - `Structure` is a type representing content of the body, can be optional type.
/// - `AllowedMediaTypes` is either single MediaType or array of MediaTypes which specify which
///   MediaTypes are allowed to be parsed.
/// - `AllowedMediaTypes` can have wildcards
/// - MediaTypes in `AllowedMediaTypes` mustn't overlap with other allowed MediaTypes
/// - `Structure` must be valid parsing type for every MediaType in `AllowedMediaTypes
/// - If any memory needs to be allocated during parsing of `Structure`, it will be allocated with
///   arena allocator provided by zap.Request, so no deallocation is nessesary. However this binds
///   the lifetime of the memory to lifetime of the zap.Request.
pub fn BodyParameters(comptime Structure: type, comptime AllowedMediaTypes: anytype) type {
    // `Structure` correctness assertion
    const Gen = struct {
        fn _allowedMediaTypesArrayType() type {
            const info = @typeInfo(@TypeOf(AllowedMediaTypes));

            if (info == .array) {
                if (info.array.len == 0)
                    @compileError("`AllowedMediaTypes` must have at least one element or be MediaType");

                return @TypeOf(AllowedMediaTypes);
            } else if (@TypeOf(AllowedMediaTypes) == MediaType)
                return [1]MediaType
            else
                @compileError("`AllowedMediaTypes` must be typed either MediaType or [_]MediaType");
        }

        fn _allowedMediaTypesArray() _allowedMediaTypesArrayType() {
            if (@TypeOf(AllowedMediaTypes) == MediaType)
                return [1]MediaType{AllowedMediaTypes}
            else
                return AllowedMediaTypes;
        }
    };

    const allowed_media_types_array = Gen._allowedMediaTypesArray();
    const structure_type =
        if (@typeInfo(Structure) == .optional)
            @typeInfo(Structure).optional.child
        else
            Structure;

    for (allowed_media_types_array, 0..) |media_type, index| allowed_media_types_loop: {
        comptime MediaType.validateType(media_type, structure_type) catch |err| {
            @compileError(comptimePrint(
                "`Structure` is invalid parsing type, cause {s}",
                .{@errorName(err)},
            ));
        };

        if (index >= allowed_media_types_array.len - 1)
            break :allowed_media_types_loop;

        for (allowed_media_types_array[index + 1 ..]) |check_media_type| {
            if (MediaType.areOverlapping(media_type, check_media_type))
                @compileError("Overlapping MediaType found in `AllowedMediaTypes`");
        }
    }

    return struct {
        const BodyParametersType = @This();
        pub const parameters_type: ParametersType = .body;
        pub const structure = Structure;
        pub const allowed_media_types = AllowedMediaTypes;

        data: Structure,

        /// Parse BodyParameters from `request` and validate
        pub fn parse(
            request: *const Request,
            dest: *BodyParametersType,
            content_length: *const ContentLength,
            content_type: *const ContentType,
            allocator: Allocator,
        ) !void {
            // EnforcedHeaders validation
            if ((request.body orelse "").len != content_length.length)
                return error.InvalidContentLength;

            var allowed_media_type: ?*const MediaType = null;
            inline for (allowed_media_types_array) |media_type| media_type_loop: {
                if (!MediaType.areOverlapping(content_type.media_type, media_type))
                    break :media_type_loop;

                allowed_media_type = &media_type;
            }

            if (allowed_media_type == null)
                return error.InvalidContentType;

            // Empty body
            if (request.body == null)
                if (comptime @typeInfo(Structure) == .optional) {
                    dest.data = null;
                    return;
                } else return error.MissingBody;

            switch (content_type.media_type) {
                .application => |application| {
                    switch (application) {
                        .json => {
                            // JSON
                            (comptime @TypeOf(application).validateType(@TypeOf(application){ .json = {} }, structure_type)) catch
                                return error.RuntimeUnreachable;

                            if (!utf8ValidateSlice(request.body.?))
                                return error.InvalidEncoding;

                            var parser = JsonParser.init;
                            defer parser.deinit(allocator);

                            const document = try parser.parseFromSlice(allocator, request.body.?);
                            const value = try document.asAny();
                            dest.data = try asAny(JsonParser, structure_type, &value, allocator);
                        },
                        .wildcard => unreachable,
                    }
                },
                .text => |text| {
                    switch (text) {
                        .plain => |plain| {
                            // Plain text
                            (comptime @TypeOf(text).validateType(@TypeOf(text){ .plain = null }, structure_type)) catch
                                return error.RuntimeUnreachable;

                            const charset =
                                if (plain != null)
                                    plain.?
                                else
                                    allowed_media_type.?.text.plain.?;

                            switch (charset) {
                                .utf_8 => {
                                    if (!utf8ValidateSlice(request.body.?))
                                        return error.InvalidEncoding;
                                },
                                .us_ascii => {
                                    for (request.body.?) |character| {
                                        if (!isAscii(character))
                                            return error.InvalidEncoding;
                                    }
                                },
                            }

                            dest.data = try allocator.dupe(u8, request.body.?);
                        },
                        .html, .wildcard => unreachable,
                    }
                },
                .wildcard => unreachable,
            }
        }
    };
}

/// Trait check for BodyParameters
///
/// - `Type` must fullfil the isResourceParameters trait check
/// - Declaration `parameters_type` from ResourceParameters must have value ParametersType.body
/// - `Type` must have decleration of allowed media types, named "allowed_media_types"
///     - `allowed_media_types` must be declaretion of either MediaType or [_]MediaType
/// - `Type` must be able to generate `Type` using its declarations and function BodyParameters
pub fn isBodyParameters(comptime Type: type) bool {
    if (!isResourceParameters(Type))
        return false;

    const is_body_parameters_type =
        Type.parameters_type == .body;

    const has_alllowed_media_types =
        @hasDecl(Type, "allowed_media_types") and
        (@TypeOf(Type.allowed_media_types) == MediaType or (@typeInfo(@TypeOf(Type.allowed_media_types)) == .array and @typeInfo(@TypeOf(Type.allowed_media_types)).array.child == MediaType));

    const can_generate_self =
        is_body_parameters_type and has_alllowed_media_types and
        BodyParameters(Type.structure, Type.allowed_media_types) == Type;

    return is_body_parameters_type and can_generate_self;
}
