/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Aura
const core = @import("core.zig");

const Environment = core.context.Environment;
const unhandledRequestRedirect = core.context.unhandledRequestRedirect;

const ApplicationType = core.application.Application;

const RouterType = core.routing.Router;
const JWTAuthorizationProcessor = core.jwt.JWTAuthorizationProcessor;
const LoggingOnRequestProcessor = core.log.LoggingOnRequestProcessor;

const StaticResource = core.routing.StaticResource;
const APIResource = core.routing.APIResource;
const ClaimsSet = core.jwt.ClaimsSet;

const PathParameters = core.routing.PathParameters;
const QueryParameters = core.routing.QueryParameters;
const HeaderParameters = core.routing.HeaderParameters;
const RequiredHeadersTag = core.routing.RequiredHeadersTag;
const RequiredHeaders = core.routing.RequiredHeaders;
const BodyParameters = core.routing.BodyParameters;
const MediaType = core.net.headers.MediaType;
const CommonMediaTypes = core.net.headers.CommonMediaTypes;
const ResultHeader = core.routing.ResultHeader;
const EnforcedHeadersTag = core.routing.EnforcedHeadersTag;
const EnforcedHeaders = core.routing.EnforcedHeaders;
const ResultBody = core.routing.ResultBody;
const ResultRedirect = core.routing.ResultRedirect;

/// Third Party
const zap = @import("zap");
const Request = zap.Request;
const StatusCode = zap.http.StatusCode;

const zeit = @import("zeit");
const Time = zeit.Time;
const Instant = zeit.Instant;

/// Test specs
/// Logging
const LogOptions = core.log.LogOptions{};
const LogFmtOptions = core.log.LogFmtOptions{};
const LoggerOptions = core.log.LoggerOptions{};

const Log = core.log.Log(LogOptions);
const LogProcessor = core.log.ConsoleLogProcessor(Log, LogFmtOptions, null);
const Logger = core.log.Logger(Log, LogProcessor, LoggerOptions);

/// Context
const Context = struct {
    environment: Environment,
    jwt_key: []const u8,
    logger: Logger,

    pub fn init(self: *Context, allocator: Allocator) anyerror!void {
        try self.environment.initAll(allocator);
        self.jwt_key = "01234567890123456789012345678901";
        self.logger.init(&self.environment);

        try self.logger.spawn();
    }

    pub fn deinit(self: *Context, allocator: Allocator) void {
        _ = allocator;

        self.logger.join();

        self.environment.deinit();
    }

    pub fn unhandledRequest(self: *Context, allocator: Allocator, request: Request) anyerror!void {
        unhandledRequestRedirect(
            "/pages/hello_world.html",
            Context,
            LoggingOnRequestProcessor(Context),
            self,
            allocator,
            request,
        );
    }
};

const Color = enum {
    red,
    green,
    blue,
};

const Item = struct {
    id: u64,
    name: []const u8,
    color: Color = .blue,
    date: ?Time,
};

/// App
const ResourceTree = struct {
    pub const pages = struct {
        pub const hello_world = StaticResource(
            "zig-out/resources/hello_world.html",
            .{},
            .{
                .authorize = null,
            },
        );
    };
    pub const api = struct {
        pub const items = APIResource(
            struct {
                pub fn get(
                    query_params: *const QueryParameters(struct {
                        redirect: bool,
                    }),
                    result_body: *ResultBody(?[]const u8, CommonMediaTypes.text),
                    result_redirect: *ResultRedirect(?[]const u8),
                ) !StatusCode {
                    if (query_params.data.redirect) {
                        result_redirect.data = "/pages/hello_world.html";
                        return .temporary_redirect;
                    } else {
                        result_body.data = "Hello world!";
                        return .ok;
                    }
                }
            },
            .{
                .authorize = null,
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
        .use_tls = .{
            .private_key_filepath = "zig-out/resources/secret/tls_key.key",
            .public_cert_filepath = "zig-out/resources/secret/tls_cert.crt",
        },
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
