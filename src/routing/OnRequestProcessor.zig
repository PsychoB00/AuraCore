/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;
const Method = std.http.Method;
const Timer = std.time.Timer;

const hasMethod = std.meta.hasMethod;
const comptimePrint = std.fmt.comptimePrint;
const bufPrint = std.fmt.bufPrint;

/// Aura
const core = @import("../core.zig");

const ParametersType = core.routing.ParametersType;

const hasLogger = core.context.hasLogger;
const getLogger = core.context.getLogger;
const methodToUpper = core.net.methodToUpper;
const statusCodeToUpper = core.net.statusCodeToUpper;

/// Third Party
const zap = @import("zap");

const Request = zap.Request;
const StatusCode = zap.http.StatusCode;

pub fn LoggingOnRequestProcessor(comptime ContextType: type) type {
    // `ContextType` correctness assertion
    const maybe_logger_type = hasLogger(ContextType);
    if (maybe_logger_type == null)
        @compileError("`ContextType` must have logger");

    return struct {
        const OnRequestProcessorType = @This();
        pub const context_t = ContextType;
        const logger_t = maybe_logger_type.?;

        timer: Timer,
        logger: *logger_t,
        request_scope: [logger_t.log_t.options.scope_len]u8,
        request_scope_len: usize,

        pub fn init(
            self: *OnRequestProcessorType,
            comptime RouteType: type,
            comptime MethodType: Method,
            _: Allocator,
            context: *ContextType,
            request: *const Request,
        ) void {
            comptime if ((methodToUpper(MethodType) ++ " @ " ++ RouteType.static_path).len >= logger_t.log_t.options.scope_len)
                @compileError("Max length of log scope must be bigger then the default scope of request");

            self.timer = Timer.start() catch unreachable;
            self.logger = getLogger(logger_t, context);

            self.request_scope = undefined;
            const request_scope = bufPrint(&self.request_scope, methodToUpper(MethodType) ++ " @ {s}{s}{s}", .{
                if (request.path != null) request.path.? else "",
                if (request.query != null) "?" else "",
                if (request.query != null) request.query.? else "",
            }) catch catch_blk: {
                _ = bufPrint(
                    &self.request_scope,
                    "{s}",
                    .{comptime methodToUpper(MethodType) ++ " @ " ++ RouteType.static_path},
                ) catch unreachable;
                break :catch_blk comptime methodToUpper(MethodType) ++ " @ " ++ RouteType.static_path;
            };

            self.request_scope_len = request_scope.len;

            self.logger
                .log(.info)
                .time()
                .scopeFmt("{s}", .{self.request_scope[0..self.request_scope_len]})
                .print("Received request")
                .commit();
        }

        pub fn requestInvalid(self: *OnRequestProcessorType, err: anyerror) void {
            var log = self.logger
                .log(.err)
                .time()
                .scopeFmt("{s}", .{self.request_scope[0..self.request_scope_len]});
            defer log.commit();

            _ = log.printTryFmt("Request invalid. Cause: {s}", .{@errorName(err)}) catch
                log.print("Request invalid");
        }

        pub fn parametersInvalid(self: *OnRequestProcessorType, comptime Type: ParametersType, err: anyerror) void {
            var log = self.logger
                .log(.err)
                .time()
                .scopeFmt("{s}", .{self.request_scope[0..self.request_scope_len]});
            defer log.commit();

            _ = log.printTryFmt("Request with invalid " ++ ParametersType.toString(Type) ++ "Parameters. Cause: {s}", .{@errorName(err)}) catch
                log.print("Request with invalid " ++ ParametersType.toString(Type) ++ "Parameters");
        }

        pub fn unauthorized(self: *OnRequestProcessorType) void {
            self.logger
                .log(.err)
                .time()
                .scopeFmt("{s}", .{self.request_scope[0..self.request_scope_len]})
                .print("Request with invalid authorization")
                .commit();
        }

        pub fn enforcedHeadersInvalid(self: *OnRequestProcessorType, err: anyerror) void {
            var log = self.logger
                .log(.err)
                .time()
                .scopeFmt("{s}", .{self.request_scope[0..self.request_scope_len]});
            defer log.commit();

            _ = log.printTryFmt("Request with invalid enforced headers. Cause: {s}", .{@errorName(err)}) catch
                log.print("Request with invalid enforced headers");
        }

        pub fn readFileError(self: *OnRequestProcessorType, err: anyerror) void {
            var log = self.logger
                .log(.err)
                .time()
                .scopeFmt("{s}", .{self.request_scope[0..self.request_scope_len]});
            defer log.commit();

            _ = log.printTryFmt("Failed to read file. Cause: {s}", .{@errorName(err)}) catch
                log.print("Failed to read file");
        }

        pub fn handlerError(self: *OnRequestProcessorType, err: anyerror) void {
            var log = self.logger
                .log(.err)
                .time()
                .scopeFmt("{s}", .{self.request_scope[0..self.request_scope_len]});
            defer log.commit();

            _ = log.printTryFmt("Failed to handle request. Cause: {s}", .{@errorName(err)}) catch
                log.print("Failed to handle request");
        }

        pub fn setHeadersError(self: *OnRequestProcessorType, err: anyerror) void {
            var log = self.logger
                .log(.err)
                .time()
                .scopeFmt("{s}", .{self.request_scope[0..self.request_scope_len]});
            defer log.commit();

            _ = log.printTryFmt("Failed to set headers. Cause: {s}", .{@errorName(err)}) catch
                log.print("Failed to set headers");
        }

        pub fn sendBodyError(self: *OnRequestProcessorType, err: anyerror) void {
            var log = self.logger
                .log(.err)
                .time()
                .scopeFmt("{s}", .{self.request_scope[0..self.request_scope_len]});
            defer log.commit();

            _ = log.printTryFmt("Failed to send body. Cause: {s}", .{@errorName(err)}) catch
                log.print("Failed to send body");
        }

        pub fn success(self: *OnRequestProcessorType, comptime Status: StatusCode) void {
            comptime if (@intFromEnum(Status) < 200 or @intFromEnum(Status) >= 300)
                @compileError("`Status` must be success code");

            const elapsed_time: u64 = self.timer.lap() / 1_000_000;

            var log = self.logger
                .log(.info)
                .time()
                .scopeFmt("{s}", .{self.request_scope[0..self.request_scope_len]});
            defer log.commit();

            const status_string = comptime comptimePrint(
                "{} {s}",
                .{ @intFromEnum(Status), statusCodeToUpper(Status) },
            );

            _ = log.printTryFmt("Request handeled succesfully in {}ms, responded with " ++ status_string, .{elapsed_time}) catch
                log.print("Request handeled succesfully, responded with " ++ status_string);
        }

        pub fn deinit(_: *OnRequestProcessorType) void {}
    };
}

/// Trait check for OnRequestProcessor
///
/// - `Type` must be struct
/// - `Type` must have declaration of what context type it is using, named "context_t"
///     - `context_t` must be decleration of type
/// - `Type` must have declaration of method for initializing, named "init"
///     - `init` must be decleration of method with signature fn (*Type, comptime type, comptime Method, Allocator, *Type.context_t, *const Request) void
/// - `Type` must have declaration of method for deinitializing, named "deinit"
///     - `deinit` must be decleration of method with signature fn (*Type) void
pub fn isOnRequestProcessor(comptime Type: type) bool {
    if (@typeInfo(Type) != .@"struct")
        return false;

    const has_context_type =
        @hasDecl(Type, "context_t") and
        @TypeOf(Type.context_t) == type;

    const has_init =
        has_context_type and
        hasMethod(Type, "init") and
        @TypeOf(Type.init) == fn (*Type, comptime type, comptime Method, Allocator, *Type.context_t, *const Request) void;

    const has_deinit =
        hasMethod(Type, "deinit") and
        @TypeOf(Type.deinit) == fn (*Type) void;

    return has_init and has_deinit;
}
