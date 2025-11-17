/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;

const comptimePrint = std.fmt.comptimePrint;
const eqlIgnoreCase = std.ascii.eqlIgnoreCase;
const eqlDeep = std.meta.eql;

/// Aura
const core = @import("../core.zig");

const ContentType = core.net.headers.ContentType;
const ParametersType = core.routing.ParametersType;

const isResourceParameters = core.routing.isResourceParameters;
const asAny = core.json.asAny;

/// Third Party
const zap = @import("zap");
const Request = zap.Request;

const zimdjson = @import("zimdjson");
const JsonParser = zimdjson.ondemand.FullParser(.default);

pub const ParseError = error{
    MissingBody,
    MissingContentType,
    UnsupportedContentType,
};

/// Parameters for larger and more complex data
///
/// - `Structure` is a type representing content of the body, can be optional type.
/// - `SupportedContentTypes` can be either a single ContentType value or array of them, if request has "Content-Type"
///   which isn't defined in `SupportedContentTypes`, parse will fail
/// - If any memory needs to be allocated during parsing of `Structure`, it will be allocated with
///   arena allocator provided by zap.Request, so no deallocation is nessesary. However this binds
///   the lifetime of the memory to lifetime of the zap.Request.
pub fn BodyParameters(comptime Structure: type, comptime SupportedContentTypes: anytype) type {
    // Generated BodyParameters tools
    const Gen = struct {
        /// Checks if `Structure` is a valid representation of `Header`
        fn _isStructureValid(comptime Header: ContentType) void {
            const structure_type =
                if (@typeInfo(Structure) == .optional)
                    @typeInfo(Structure).optional.child
                else
                    Structure;

            ContentType.validateType(Header, structure_type);
        }

        /// Returns how many headers does `SupportedContentTypes` represent
        fn _ContentTypesCount() usize {
            switch (@typeInfo(@TypeOf(SupportedContentTypes))) {
                .array => return SupportedContentTypes.len,
                .@"struct" => return 1,
                else => @compileError("Unsupported type of `SupportedContentTypes` found"),
            }
        }

        /// If `SupportedContentTypes` is a single header, converts it into an array
        fn _generateContentTypesArray() [_ContentTypesCount()]ContentType {
            switch (@typeInfo(@TypeOf(SupportedContentTypes))) {
                .array => return SupportedContentTypes,
                .@"struct" => return [1]ContentType{SupportedContentTypes},
                else => @compileError("Unsupported type of `SupportedContentTypes` found"),
            }
        }
    };

    // `SupportedContentTypes` correctness assertion
    switch (@typeInfo(@TypeOf(SupportedContentTypes))) {
        .array => |info| {
            if (info.child != ContentType)
                @compileError("Array with element type which isn't ContentType found");
            if (SupportedContentTypes.len == 0)
                @compileError("`SupportedContentTypes` must have at least one element");
        },
        .@"struct" => {
            if (@TypeOf(SupportedContentTypes) != ContentType)
                @compileError("Struct which isn't ContentType found");
        },
        else => @compileError("Unsupported type of `SupportedContentTypes` found"),
    }

    const supported_content_types_array = Gen._generateContentTypesArray();

    for (supported_content_types_array) |content_type| {
        Gen._isStructureValid(content_type);
    }

    return struct {
        const BodyParametersType = @This();
        pub const parameters_type: ParametersType = .body;
        pub const structure = Structure;
        pub const supported_content_types = SupportedContentTypes;

        data: Structure,

        /// Parse BodyParameters from `request`
        pub fn parse(allocator: Allocator, request: *const Request, dest: *BodyParametersType) !void {
            if (request.body == null)
                if (comptime @typeInfo(Structure) == .optional) {
                    dest.data = null;
                    return;
                } else return ParseError.MissingBody;

            var content_type: ContentType = undefined;

            const content_type_string = request.getHeaderCommon(.content_type) orelse
                return ParseError.MissingContentType;
            var content_type_reader = Reader.fixed(content_type_string);
            try content_type.parse(&content_type_reader);

            inline for (supported_content_types_array) |supported_content_type| inline_loop: {
                if (!eqlDeep(content_type, supported_content_type))
                    break :inline_loop;

                switch (supported_content_type.mime) {
                    inline .text => |@"type"| {
                        switch (@"type") {
                            inline .html, .plain => {
                                dest.data = try allocator.dupe(u8, request.body.?);
                            },
                            inline .wildcard => unreachable,
                        }
                    },
                    inline .application => |@"type"| {
                        switch (@"type") {
                            inline .json => {
                                var parser = JsonParser.init;
                                defer parser.deinit(allocator);

                                const document: JsonParser.Document = try parser.parseFromSlice(allocator, request.body.?);
                                const document_value = try document.asAny();

                                dest.data = try asAny(JsonParser, Structure, &document_value, allocator);
                            },
                            inline .wildcard => unreachable,
                        }
                    },
                    inline .wildcard => unreachable,
                }

                return;
            }

            return ParseError.UnsupportedContentType;
        }
    };
}

pub fn isBodyParameters(comptime Type: type) bool {
    return isResourceParameters(Type) and Type.parameters_type == .body and
        @hasDecl(Type, "supported_content_types") and
        BodyParameters(Type.structure, Type.supported_content_types) == Type;
}
