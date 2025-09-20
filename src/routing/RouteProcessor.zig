/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;
const Method = std.http.Method;
const Timer = std.time.Timer;

const hasMethod = std.meta.hasMethod;
const comptimePrint = std.fmt.comptimePrint;

/// Aura
const core = @import("../core.zig");

const ParametersType = core.routing.ParametersType;

const hasLogger = core.context.hasLogger;
const methodToUpper = core.net.methodToUpper;

/// Third Party
const zap = @import("zap");

const Request = zap.Request;
const StatusCode = zap.http.StatusCode;

pub fn LoggingRouteProcessor(comptime ContextType: type) type {
    // `ContextType` correctness assertion
    const maybe_logger_type = hasLogger(ContextType);
    if (maybe_logger_type == null)
        @compileError("`ContextType` must have logger");

    return struct {
        const RouteProcessorType = @This();
        pub const context_t = ContextType;
        const logger_t = maybe_logger_type.?;

        timer: Timer,
        logger: *logger_t,

        request: *const Request,

        pub fn init(
            self: *RouteProcessorType,
            _: Allocator,
            context: *ContextType,
            request: *const Request,
        ) void {
            self.timer = Timer.start() catch unreachable;
            self.logger = core.context.getLogger(logger_t, context);
            self.request = request;
        }

        pub fn start(self: *RouteProcessorType, comptime MethodType: Method, comptime RouteType: type) void {
            var log = self.logger.log(.info).time();
            defer log.commit();

            _requestScope(log, MethodType, RouteType, self.request);

            _ = log.print("Received request...");
        }

        pub fn requestError(
            self: *RouteProcessorType,
            comptime MethodType: Method,
            comptime RouteType: type,
            comptime Status: StatusCode,
        ) void {
            comptime if (@intFromEnum(Status) < 400 or @intFromEnum(Status) >= 600)
                @compileError("`Status` must be error code");

            var log = self.logger.log(.err).time();
            defer log.commit();

            _requestScope(log, MethodType, RouteType, self.request);

            _ = log.print(comptimePrint(
                "Request resulted in error code: {} {s}",
                .{ @intFromEnum(Status), core.net.statusCodeToUpper(Status) },
            ));
        }

        pub fn parametersParseError(
            self: *RouteProcessorType,
            comptime MethodType: Method,
            comptime RouteType: type,
            comptime Type: ParametersType,
            err: anyerror,
        ) void {
            var log = self.logger.log(.err).time();
            defer log.commit();

            _requestScope(log, MethodType, RouteType, self.request);

            _ = log.printTryFmt("Failed to parse" ++ ParametersType.toString(Type) ++ "Parameters. Cause: {s}", .{@errorName(err)}) catch
                log.print("Failed to parse " ++ ParametersType.toString(Type) ++ "Parameters");
        }

        pub fn readFileError(
            self: *RouteProcessorType,
            comptime MethodType: Method,
            comptime RouteType: type,
            err: anyerror,
        ) void {
            var log = self.logger.log(.err).time();
            defer log.commit();

            _requestScope(log, MethodType, RouteType, self.request);

            _ = log.printTryFmt("Failed to read file. Cause: {s}", .{@errorName(err)}) catch
                log.print("Failed to read file");
        }

        pub fn setHeadersError(
            self: *RouteProcessorType,
            comptime MethodType: Method,
            comptime RouteType: type,
            err: anyerror,
        ) void {
            var log = self.logger.log(.err).time();
            defer log.commit();

            _requestScope(log, MethodType, RouteType, self.request);

            _ = log.printTryFmt("Failed to set headers. Cause: {s}", .{@errorName(err)}) catch
                log.print("Failed to set headers");
        }

        pub fn sendBodyError(
            self: *RouteProcessorType,
            comptime MethodType: Method,
            comptime RouteType: type,
            err: anyerror,
        ) void {
            var log = self.logger.log(.err).time();
            defer log.commit();

            _requestScope(log, MethodType, RouteType, self.request);

            _ = log.printTryFmt("Failed to send body. Cause: {s}", .{@errorName(err)}) catch
                log.print("Failed to send body");
        }

        pub fn success(
            self: *RouteProcessorType,
            comptime MethodType: Method,
            comptime RouteType: type,
            comptime Status: StatusCode,
        ) void {
            comptime if (@intFromEnum(Status) < 200 or @intFromEnum(Status) >= 300)
                @compileError("`Status` must be success code");

            const elapsed_time: u64 = self.timer.lap() / 1_000_000;
            var log = self.logger.log(.info).time();
            defer log.commit();

            _requestScope(log, MethodType, RouteType, self.request);

            const status_string = comptime comptimePrint(
                "{} {s}",
                .{ @intFromEnum(Status), core.net.statusCodeToUpper(Status) },
            );

            _ = log.printTryFmt("Request handeled succesfully in {}ms and resulted in code: " ++ status_string, .{elapsed_time}) catch
                log.print("Request handeled succesfully and resulted in code: " ++ status_string);
        }

        pub fn deinit(_: *RouteProcessorType) void {}

        fn _requestScope(log: anytype, comptime MethodType: Method, comptime RouteType: type, request: *const Request) void {
            _ = log.scopeTryFmt(
                methodToUpper(MethodType) ++ " @ {s}{s}{s}",
                .{
                    if (request.path != null) request.path.? else "",
                    if (request.query != null) "?" else "",
                    if (request.query != null) request.query.? else "",
                },
            ) catch {
                _ = log.scope(methodToUpper(MethodType) ++ " @ " ++ RouteType.static_path);
            };
        }
    };
}

pub fn isRouteProcessor(comptime Type: type) bool {
    return @hasDecl(Type, "context_t") and @TypeOf(Type.context_t) == type and
        hasMethod(Type, "init") and @TypeOf(Type.init) == fn (*Type, Allocator, *Type.context_t, *const Request) void and
        hasMethod(Type, "deinit") and @TypeOf(Type.deinit) == fn (*Type) void;
}
