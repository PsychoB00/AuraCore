/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Aura
const core = @import("core.zig");

const Enviroment = core.context.Environment;

const RouterType = core.routing.Router;
const JWTAuthenticator = core.jwt.JWTAuthenticator;
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

/// App
const Context = struct {
    logger: Logger,
};
const Color = enum {
    red,
    green,
    blue,
};
const ItemModel = struct {
    id: u64,
    name: []const u8,
    color: ?Color,
};

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
    pub const img = struct {
        pub const dome = StaticResource(
            "zig-out/resources/aura_dome.svg",
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
                    header_params: *const HeaderParameters(EnforcedHeaders(.body)),
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
                .authenticate = false,
            },
        );
    };
};

const Router = RouterType(
    ResourceTree,
    Context,
    JWTAuthenticator,
    LoggingOnRequestProcessor(Context),
);

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
    }) = .{};
    defer std.debug.print("\n\nLeaks detected: {}\n\n", .{gpa.deinit() != .ok});
    const allocator = gpa.allocator();

    var enviroment: Enviroment = undefined;
    try enviroment.initAll(allocator);
    defer enviroment.deinit();

    var my_context = Context{
        .logger = undefined,
    };

    my_context.logger.init(&enviroment);
    try my_context.logger.spawn();
    defer my_context.logger.join();

    const App = zap.App.Create(Context);
    try App.init(allocator, &my_context, .{});
    defer App.deinit();

    var authenticator = try core.jwt.JWTAuthenticator.init(allocator, "12345", null);
    defer authenticator.deinit();

    var router: Router = undefined;
    try router.init(&authenticator);

    try App.listen(.{
        .interface = "127.0.0.1",
        .port = 3000,
    });

    // start worker threads
    zap.start(.{
        .threads = 2,
        .workers = 1,
    });
}
