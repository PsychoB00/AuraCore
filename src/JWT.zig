/// STD
const std = @import("std");
const log = std.log;
const Allocator = std.mem.Allocator;

/// Thrid Party
const zap = @import("zap");
const jwt = @import("jwt");

pub const JWTPayload = struct {
    sub: []const u8,
    iat: i64,
    exp: i64,
};

/// Copy of https://zigzap.org/zap/#zap.http_auth.BearerSingle but changed to authenticate JWT
pub const JWTAuthenticator = struct {
    allocator: Allocator,
    token: []const u8,
    realm: ?[]const u8,

    /// Initialize JWTAuthenticator
    ///
    /// MUST CALL `deinit` to deinitialize
    pub fn init(allocator: Allocator, key: []const u8, realm: ?[]const u8) !JWTAuthenticator {
        return .{
            .allocator = allocator,
            .token = try allocator.dupe(u8, key),
            .realm = if (realm) |the_realm| try allocator.dupe(u8, the_realm) else null,
        };
    }

    /// The aura authentication request handler.
    ///
    /// Tries to extract the authentication header and perform the authentication.
    pub fn authenticateRequest(self: *JWTAuthenticator, r: *const zap.Request) zap.Auth.AuthResult {
        r.parseCookies(false);
        const auth_cookie = (r.getCookieStr(self.allocator, zap.Auth.AuthScheme.Bearer.headerFieldStrFio()) catch return .AuthFailed) orelse return .AuthFailed;
        defer self.allocator.free(auth_cookie);

        const token = auth_cookie[zap.Auth.AuthScheme.Bearer.str().len..];
        const payload = jwt.validate(JWTPayload, self.allocator, .HS256, token, .{ .key = self.token }) catch return .AuthFailed;
        defer payload.deinit();
        return if (payload.value.exp > std.time.timestamp()) .AuthOK else .AuthFailed;
    }

    /// Deinitialize JWTAuthenticator
    pub fn deinit(self: *JWTAuthenticator) void {
        if (self.realm) |the_realm| {
            self.allocator.free(the_realm);
        }
        self.allocator.free(self.token);
    }
};

/// Wrapper for holding Endpoint and it's JWT Authenticating version
pub fn JWTAuthEndpoint(comptime Endpoint: type, comptime App: type) type {
    return struct {
        const AuthEndpoint = App.Endpoint.Authenticating(Endpoint, JWTAuthenticator);

        ep: Endpoint,
        auth_ep: AuthEndpoint,

        pub fn init(self: *JWTAuthEndpoint(Endpoint, App), path: []const u8, authenticator: *JWTAuthenticator) void {
            self.ep.init(path);
            self.auth_ep = AuthEndpoint.init(&self.ep, authenticator);
        }
    };
}
