/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;

const Method = std.http.Method;

const hasMethod = std.meta.hasMethod;

/// Aura
const core = @import("../core.zig");

const Authorization = core.net.headers.Authorization;

/// Third party
const zap = @import("zap");

const Request = zap.Request;

pub const AuthorizationResult = enum {
    unauthorized,
    forbidden,
    authorized,
};

/// Trait check for AuthorizationProcessor
///
/// - `Type` must be struct
/// - `Type` must have declaration of what claims set type it is using, named "claims_set_t"
///     - `claims_set_t` must be decleration of type
/// - `Type` must have declaration of method for initializing, named "init"
///     - `init` must be decleration of method with signature fn (*Type, anytype, Allocator) anyerror!void
///     - Type of second parameter is a pointer to Context of Application which is using the AuthorizationProcessor
/// - `Type` must have declaration of method for deinitializing, named "deinit"
///     - `deinit` must be decleration of method with signature fn (*Type, Allocator) void
/// - `Type` must have declaration of method for authorizing, named "authorize"
///     - `authorize` must be decleration of method with signature
///       fn (*const Type, comptime Method, comptime []const []const u8, *const Authorization, *Type.claims_set_t, Allocator) AuthorizationResult
pub fn isAuthorizationProcessor(comptime Type: type) bool {
    if (@typeInfo(Type) != .@"struct")
        return false;

    const has_claims_set =
        @hasDecl(Type, "claims_set_t") and
        @TypeOf(Type.claims_set_t) == type;

    const has_init =
        hasMethod(Type, "init") and
        @TypeOf(Type.init) == fn (*Type, anytype, Allocator) anyerror!void;

    const has_deinit =
        hasMethod(Type, "deinit") and
        @TypeOf(Type.deinit) == fn (*Type, Allocator) void;

    const has_authorize =
        has_claims_set and
        hasMethod(Type, "authorize") and
        @TypeOf(Type.authorize) == fn (*const Type, comptime Method, comptime []const []const u8, *const Authorization, *Type.claims_set_t, Allocator) AuthorizationResult;

    return has_init and has_deinit and has_authorize;
}
