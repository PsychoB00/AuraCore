/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;
const Method = std.http.Method;

const comptimePrint = std.fmt.comptimePrint;
const eql = std.mem.eql;
const isAlphanumeric = std.ascii.isAlphanumeric;
const isPrint = std.ascii.isPrint;
const isWhitespace = std.ascii.isWhitespace;
const hasMethod = std.meta.hasMethod;
const timestamp = std.time.timestamp;

/// Aura
const core = @import("core.zig");

const AuthorizationPolicy = core.routing.AuthorizationPolicy;
const Authorization = core.net.headers.Authorization;
const WWWAuthenticate = core.net.headers.WWWAuthenticate;
const Challenge = WWWAuthenticate.Challenge;
const AuthorizationResult = core.routing.AuthorizationResult;
const JsonInterpreter = core.json.DefaultJsonInterpreter;

const assertValidate = core.utils.assertValidate;
const isContext = core.context.isContext;
const validateRequirement = core.routing.Requirement.validate;
const validateRealm = core.routing.Realm.validate;
const parseLeaky = JsonInterpreter.parseLeaky;

/// Thrid Party
const jwt = @import("jwt");

const validateMessage = jwt.validateMessage;

pub const ClaimsSet = struct {
    pub const Realm = struct {
        pub const Permission = struct {
            name: []const u8,
            ops: u4,

            pub fn validate(self: Permission) !void {
                try validateRequirement(self.name);
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

        name: []const u8,
        perms: []const Permission,

        pub fn validate(self: Realm) !void {
            try validateRealm(self.name);

            if (self.perms.len == 0)
                return error.TooFewPerms;
            if (self.perms.len > AuthorizationPolicy.requirements_capacity)
                return error.TooManyPerms;

            for (self.perms, 0..) |perm, index| {
                try perm.validate();

                for (self.perms[(index + 1)..]) |check_perm| {
                    if (eql(u8, perm.name, check_perm.name))
                        return error.DuplicatePermissions;
                }
            }
        }
    };

    const max_sub_len: usize = 64;
    const realms_capacity: usize = 32;

    sub: []const u8,
    rlms: ?[]const Realm,
    iat: i64,
    exp: i64,

    pub fn validate(self: ClaimsSet) anyerror!void {
        if (self.sub.len == 0)
            return error.SubTooShort;
        if (self.sub.len > max_sub_len)
            return error.SubTooLong;

        for (self.sub) |character| {
            if (!(isAlphanumeric(character) or character == '-' or character == '_'))
                return error.InvalidCharacter;
        }

        if (self.rlms) |realms| {
            if (realms.len == 0)
                return error.TooFewRealms;
            if (realms.len > realms_capacity)
                return error.TooManyRealms;

            for (realms, 0..) |realm, index| {
                try realm.validate();

                for (realms[(index + 1)..]) |check_realm| {
                    if (eql(u8, realm.name, check_realm.name))
                        return error.DuplicateRealms;
                }
            }
        }
    }

    pub fn isValid(self: ClaimsSet, comptime MethodType: Method, comptime AuthPolicy: AuthorizationPolicy) Validity {
        comptime {
            // `AuthPolicy` correctness assertion
            AuthPolicy.validate() catch |err| {
                @compileError(comptimePrint(
                    "Invalid `AuthPolicy` found, cause {s}.",
                    .{@errorName(err)},
                ));
            };
        }

        assertValidate(self.validate());

        if (self.rlms == null)
            return .invalid;

        var found_realm = false;

        for (self.rlms.?) |realm| {
            if (!eql(u8, realm.name, AuthPolicy.realm))
                continue;

            inline for (AuthPolicy.requirements) |requirement| {
                var permission: ?*const Realm.Permission = null;

                for (realm.perms) |*perm| {
                    if (!eql(u8, requirement, perm.name))
                        continue;

                    permission = perm;
                    break;
                }

                if (permission == null)
                    return .invalid;

                switch (MethodType) {
                    inline .POST => {
                        // CREATE
                        if (!permission.?.allowsCreate())
                            return .invalid;
                    },
                    inline .GET, .HEAD, .OPTIONS => {
                        // READ
                        if (!permission.?.allowsRead())
                            return .invalid;
                    },
                    inline .PATCH => {
                        // UPDATE
                        if (!permission.?.allowsUpdate())
                            return .invalid;
                    },
                    inline .DELETE => {
                        // DELETE
                        if (!permission.?.allowsDelete())
                            return .invalid;
                    },
                    inline .PUT => {
                        // CREATE + UPDATE
                        if (!(permission.?.allowsCreate() and permission.?.allowsUpdate()))
                            return .invalid;
                    },
                    inline else => unreachable,
                }
            }

            found_realm = true;
        }

        if (!found_realm)
            return .invalid;

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

        fn _validateKey(key: []const u8) !void {
            if (key.len < min_key_len)
                return error.JWTKeyTooShort;
            if (key.len > max_key_len)
                return error.JWTKeyTooLong;
        }

        pub fn validate(self: JWTAuthorizationProcessorType) anyerror!void {
            try _validateKey(self.key);
        }

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

            try _validateKey(context_key);

            self.key = try allocator.dupe(u8, context_key);
        }

        pub fn authorize(
            self: *const JWTAuthorizationProcessorType,
            comptime MethodType: Method,
            comptime AuthPolicy: AuthorizationPolicy,
            authorization_header: *const Authorization,
            claims_set_dest: *ClaimsSetType,
            challenges: *[WWWAuthenticate.challenges_capacity]Challenge,
            challenge_count: *usize,
            allocator: Allocator,
        ) AuthorizationResult {
            assertValidate(self.validate());

            if (authorization_header.scheme != .bearer)
                return _failedAuthorize(.unauthorized, AuthPolicy, challenges, challenge_count, error.InvalidScheme);

            const message =
                validateMessage(
                    allocator,
                    .HS256,
                    authorization_header.scheme.bearer,
                    .{ .key = self.key },
                ) catch |err| return _failedAuthorize(.unauthorized, AuthPolicy, challenges, challenge_count, err);

            parseLeaky(ClaimsSetType, &message, claims_set_dest, allocator) catch |err|
                return _failedAuthorize(.unauthorized, AuthPolicy, challenges, challenge_count, err);

            claims_set_dest.validate() catch |err|
                return _failedAuthorize(.unauthorized, AuthPolicy, challenges, challenge_count, err);

            switch (claims_set_dest.isValid(MethodType, AuthPolicy)) {
                .invalid => return _failedAuthorize(.forbidden, AuthPolicy, challenges, challenge_count, error.TokenInvalid),
                .expired => return _failedAuthorize(.unauthorized, AuthPolicy, challenges, challenge_count, error.TokenExpired),
                .valid => return .authorized,
            }
        }

        pub fn raiseChallenge(
            comptime AuthPolicy: AuthorizationPolicy,
            challenges: *[WWWAuthenticate.challenges_capacity]Challenge,
            challenge_count: *usize,
            err: anyerror,
        ) void {
            challenges[challenge_count.*] = .{ .bearer = .{
                .realm = AuthPolicy.realm,
                .scope = AuthPolicy.requirements,
                .err = @errorName(err),
            } };

            challenge_count.* += 1;
        }

        fn _failedAuthorize(
            comptime Result: AuthorizationResult,
            comptime AuthPolicy: AuthorizationPolicy,
            challenges: *[WWWAuthenticate.challenges_capacity]Challenge,
            challenge_count: *usize,
            err: anyerror,
        ) AuthorizationResult {
            raiseChallenge(AuthPolicy, challenges, challenge_count, err);
            return Result;
        }

        pub fn deinit(self: *JWTAuthorizationProcessorType, allocator: Allocator) void {
            assertValidate(self.validate());

            allocator.free(self.key);
        }
    };
}

/// Trait check for ClaimSetType for JWTAuthorizationProcessor
///
/// - `Type` must be struct
/// - `Type` must have declaration of method to validate, named "validate"
///     - `validate` must be decleration of method with signature fn (Type) anyerror!void
/// - `Type` must have declaration of method to check if it is valid, named "isValid"
///     - `isValid` must be decleration of method with signature fn (Type, comptime Method, comptime AuthorizationPolicy) Validity
pub fn isJWTClaimsSet(comptime Type: type) bool {
    if (@typeInfo(Type) != .@"struct")
        return false;

    const has_validate =
        hasMethod(Type, "validate") and
        @TypeOf(Type.validate) == fn (Type) anyerror!void;

    const has_is_valid =
        hasMethod(Type, "isValid") and
        @TypeOf(Type.isValid) == fn (Type, comptime Method, comptime AuthorizationPolicy) Validity;

    return has_validate and has_is_valid;
}
