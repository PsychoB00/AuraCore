/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Aura
const core = @import("core.zig");

const Environment = core.context.Environment;

const ApplicationType = core.application.Application;

const RouterType = core.routing.Router;
const JWTAuthorizationProcessor = core.routing.JWTAuthorizationProcessor;
const LoggingOnRequestProcessor = core.routing.LoggingOnRequestProcessor;

const ResourceOptions = core.routing.ResourceOptions;
const StaticResource = core.routing.StaticResource;
const APIResource = core.routing.APIResource;

const PathParameters = core.routing.PathParameters;
const QueryParameters = core.routing.QueryParameters;
const HeaderParameters = core.routing.HeaderParameters;
const EnforcedHeadersTag = core.routing.EnforcedHeadersTag;
const EnforcedHeaders = core.routing.EnforcedHeaders;
const BodyParameters = core.routing.BodyParameters;
const MediaType = core.net.headers.MediaType;
const CommonMediaTypes = core.net.headers.CommonMediaTypes;

/// Third Party
const zap = @import("zap");
const StatusCode = zap.http.StatusCode;

const zeit = @import("zeit");
const Time = zeit.Time;

/// Test specs
/// Logging
const LogOptions = core.log.LogOptions{};
const LogFmtOptions = core.log.LogFmtOptions{};
const LoggerOptions = core.log.LoggerOptions{};

const Log = core.log.Log(LogOptions);
const LogProcessor = core.log.ConsoleLogProcessor(Log, LogFmtOptions, null);
const Logger = core.log.Logger(Log, LogProcessor, LoggerOptions);

/// Context
pub const ClaimsSet = struct {
    sub: []const u8,
    iat: i64,
    exp: i64,
};

const Context = struct {
    environment: Environment,
    jwt_key: []const u8,
    logger: Logger,

    pub fn init(self: *Context, allocator: Allocator) anyerror!void {
        try self.environment.initAll(allocator);
        self.jwt_key = "12345";
        self.logger.init(&self.environment);

        try self.logger.spawn();
    }

    pub fn deinit(self: *Context, allocator: Allocator) void {
        _ = allocator;

        self.logger.join();

        self.environment.deinit();
    }
};

/// App
const ResourceTree = struct {
    pub const pages = struct {
        pub const hello_world = StaticResource(
            "zig-out/resources/hello_world.html",
            .{},
            .{
                .authenticate = false,
            },
        );
    };
    pub const api = struct {
        pub const items = APIResource(
            struct {
                pub fn post(
                    header_params: *const HeaderParameters(EnforcedHeaders(.body_auth)),
                    body_params: *const BodyParameters(
                        []const u8,
                        MediaType{ .text = .{ .plain = .utf_8 } },
                    ),
                ) !StatusCode {
                    _ = header_params;
                    _ = body_params;
                    return .ok;
                }
            },
            .{
                .authenticate = true,
            },
        );
    };
};

const Router = RouterType(
    ResourceTree,
    Context,
    JWTAuthorizationProcessor(ClaimsSet),
    LoggingOnRequestProcessor(Context),
);

const Application = ApplicationType(
    .{
        .interface = "127.0.0.1",
        .port = 3000,
        .thread_count = 2,
        .worker_count = 1,
    },
    Router,
);

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
    }) = .{};
    defer std.debug.print("\n\nLeaks detected: {}\n\n", .{gpa.deinit() != .ok});
    const allocator = gpa.allocator();

    var app: Application = undefined;
    try app.init(allocator);
    defer app.deinit(allocator);

    try app.run();
}
