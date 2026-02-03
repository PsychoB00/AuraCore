/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;
const Method = std.http.Method;
const Timer = std.time.Timer;
const StackTrace = std.builtin.StackTrace;
const Writer = std.Io.Writer;

const assert = std.debug.assert;
const comptimePrint = std.fmt.comptimePrint;
const bufPrint = std.fmt.bufPrint;

const buildin = @import("builtin");

const IsDebug = buildin.mode == .Debug;

/// Aura
const core = @import("../core.zig");

const status_code = core.net.status_code;
const ParametersType = core.routing.ParametersType;
const ResultType = core.routing.ResultType;

const hasLogger = core.context.hasLogger;
const getLogger = core.context.getLogger;
const methodToUpper = core.net.methodToUpper;
const statusCodeToUpper = core.net.statusCodeToUpper;
const statusCodeFormat = core.net.statusCodeFormat;
const isStatusCodeSuccess = core.net.isStatusCodeSuccess;
const isStatusCodeRedirect = core.net.isStatusCodeRedirect;

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
                break :catch_blk bufPrint(
                    &self.request_scope,
                    "{s}",
                    .{comptime methodToUpper(MethodType) ++ " @ " ++ RouteType.static_path},
                ) catch unreachable;
            };

            self.request_scope_len = request_scope.len;

            self.logger
                .log(.info)
                .time()
                .scopeFmt("{s}", .{self.request_scope[0..self.request_scope_len]})
                .print("Received request")
                .commit();
        }

        pub fn initUnhandledRequest(
            self: *OnRequestProcessorType,
            comptime MethodType: Method,
            _: Allocator,
            context: *ContextType,
            request: *const Request,
        ) void {
            const min_scope_len: usize = (comptime methodToUpper(MethodType) ++ " @ /...").len;
            comptime if (min_scope_len >= logger_t.log_t.options.scope_len)
                @compileError("Max length of log scope must be bigger then the default scope of request");

            self.timer = Timer.start() catch unreachable;
            self.logger = getLogger(logger_t, context);

            self.request_scope = undefined;
            const request_scope = bufPrint(&self.request_scope, methodToUpper(MethodType) ++ " @ {s}{s}{s}", .{
                if (request.path != null) request.path.? else "",
                if (request.query != null) "?" else "",
                if (request.query != null) request.query.? else "",
            }) catch catch_blk: {
                break :catch_blk bufPrint(
                    &self.request_scope,
                    "{s}{s}...",
                    .{
                        comptime methodToUpper(MethodType) ++ " @ ",
                        if (request.path != null) request.path.?[0..(logger_t.log_t.options.scope_len - min_scope_len)] else "",
                    },
                ) catch unreachable;
            };

            self.request_scope_len = request_scope.len;

            self.logger
                .log(.info)
                .time()
                .scopeFmt("{s}", .{self.request_scope[0..self.request_scope_len]})
                .print("Received request")
                .commit();
        }

        pub fn invalidRequest(self: *OnRequestProcessorType, comptime Status: StatusCode, err: anyerror) void {
            const status_string = comptime comptimePrint(
                "{} {s}",
                .{ @intFromEnum(Status), statusCodeToUpper(Status) },
            );

            var log = self.logger
                .log(.warn)
                .time()
                .scopeFmt("{s}", .{self.request_scope[0..self.request_scope_len]});
            defer log.commit();

            _ = log.printTryFmt("Request is invalid, caused by {s}, responded with " ++ status_string ++ "", .{@errorName(err)}) catch
                log.print("Request is invalid, responded with " ++ status_string);
        }

        pub fn invalidMethod(self: *OnRequestProcessorType, comptime Status: StatusCode) void {
            const status_string = comptime comptimePrint(
                "{} {s}",
                .{ @intFromEnum(Status), statusCodeToUpper(Status) },
            );

            self.logger
                .log(.warn)
                .time()
                .scopeFmt("{s}", .{self.request_scope[0..self.request_scope_len]})
                .print("Request for invalid method, responded with " ++ status_string)
                .commit();
        }

        pub fn invalidParameters(self: *OnRequestProcessorType, comptime Type: ParametersType, comptime Status: StatusCode, err: anyerror) void {
            const status_string = comptime comptimePrint(
                "{} {s}",
                .{ @intFromEnum(Status), statusCodeToUpper(Status) },
            );

            var log = self.logger
                .log(.warn)
                .time()
                .scopeFmt("{s}", .{self.request_scope[0..self.request_scope_len]});
            defer log.commit();

            _ = log.printTryFmt("Request with invalid " ++ Type.toString() ++ "Parameters, caused by {s}, responded with " ++ status_string, .{@errorName(err)}) catch
                log.print("Request with invalid " ++ Type.toString() ++ "Parameters, responded with " ++ status_string);
        }

        pub fn invalidAuthorization(self: *OnRequestProcessorType, comptime Status: StatusCode) void {
            const status_string = comptime comptimePrint(
                "{} {s}",
                .{ @intFromEnum(Status), statusCodeToUpper(Status) },
            );

            self.logger
                .log(.warn)
                .time()
                .scopeFmt("{s}", .{self.request_scope[0..self.request_scope_len]})
                .print("Request with invalid authorization, responded with " ++ status_string)
                .commit();
        }

        pub fn controllerError(self: *OnRequestProcessorType, comptime Status: StatusCode, err: anyerror, trace: if (IsDebug) StackTrace else void) void {
            const status_string = comptime comptimePrint(
                "{} {s}",
                .{ @intFromEnum(Status), statusCodeToUpper(Status) },
            );

            var log = self.logger
                .log(.err)
                .time()
                .scopeFmt("{s}", .{self.request_scope[0..self.request_scope_len]});
            defer log.commit();

            _ = log.printTryFmt("Failed to handle request, caused by {s}, responded with " ++ status_string, .{@errorName(err)}) catch
                log.print("Failed to handle request, responded with " ++ status_string);

            if (comptime IsDebug)
                _ = log.trace(trace);
        }

        pub fn setHeadersError(self: *OnRequestProcessorType, comptime Status: StatusCode, err: anyerror, trace: if (IsDebug) StackTrace else void) void {
            const status_string = comptime comptimePrint(
                "{} {s}",
                .{ @intFromEnum(Status), statusCodeToUpper(Status) },
            );

            var log = self.logger
                .log(.err)
                .time()
                .scopeFmt("{s}", .{self.request_scope[0..self.request_scope_len]});
            defer log.commit();

            _ = log.printTryFmt("Failed to set headers, caused by {s}, responded with " ++ status_string, .{@errorName(err)}) catch
                log.print("Failed to set headers, responded with " ++ status_string);

            if (comptime IsDebug)
                _ = log.trace(trace);
        }

        pub fn sendBodyError(self: *OnRequestProcessorType, comptime Status: StatusCode, err: anyerror, trace: if (IsDebug) StackTrace else void) void {
            const status_string = comptime comptimePrint(
                "{} {s}",
                .{ @intFromEnum(Status), statusCodeToUpper(Status) },
            );

            var log = self.logger
                .log(.err)
                .time()
                .scopeFmt("{s}", .{self.request_scope[0..self.request_scope_len]});
            defer log.commit();

            _ = log.printTryFmt("Failed to send body, caused by {s}, responded with " ++ status_string, .{@errorName(err)}) catch
                log.print("Failed to send body, responded with " ++ status_string);

            if (comptime IsDebug)
                _ = log.trace(trace);
        }

        pub fn redirectError(self: *OnRequestProcessorType, comptime Status: StatusCode, err: anyerror, trace: if (IsDebug) StackTrace else void) void {
            const status_string = comptime comptimePrint(
                "{} {s}",
                .{ @intFromEnum(Status), statusCodeToUpper(Status) },
            );

            var log = self.logger
                .log(.err)
                .time()
                .scopeFmt("{s}", .{self.request_scope[0..self.request_scope_len]});
            defer log.commit();

            _ = log.printTryFmt("Failed to redirect, caused by {s}, responded with " ++ status_string, .{@errorName(err)}) catch
                log.print("Failed to redirect, responded with " ++ status_string);

            if (comptime IsDebug)
                _ = log.trace(trace);
        }

        pub fn matchStatusCodeToResultCrash(self: *OnRequestProcessorType, comptime Type: ResultType, err: anyerror) void {
            var log = self.logger
                .log(.fatal)
                .time()
                .scopeFmt("{s}", .{self.request_scope[0..self.request_scope_len]});
            defer log.commit();

            _ = log.printTryFmt("Server crashed when trying to match status code to " ++ Type.toString() ++ "Result, caused by {s}", .{@errorName(err)}) catch
                log.print("Server crashed when trying to match status code to " ++ Type.toString() ++ "Result");
        }

        pub fn resultCompositionCrash(self: *OnRequestProcessorType, err: anyerror) void {
            var log = self.logger
                .log(.fatal)
                .time()
                .scopeFmt("{s}", .{self.request_scope[0..self.request_scope_len]});
            defer log.commit();

            _ = log.printTryFmt("Server crashed when trying to compose result, caused by {s}", .{@errorName(err)}) catch
                log.print("Server crashed when trying to compose result");
        }

        pub fn formatResultCrash(self: *OnRequestProcessorType, comptime Type: ResultType, err: anyerror) void {
            var log = self.logger
                .log(.fatal)
                .time()
                .scopeFmt("{s}", .{self.request_scope[0..self.request_scope_len]});
            defer log.commit();

            _ = log.printTryFmt("Server crashed when trying to format " ++ Type.toString() ++ "Result, caused by {s}", .{@errorName(err)}) catch
                log.print("Server crashed when trying to format " ++ Type.toString() ++ "Result");
        }

        pub fn readFileCrash(self: *OnRequestProcessorType, err: anyerror) void {
            var log = self.logger
                .log(.fatal)
                .time()
                .scopeFmt("{s}", .{self.request_scope[0..self.request_scope_len]});
            defer log.commit();

            _ = log.printTryFmt("Server crashed when trying to read file, caused by {s}", .{@errorName(err)}) catch
                log.print("Server crashed when trying to read file");
        }

        pub fn success(self: *OnRequestProcessorType, status: StatusCode) void {
            assert(isStatusCodeSuccess(status));

            const elapsed_time: u64 = self.timer.lap() / 1_000_000;

            var log = self.logger
                .log(.success)
                .time()
                .scopeFmt("{s}", .{self.request_scope[0..self.request_scope_len]});
            defer log.commit();

            var status_buffer: [status_code.max_value_len]u8 = undefined;
            var writer = Writer.fixed(&status_buffer);

            statusCodeFormat(status, &writer) catch unreachable;

            _ = log.printTryFmt("Request handeled succesfully in {}ms, responded with {} {s}", .{
                elapsed_time,
                @intFromEnum(status),
                writer.buffered(),
            }) catch
                log.print("Request handeled succesfully");
        }

        pub fn redirect(self: *OnRequestProcessorType, status: StatusCode) void {
            assert(isStatusCodeRedirect(status));

            const elapsed_time: u64 = self.timer.lap() / 1_000_000;

            var log = self.logger
                .log(.success)
                .time()
                .scopeFmt("{s}", .{self.request_scope[0..self.request_scope_len]});
            defer log.commit();

            var status_buffer: [status_code.max_value_len]u8 = undefined;
            var writer = Writer.fixed(&status_buffer);

            statusCodeFormat(status, &writer) catch unreachable;

            _ = log.printTryFmt("Request redirected in {}ms, responded with {} {s}", .{
                elapsed_time,
                @intFromEnum(status),
                writer.buffered(),
            }) catch
                log.print("Request redirected");
        }

        pub fn deinit(_: *OnRequestProcessorType) void {}
    };
}
