/// STD
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Aura
const core = @import("core.zig");
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

const Context = struct {
    a: u32 = 32,
    b: bool = false,
};

const ItemModel = struct {
    id: u64,
    name: []const u8 = "NOT_FOUND",
    valid: ?bool,
    made_at: Time,
};

const html = "<!DOCTYPE html><html><head><title>Hello World</title></head><body><h1>Hello World!</h1></body></html>";

const APIController = struct {
    pub const api = struct {
        pub const items = struct {
            pub fn post(
                body_params: *const BodyParameters(ItemModel),
            ) !StatusCode {
                std.debug.print("{} {s} {?} {}\n", .{ body_params.data.id, body_params.data.name, body_params.data.valid, body_params.data.made_at });
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

    var my_context: Context = .{};

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
