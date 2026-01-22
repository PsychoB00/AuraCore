/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;
const Method = std.http.Method;

const isAlphanumeric = std.ascii.isAlphanumeric;
const isPrint = std.ascii.isPrint;
const isWhitespace = std.ascii.isWhitespace;
const eqlIgnoreCase = std.ascii.eqlIgnoreCase;
const hasMethod = std.meta.hasMethod;
const timestamp = std.time.timestamp;

/// Aura
const core = @import("core.zig");

const Authorization = core.net.headers.Authorization;
const AuthorizationResult = core.routing.AuthorizationResult;
const JsonInterpreter = core.json.DefaultJsonInterpreter;

const assertValidate = core.utils.assertValidate;
const isContext = core.context.isContext;
const validateRequirementChar = core.routing.Requirement.validateRequirementChar;
const parseLeaky = JsonInterpreter.parseLeaky;

/// Thrid Party
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

            for (self.name) |character| {
                try validateRequirementChar(character);
            }
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

    const max_sub_len: usize = 64;
    const perms_capacity: usize = 128;

    sub: []const u8,
    perms: ?[]const Permission,
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

        if (self.perms) |perms| {
            if (perms.len == 0)
                return error.TooFewPerms;
            if (perms.len > perms_capacity)
                return error.TooManyPerms;

            for (perms, 0..) |perm, index| {
                try perm.validate();

                for (perms[(index + 1)..]) |check_perm| {
                    if (eqlIgnoreCase(perm.name, check_perm.name))
                        return error.DuplicatePermission;
                }
            }
        }
    }

    pub fn isValid(self: ClaimsSet, comptime MethodType: Method, comptime RequirementsSet: []const []const u8) Validity {
        comptime {
            // `RequirementsSet` correctness assertion
            if (RequirementsSet.len > perms_capacity)
                @compileError("`RequirementsSet` mustn't have more requirements then `self` can have permission");

            for (RequirementsSet, 0..) |requirement, index| {
                if (requirement.len == 0)
                    @compileError("Requirement with zero length found in `RequirementsSet`");
                if (requirement.len > Permission.max_name_len)
                    @compileError("Requirement with length over `Permission.max_name_len` found in `RequirementsSet`");

                for (requirement) |character| {
                    validateRequirementChar(character) catch
                        @compileError("Requirement with invalid character found in `RequirementsSet`");
                }

                for (RequirementsSet[(index + 1)..]) |check_requirement| {
                    if (eqlIgnoreCase(requirement, check_requirement))
                        @compileError("`RequirementsSet` mustn't have any duplicate values (case insensitive)");
                }
            }
        }

        assertValidate(self.validate());

        if (self.perms == null)
            return .invalid;

        inline for (RequirementsSet) |requirement| {
            var permission: ?*const Permission = null;

            for (self.perms.?) |*perm| {
                if (!eqlIgnoreCase(requirement, perm.name))
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
            comptime RequirementsSet: []const []const u8,
            authorization_header: *const Authorization,
            claims_set_dest: *ClaimsSetType,
            allocator: Allocator,
        ) AuthorizationResult {
            assertValidate(self.validate());

            if (authorization_header.scheme != .bearer)
                return .unauthorized;

            const message =
                validateMessage(
                    allocator,
                    .HS256,
                    authorization_header.scheme.bearer,
                    .{ .key = self.key },
                ) catch return .unauthorized;

            parseLeaky(ClaimsSetType, &message, claims_set_dest, allocator) catch
                return .unauthorized;

            claims_set_dest.validate() catch
                return .unauthorized;

            switch (claims_set_dest.isValid(MethodType, RequirementsSet)) {
                .invalid => return .forbidden,
                .expired => return .unauthorized,
                .valid => return .authorized,
            }
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
///     - `isValid` must be decleration of method with signature fn (Type, comptime Method, comptime []const []const u8) Validity
pub fn isJWTClaimsSet(comptime Type: type) bool {
    if (@typeInfo(Type) != .@"struct")
        return false;

    const has_validate =
        hasMethod(Type, "validate") and
        @TypeOf(Type.validate) == fn (Type) anyerror!void;

    const has_is_valid =
        hasMethod(Type, "isValid") and
        @TypeOf(Type.isValid) == fn (Type, comptime Method, comptime []const []const u8) Validity;

    return has_validate and has_is_valid;
}
