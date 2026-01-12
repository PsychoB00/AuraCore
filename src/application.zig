/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;

/// Aura
const core = @import("core.zig");

const isRouter = core.routing.isRouter;

/// Third party
const zap = @import("zap");

pub const ApplicationOptions = struct {
    interface: []const u8,
    port: u16,
    thread_count: u16,
    worker_count: u16,
};

pub fn Application(comptime Options: ApplicationOptions, comptime RouterType: type) type {
    if (!isRouter(RouterType))
        @compileError("`RouterType` must be Router");

    return struct {
        const AppType = @This();
        const ContextType = RouterType.context_t;
        const AuthorizationProcessorType = RouterType.authorization_processor_t;
        const ZapAppType = zap.App.Create(ContextType);

        context: ContextType,
        authorization_processor: (AuthorizationProcessorType orelse void),
        router: RouterType,

        pub fn init(self: *AppType, allocator: Allocator) !void {
            try self.context.init(allocator);
            if (comptime AuthorizationProcessorType != null)
                try self.authorization_processor.init(&self.context, allocator);

            try ZapAppType.init(allocator, &self.context, .{ .default_error_strategy = .raise });

            if (comptime AuthorizationProcessorType == null)
                try self.router.init()
            else
                try self.router.init(&self.authorization_processor);
        }

        pub fn run(self: *AppType) !void {
            _ = self;

            try ZapAppType.listen(.{
                .interface = @ptrCast(Options.interface.ptr),
                .port = Options.port,
            });

            zap.start(.{
                .threads = Options.thread_count,
                .workers = Options.worker_count,
            });
        }

        pub fn deinit(self: *AppType, allocator: Allocator) void {
            ZapAppType.deinit();

            if (comptime AuthorizationProcessorType != null)
                self.authorization_processor.deinit(allocator);
            self.context.deinit(allocator);
        }
    };
}
