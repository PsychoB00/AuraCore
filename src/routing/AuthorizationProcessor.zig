/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;

const hasMethod = std.meta.hasMethod;

/// Aura
const core = @import("../core.zig");

const Authorization = core.net.headers.Authorization;

const isContext = core.context.isContext;

/// Third party
const zap = @import("zap");

const Request = zap.Request;

pub fn JWTAuthorizationProcessor(comptime ClaimsSetType: type) type {
    return struct {
        const JWTAuthorizationProcessorType = @This();

        pub const claims_set_t = ClaimsSetType;

        key: []const u8,

        pub fn init(self: *JWTAuthorizationProcessorType, context: anytype, allocator: Allocator) anyerror!void {
            comptime {
                // `context` correctness assertion
                const context_info = @typeInfo(@TypeOf(context));
                if (!(context_info == .pointer and !context_info.pointer.is_const))
                    @compileError("`context` isn't a non-const pointer");

                if (!isContext(context_info.pointer.child))
                    @compileError("`context` must be typed as a non-const pointer to a type which fulfill the isContext trait check");

                if (!(@hasField(context_info.pointer.child, "jwt_key") and @FieldType(context_info.pointer.child, "jwt_key") == []const u8))
                    @compileError("`context` must have field `jwt_key` witch is typed as []const u8");
            }

            self.key = try allocator.dupe(u8, @field(context.*, "jwt_key"));
        }

        pub fn process(self: *const JWTAuthorizationProcessorType, request: *const Request, authorization_header: *const Authorization, claims_set_dest: *ClaimsSetType) bool {
            _ = self;
            _ = request;
            _ = authorization_header;
            _ = claims_set_dest;

            return true;
        }

        pub fn deinit(self: *JWTAuthorizationProcessorType, allocator: Allocator) void {
            allocator.free(self.key);
        }
    };
}

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
/// - `Type` must have declaration of method for processing the authorization, named "process"
///     - `process` must be decleration of method with signature fn (*const Type, *const Request, *const Authorization, *Type.claims_set_t) bool
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

    const has_process =
        has_claims_set and
        hasMethod(Type, "process") and
        @TypeOf(Type.process) == fn (*const Type, *const Request, *const Authorization, *Type.claims_set_t) bool;

    return has_init and has_deinit and has_process;
}
