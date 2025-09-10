/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;

const comptimePrint = std.fmt.comptimePrint;
const eqlIgnoreCase = std.ascii.eqlIgnoreCase;

/// Aura
const core = @import("../core.zig");
const json = @import("../json.zig");

const ParametersType = core.routing.ParametersType;

const isResourceParameters = core.routing.isResourceParameters;

/// Third Party
const zap = @import("zap");
const Request = zap.Request;

const zimdjson = @import("zimdjson");
const JsonParser = zimdjson.ondemand.FullParser(.default);

/// Supported MIME types are:
/// - `text/plain`
///     - extention: .txt
///     - compatible types: []const u8
/// - `application/json`
///     - extention: .json
///     - compatible types:
///         - JSON compatible types
///         - []const u8 for enum
///         - []const u8 for date and time, formated to ISO 8601
pub const MIMEType = enum {
    text,
    json,
};

pub const ParseError = error{
    MissingBody,
    MissingContentType,
    UnsupportedMIMEType,
};

/// Parameters for larger and more complex data
///
/// - `Structure` is a type representing content of the body, can be optional type.
/// - `SupportedMIMETypes` can be either a single MIMEType value or array of them, if request has "Content-Type"
///   which isn't defined in `SupportedMIMETypes`, returned status code will be UNSUPPORTED_MEDIA_TYPE
/// - If any memory needs to be allocated during parsing of `Structure`, it will be allocated with
///   arena allocator provided by zap.Request, so no deallocation is nessesary. However this binds
///   the lifetime of the memory to lifetime of the zap.Request.
pub fn BodyParameters(comptime Structure: type, comptime SupportedMIMETypes: anytype) type {
    // Generated BodyParameters tools
    const Gen = struct {
        /// Checks if `Structure` is a valid representation of `Type`
        fn _isStructureValid(comptime Type: MIMEType) bool {
            const structure_type =
                if (@typeInfo(Structure) == .optional)
                    @typeInfo(Structure).optional.child
                else
                    Structure;

            switch (Type) {
                .text => return structure_type == []const u8,
                .json => {
                    json.validateJsonType(structure_type, true) catch return false;
                    return true;
                },
            }
        }

        /// Returns how many MIME types does `SupportedMIMETypes` represent
        fn _MIMETypesCount() usize {
            switch (@typeInfo(@TypeOf(SupportedMIMETypes))) {
                .array => return SupportedMIMETypes.len,
                .@"enum" => return 1,
                else => @compileError("Unsupported type of `SupportedMIMETypes` found"),
            }
        }

        /// If `SupportedMIMETypes` is a single MIME type converts it into an array
        fn _generateMIMETypesArray() [_MIMETypesCount()]MIMEType {
            switch (@typeInfo(@TypeOf(SupportedMIMETypes))) {
                .array => return SupportedMIMETypes,
                .@"enum" => return [1]MIMEType{SupportedMIMETypes},
                else => @compileError("Unsupported type of `SupportedMIMETypes` found"),
            }
        }
    };

    // `SupportedMIMETypes` correctness assertion
    switch (@typeInfo(@TypeOf(SupportedMIMETypes))) {
        .array => |info| {
            if (info.child != MIMEType)
                @compileError("Array with element type which isnt MIMEType found");
            if (SupportedMIMETypes.len == 0)
                @compileError("`SupportedMIMETypes` must have at least one element");
        },
        .@"enum" => {
            if (@TypeOf(SupportedMIMETypes) != MIMEType)
                @compileError("Enum which isn't MIMEType found");
        },
        else => @compileError("Unsupported type of `SupportedMIMETypes` found"),
    }

    const supported_mime_types_array = Gen._generateMIMETypesArray();

    for (supported_mime_types_array) |mime_type| {
        if (!Gen._isStructureValid(mime_type))
            @compileError(comptimePrint(
                "Failed to validate MIMEType ({})",
                .{mime_type},
            ));
    }

    return struct {
        const BodyParametersType = @This();

        pub const parameters_type: ParametersType = .body;
        pub const structure = Structure;
        pub const supported_mime_types = SupportedMIMETypes;

        data: Structure,

        /// Parse BodyParameters from `request`
        pub fn parse(allocator: *const Allocator, request: *const Request, dest: *BodyParametersType) !void {
            if (request.body == null) {
                if (comptime @typeInfo(Structure) == .optional) {
                    dest.data = null;
                    return;
                } else return ParseError.MissingBody;
            }

            const content_type = request.getHeaderCommon(.content_type) orelse
                return ParseError.MissingContentType;

            inline for (supported_mime_types_array) |mime_type| inline_loop: {
                switch (mime_type) {
                    inline .text => {
                        // text/plain
                        if (!eqlIgnoreCase(content_type, "text/plain"))
                            break :inline_loop;

                        dest.data = try allocator.dupe(u8, request.body.?);
                        return;
                    },
                    inline .json => {
                        // application/json
                        if (!eqlIgnoreCase(content_type, "application/json"))
                            break :inline_loop;

                        var parser = JsonParser.init;
                        defer parser.deinit(allocator.*);

                        const document: JsonParser.Document = try parser.parseFromSlice(allocator.*, request.body.?);
                        const document_value = try document.asAny();

                        dest.data = try json.asAny(JsonParser, Structure, &document_value, allocator);
                        return;
                    },
                }
            }

            return ParseError.UnsupportedMIMEType;
        }
    };
}

pub fn isBodyParameters(comptime Type: type) bool {
    return isResourceParameters(Type) and Type.parameters_type == .body and
        @hasDecl(Type, "supported_mime_types") and
        BodyParameters(Type.structure, Type.supported_mime_types) == Type;
}
