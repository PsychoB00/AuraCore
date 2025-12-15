/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;
const Reader = std.Io.Reader;

const comptimePrint = std.fmt.comptimePrint;
const eqlIgnoreCase = std.ascii.eqlIgnoreCase;
const eqlDeep = std.meta.eql;

/// Aura
const core = @import("../core.zig");

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
/// - If any memory needs to be allocated during parsing of `Structure`, it will be allocated with
///   arena allocator provided by zap.Request, so no deallocation is nessesary. However this binds
///   the lifetime of the memory to lifetime of the zap.Request.
pub fn BodyParameters(comptime Structure: type) type {
    if (Structure != []const u8)
        @compileError("BodyParameter content-type not yet implemented");

    return struct {
        const BodyParametersType = @This();
        pub const parameters_type: ParametersType = .body;
        pub const structure = Structure;

        data: Structure,

        /// Parse BodyParameters from `request`
        pub fn parse(allocator: Allocator, request: *const Request, dest: *BodyParametersType) !void {
            if (request.body == null)
                if (comptime @typeInfo(Structure) == .optional) {
                    dest.data = null;
                    return;
                } else return ParseError.MissingBody;

            dest.data = try allocator.dupe(u8, request.body.?);

            return ParseError.UnsupportedContentType;
        }
    };
}

pub fn isBodyParameters(comptime Type: type) bool {
    return isResourceParameters(Type) and Type.parameters_type == .body and
        @hasDecl(Type, "supported_content_types") and
        BodyParameters(Type.structure, Type.supported_content_types) == Type;
}
