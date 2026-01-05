/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;

const parseFromSliceLeaky = std.json.parseFromSliceLeaky;
const hasMethod = std.meta.hasMethod;
const timestamp = std.time.timestamp;

/// Aura
const core = @import("core.zig");

const Authorization = core.net.headers.Authorization;

const assertValidate = core.utils.assertValidate;
const isContext = core.context.isContext;

/// Thrid Party
const zap = @import("zap");

const Request = zap.Request;

const jwt = @import("jwt");

const validateMessage = jwt.validateMessage;

pub const ClaimsSet = struct {
    pub const Permission = struct {
        const max_name_len: usize = 32;

        name: []const u8,
        ops: u4,

        pub fn validate(self: Permission) !void {
            if (self.name.len == 0)
                return error.NameTooShort;
            if (self.name.len > max_name_len)
                return error.NameTooLong;
        }

        pub fn allowsCreate(self: Permission) bool {
            return (self.ops & 0b1000) == 0b1000;
        }

        pub fn allowsRead(self: Permission) bool {
            return (self.ops & 0b0100) == 0b0100;
        }

        pub fn allowsUpdate(self: Permission) bool {
            return (self.ops & 0b0010) == 0b0010;
        }

        pub fn allowsDelete(self: Permission) bool {
            return (self.ops & 0b0001) == 0b0001;
        }
    };

    pub const Role = struct {
        const max_name_len: usize = 32;
        const perms_capacity: usize = 64;

        name: []const u8,
        perms: []const Permission,

        pub fn validate(self: Role) !void {
            if (self.name.len == 0)
                return error.NameTooShort;
            if (self.name.len > max_name_len)
                return error.NameTooLong;

            if (self.perms.len == 0)
                return error.TooFewPerms;
            if (self.perms.len > Role.perms_capacity)
                return error.TooManyPerms;

            for (self.perms) |perm| {
                try perm.validate();
            }
        }
    };

    const max_sub_len: usize = 64;
    const perms_capacity: usize = 128;
    const roles_capacity: usize = 32;

    sub: []const u8,
    perms: ?[]const Permission,
    roles: ?[]const Role,
    iat: i64,
    exp: i64,

    pub fn validate(self: ClaimsSet) !void {
        if (self.sub.len == 0)
            return error.SubTooShort;
        if (self.sub.len > max_sub_len)
            return error.SubTooLong;

        if (self.perms) |perms| {
            if (perms.len == 0)
                return error.TooFewPerms;
            if (perms.len > perms_capacity)
                return error.TooManyPerms;

            for (perms) |perm| {
                try perm.validate();
            }
        }

        if (self.roles) |roles| {
            if (roles.len == 0)
                return error.TooFewRoles;
            if (roles.len > roles_capacity)
                return error.TooManyRoles;

            for (roles) |role| {
                try role.validate();
            }
        }
    }

    pub fn isValid(self: ClaimsSet, request: *const Request) Validity {
        assertValidate(self.validate());

        _ = request;

        if (self.exp < timestamp())
            return .expired;

        return .valid;
    }
};

pub const Validity = enum {
    invalid,
    expired,
    valid,
};

pub fn JWTAuthorizationProcessor(comptime ClaimsSetType: type) type {
    if (!isJWTClaimsSet(ClaimsSetType))
        @compileError("`ClaimsSetType` must be JWTClaimsSet");

    return struct {
        const JWTAuthorizationProcessorType = @This();

        const min_key_len: usize = 32;
        const max_key_len: usize = 64;

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
                    @compileError("`context` must have field `jwt_key` which is typed as []const u8");
            }

            const context_key: []const u8 = @field(context.*, "jwt_key");

            if (context_key.len < min_key_len)
                return error.JWTKeyTooShort;
            if (context_key.len > max_key_len)
                return error.JWTKeyTooLong;

            self.key = try allocator.dupe(u8, context_key);
        }

        pub fn authorize(
            self: *const JWTAuthorizationProcessorType,
            request: *const Request,
            authorization_header: *const Authorization,
            claims_set_dest: *ClaimsSetType,
            allocator: Allocator,
        ) bool {
            if (authorization_header.scheme != .bearer)
                return false;

            const message =
                validateMessage(
                    allocator,
                    .HS256,
                    authorization_header.scheme.bearer,
                    .{ .key = self.key },
                ) catch return false;

            claims_set_dest.* =
                parseFromSliceLeaky(
                    ClaimsSetType,
                    allocator,
                    message,
                    .{ .allocate = .alloc_always },
                ) catch return false;

            const validity: Validity = claims_set_dest.isValid(request);

            return validity == .valid;
        }

        pub fn deinit(self: *JWTAuthorizationProcessorType, allocator: Allocator) void {
            allocator.free(self.key);
        }
    };
}

/// Trait check for AuthorizationProcessor
///
/// - `Type` must be struct
/// - `Type` must have declaration of method to check if it is valid, named "isValid"
///     - `isValid` must be decleration of method with signature fn (Type, *const Request) Validity
pub fn isJWTClaimsSet(comptime Type: type) bool {
    if (@typeInfo(Type) != .@"struct")
        return false;

    const has_is_valid =
        hasMethod(Type, "isValid") and
        @TypeOf(Type.isValid) == fn (Type, *const Request) Validity;

    return has_is_valid;
}
