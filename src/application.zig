/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;

const cwd = std.fs.cwd;
const comptimePrint = std.fmt.comptimePrint;

/// Aura
const core = @import("core.zig");

const isRouter = core.routing.isRouter;
const hasLogger = core.context.hasLogger;
const getLogger = core.context.getLogger;

/// Third party
const zap = @import("zap");

const Tls = zap.Tls;

pub const ApplicationOptions = struct {
    interface: []const u8,
    port: u16,
    thread_count: u16,
    worker_count: u16,
    use_tls: ?TlsOptions,
};

pub const TlsOptions = struct {
    private_key_filepath: []const u8,
    public_cert_filepath: []const u8,
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
        tls: if (Options.use_tls != null) Tls else void,
        router: RouterType,

        pub fn init(self: *AppType, allocator: Allocator) !void {
            try self.context.init(allocator);
            if (comptime AuthorizationProcessorType != null)
                try self.authorization_processor.init(&self.context, allocator);

            if (comptime Options.use_tls != null) {
                const logger_type = hasLogger(ContextType);

                cwd().access(Options.use_tls.?.private_key_filepath, .{}) catch |err| {
                    if (comptime logger_type != null) {
                        var logger = getLogger(logger_type.?, &self.context);
                        var log = logger
                            .log(.fatal)
                            .time()
                            .scope("Application.init");
                        defer log.commit();

                        _ = log.printTryFmt("Server crashed when trying to access Tls private key at \"../" ++ Options.use_tls.?.private_key_filepath ++ "\", caused by {s}", .{@errorName(err)}) catch
                            log.print("Server crashed when trying to access Tls private key at " ++ Options.use_tls.?.private_key_filepath);
                    }
                    unreachable;
                };

                cwd().access(Options.use_tls.?.public_cert_filepath, .{}) catch |err| {
                    if (comptime logger_type != null) {
                        var logger = getLogger(logger_type.?, &self.context);
                        var log = logger
                            .log(.fatal)
                            .time()
                            .scope("Application.init");
                        defer log.commit();

                        _ = log.printTryFmt("Server crashed when trying to access Tls public certificate at \"../" ++ Options.use_tls.?.public_cert_filepath ++ "\", caused by {s}", .{@errorName(err)}) catch
                            log.print("Server crashed when trying to access Tls public certificate at " ++ Options.use_tls.?.public_cert_filepath);
                    }
                    unreachable;
                };

                self.tls = try Tls.init(.{
                    .server_name = comptimePrint("{s}:{d}", .{ Options.interface, Options.port }),
                    .public_certificate_file = @ptrCast(Options.use_tls.?.public_cert_filepath ++ "\x00"),
                    .private_key_file = @ptrCast(Options.use_tls.?.private_key_filepath ++ "\x00"),
                });
            }

            try ZapAppType.init(allocator, &self.context, .{ .default_error_strategy = .raise });

            if (comptime AuthorizationProcessorType == null)
                try self.router.init()
            else
                try self.router.init(&self.authorization_processor);
        }

        pub fn run(self: *AppType) !void {
            try ZapAppType.listen(.{
                .interface = @ptrCast(Options.interface.ptr),
                .port = Options.port,
                .tls = if (comptime Options.use_tls != null) self.tls else null,
            });

            zap.start(.{
                .threads = Options.thread_count,
                .workers = Options.worker_count,
            });
        }

        pub fn deinit(self: *AppType, allocator: Allocator) void {
            ZapAppType.deinit();

            if (comptime Options.use_tls != null)
                self.tls.deinit();
            if (comptime AuthorizationProcessorType != null)
                self.authorization_processor.deinit(allocator);
            self.context.deinit(allocator);
        }
    };
}
