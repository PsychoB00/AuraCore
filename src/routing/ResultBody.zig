/// Aura
const core = @import("../core.zig");

const ResultType = core.routing.ResultType;
const MediaType = core.net.headers.MediaType;

const isResourceResult = core.routing.isResourceResult;

pub fn ResultBody(comptime Structure: type, comptime ResultMediaType: ?MediaType) type {
    return struct {
        const ResultBodyType = @This();
        pub const result_type: ResultType = .body;
        pub const structure = Structure;
        pub const result_media_type = ResultMediaType;

        data: Structure,
    };
}

/// Trait check for ResultBody
///
/// - `Type` must fullfil the isResourceResult trait check
/// - Declaration `result_type` from ResourceResult must have value ResultType.body
/// - `Type` must have decleration of resulting media type, named "result_media_type"
///     - `result_media_type` must be declaretion of ?MediaType
/// - `Type` must be able to generate `Type` using its declarations and function ResultBody
pub fn isResultBody(comptime Type: type) bool {
    if (!isResourceResult(Type))
        return false;

    const is_body_result_type =
        Type.result_type == .body;

    const has_result_media_type =
        @hasDecl(Type, "result_media_type") and
        @TypeOf(Type.result_media_type) == ?MediaType;

    const can_generate_self =
        is_body_result_type and has_result_media_type and
        ResultBody(Type.structure, Type.result_media_type) == Type;

    return is_body_result_type and can_generate_self;
}
