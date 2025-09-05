/// STD
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Aura
const core = @import("root.zig");

const Enviroment = core.context.Environment;
const ResourceTreeOptions = core.router.ResourceTreeOptions;
const ResourceTree = core.router.ResourceTree;
const PathParameters = core.api_resource.PathParameters;
const QueryParameters = core.api_resource.QueryParameters;
const BodyParameters = core.api_resource.BodyParameters;

/// Third Party
const zap = @import("zap");
const Request = zap.Request;
const StatusCode = zap.http.StatusCode;

const zeit = @import("zeit");
const Time = zeit.Time;

/// Test specs
/// Logging
const LogOptions = core.log.LogOptions{};
const LogFmtOptions = core.log.LogFmtOptions{};
const LoggerOptions = core.log.LoggerOptions{};

const Log = core.log.Log(LogOptions);
const LogProcessor = core.log.ConsoleLogProcessor(Log, LogFmtOptions);
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
    color: Color = .blue,
};

const html = "<!DOCTYPE html><html><head><title>Hello World</title></head><body><h1>Hello World!</h1></body></html>";

const APIController = struct {
    pub const api = struct {
        pub const items = struct {
            pub fn post(
                context: *Context,
                body_params: *const BodyParameters(ItemModel),
            ) !StatusCode {
                context.logger.log(.info).time().scope("POST @ /api/items").printFmt("{} {s} {}\n", .{ body_params.data.id, body_params.data.name, body_params.data.color }).commit();
                return .ok;
            }
        };
    };
};
const IndexController = struct {
    pub const index = core.static_resource.StaticResource(.html, html);
};

const Router = core.router.Router(
    .{
        ResourceTree(
            IndexController,
            ResourceTreeOptions{
                .resource_type = .static,
                .authenticated = false,
            },
        ),
        ResourceTree(
            APIController,
            ResourceTreeOptions{
                .resource_type = .api,
                .authenticated = false,
            },
        ),
    },
    Context,
    core.jwt.JWTAuthenticator,
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
