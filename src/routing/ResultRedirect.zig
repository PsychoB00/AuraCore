/// Aura
const core = @import("../core.zig");

const ResultType = core.routing.ResultType;

const isResourceResult = core.routing.isResourceResult;

/// Result for redirecting
///
/// - `Structure` can be either []const u8 or ?[]const u8
/// - `Structure` can be an optional type only if either ResultHeader or ResultBody are defined in endpoint
pub fn ResultRedirect(comptime Structure: type) type {
    return struct {
        const ResultRedirectType = @This();
        pub const result_type: ResultType = .redirect;
        pub const structure = Structure;

        data: Structure,
    };
}

/// Trait check for ResultRedirect
///
/// - `Type` must fulfill the isResourceResult trait check
/// - Declaration `result_type` from ResourceResult must have value ResultType.redirect
/// - `Type` must be able to generate `Type` using its declarations and function ResultRedirect
pub fn isResultRedirect(comptime Type: type) bool {
    if (!isResourceResult(Type))
        return false;

    const is_redirect_result_type =
        Type.result_type == .redirect;

    const can_generate_self =
        is_redirect_result_type and
        ResultRedirect(Type.structure) == Type;

    return is_redirect_result_type and can_generate_self;
}
