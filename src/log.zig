/// STD
const std = @import("std");

const assert = std.debug.assert;
const comptimePrint = std.fmt.comptimePrint;

const Allocator = std.mem.Allocator;

const atomic = std.atomic.Value;
const Futex = std.Thread.Futex;

const indexOfScalarPos = std.mem.indexOfScalarPos;

/// Aura
pub const log = @This();
const core = @import("root.zig");

const Enviroment = core.utils.Environment;

/// Third Party
const zeit = @import("zeit");

const TimeZone = zeit.TimeZone;
const Instant = zeit.Instant;

pub const State = enum(u8) {
    empty,
    reserved,
    constructed,
    collected,
};

pub const Level = enum {
    debug,
    info,
    warn,
    err,
    fatal,
};

pub const LoggerOptions = struct {
    /// Amount of logs which can Logger handle.
    log_pool_size: u32 = 16,
};

pub const LogOptions = struct {
    /// How long can Log scope string be?
    scope_len: usize = 64,
    /// When formated, how long can a Log message string be?
    message_len: usize = 1024,
};

pub const LogFmtOptions = struct {
    /// What formating the whole Log shoud be in?
    /// If placeholder is '%' followed by lower case character, the argument is not nessesary and will be omitted if not in Log.
    /// If placeholder is '%' followed by upper case character, the argument is nessesary and if not in Log, a "empty argument" will be used.
    /// - '%l' and '%L' is `level`, empty argument is "<NO_LEVEL>"
    /// - '%t' and '%T' is `time`, empty argument is "<NO_TIME>"
    /// - '%c' and '%C' is `scope`, empty argument is "<NO_SCOPE>"
    /// - '%m' and '%M' is `message`, empty argument is "<NO_MESSAGE>"
    /// - '%s' and '%S' is `source_location`, empty argument is "<NO_SOURCE>"
    fmt: []const u8 = "%L%t%c%m%s",
    /// If formated, what format should the `level` be in?
    /// - '%l' is `level` in lower case, like "debug"
    /// - '%L' is `level` in upper case, like "DEBUG"
    level_fmt: []const u8 = "[%L]",
    /// If formated, what format should the `time` be in?
    /// See: https://rockorager.github.io/zeit/#zeit.Time.strftime
    time_fmt: []const u8 = " [%d.%m.%Y %H:%M:%S]",
    /// If formated, what format should the `scope` be in?
    /// - '%s' is `scope`
    scope_fmt: []const u8 = " (%s):",
    /// If formated, what format should the `message` be in?
    /// - '%m' is `message`
    message_fmt: []const u8 = " %m",
    /// If formated, what format should the `source_location` be in?
    /// - '%m' is `module`
    /// - '%F' is `file`
    /// - '%f' is `fn_name`
    /// - '%l' is `line`
    /// - '%c' is `column`
    source_location_fmt: []const u8 = " in file '%F' line %l",
};

/// Multi-thread safe, statically sized Logger
///
/// - To log call `log`, which will return a pointer to reserved Log. Make sure you call `commit` or `rollback` on it
///   after, otherwise the Log will be pernamently reserved in `log_pool`, exhausting it.
/// - Requesting Log when `log_pool` has been exhausted will lead to blocking of requesting thread. Ensure that `Options.log_pool_size` is set
///   appropriately to the amount of threads utilizing this Logger, frequency of Log requests and compexity of Log processing.
/// - LogProcessor handles the processing of collected Logs. It must be a type which contains method `init` and methode for
///   Log processing `processLog`.
pub fn Logger(comptime LogType: type, comptime LogProcessorType: type, comptime Options: LoggerOptions) type {
    return struct {
        const LoggerType = Logger(LogType, LogProcessorType, Options);

        thread_running: atomic(bool),
        thread: ?std.Thread,

        uncollected: atomic(u32),

        log_pool: ?[Options.log_pool_size]LogType,
        reserve_index: ?atomic(u32),

        log_processor: LogProcessorType,

        /// Initialize Logger
        ///
        /// Logger doesn't keep `enviroment`, it's passed to LogProcessor
        pub fn init(self: *LoggerType, enviroment: *Enviroment) void {
            self.thread_running = atomic(bool).init(false);
            self.thread = null;

            self.uncollected = atomic(u32).init(0);

            self.log_pool = null;
            self.reserve_index = null;

            self.log_processor.init(enviroment);
        }

        /// Spawn collecting thread and sync with it
        ///
        /// MUST CALL `join` after
        pub fn spawn(self: *LoggerType) !void {
            assert(!self.thread_running.load(.acquire));
            assert(self.thread == null);
            assert(self.log_pool == null);
            assert(self.reserve_index == null);

            self.thread = try std.Thread.spawn(
                .{},
                _collect,
                .{self},
            );

            // Waiting for collecting thread to initialize it's stack
            Futex.wait(&self.uncollected, 0);
        }

        /// Initialize collecting thread stack and start collecting loop
        ///
        /// DO NOT CALL, internal use only
        fn _collect(self: *LoggerType) void {
            assert(!self.thread_running.load(.acquire));
            assert(self.thread != null);
            assert(self.log_pool == null);
            assert(self.reserve_index == null);

            // Initialize stack of collecting thread
            self.thread_running.store(true, .release);

            self.log_pool = undefined;
            for (&self.log_pool.?) |*log_request| {
                log_request.* = LogType.init(self);
            }
            defer self.log_pool = null;

            self.reserve_index = atomic(u32).init(0);
            defer self.reserve_index = null;

            // Waking spawning thread waiting for collecting thread initialization
            Futex.wake(&self.uncollected, 1);

            // Collecting loop
            while (self.thread_running.load(.acquire) or self.uncollected.load(.acquire) != 0) {
                Futex.wait(&self.uncollected, 0);

                for (&self.log_pool.?) |*log_request| {
                    _ = @cmpxchgWeak(
                        State,
                        &log_request.state.raw,
                        .constructed,
                        .collected,
                        .acq_rel,
                        .acquire,
                    ) orelse {
                        self.log_processor.processLog(log_request);

                        log_request.level = null;
                        log_request.instant = null;
                        log_request.context = null;
                        log_request.context_len = null;
                        log_request.message = null;
                        log_request.message_len = null;
                        log_request.source_location = null;

                        log_request.state.store(.empty, .release);
                        _ = self.uncollected.fetchSub(1, .release);
                        Futex.wake(&self.uncollected, std.math.maxInt(u32));
                        if (self.uncollected.load(.acquire) == 0) break;
                    };
                }
            }
        }

        /// Join collecting thread
        pub fn join(self: *LoggerType) void {
            assert(self.thread_running.load(.acquire));
            assert(self.thread != null);
            assert(self.log_pool != null);
            assert(self.reserve_index != null);

            self.thread_running.store(false, .release);
            Futex.wake(&self.uncollected, 1);
            self.thread.?.join();

            self.thread = null;
        }

        /// Reserve Log with a `Level` in `log_pool`
        ///
        /// MUST CALL `Log.commit` or `Log.rollback` on the result
        pub fn log(self: *LoggerType, comptime LogLevel: Level) *LogType {
            assert(self.thread_running.load(.acquire));
            assert(self.thread != null);
            assert(self.log_pool != null);
            assert(self.reserve_index != null);

            while (true) {
                Futex.wait(&self.uncollected, Options.log_pool_size);

                _ = @cmpxchgWeak(
                    u32,
                    &self.reserve_index.?.raw,
                    Options.log_pool_size,
                    0,
                    .acq_rel,
                    .acquire,
                );
                _ = @cmpxchgWeak(
                    State,
                    &self.log_pool.?[self.reserve_index.?.load(.acquire)].state.raw,
                    .empty,
                    .reserved,
                    .acq_rel,
                    .acquire,
                ) orelse {
                    const reserved = &self.log_pool.?[self.reserve_index.?.load(.acquire)];
                    _ = self.reserve_index.?.fetchAdd(1, .release);
                    reserved.level = LogLevel;
                    return reserved;
                };
            }
        }

        /// Increments the `uncollected` counter and awakes collecting thread waiting
        ///
        /// DO NOT CALL, used by Log to signal it's ready for collecting, independently on LoggerType
        fn _incrUncollected(self: *LoggerType) void {
            _ = self.uncollected.fetchAdd(1, .release);
            Futex.wake(&self.uncollected, 1);
        }
    };
}

/// Statically sized Log
///
/// - Log allows construction chaining (except of `printTryFmt`).
/// - Must call `commit` to set Log for collecting or `rollback` to set Log for reserving.
/// - Exceeding `Options.message_len` by length of message formated in `printFmt` will cause panic. Therefore, if you are
///   unsure about lenght of formated message use `printTryFmt` and `catch` the result. If error is caught when calling `printTryFmt`,
///   the Log on which it was called IS STILL RESERVED in `log_pool` make sure it's properly commited or rolled-back.
/// - Log can be used by any Logger type which has opaque methode `_incrUncollected`.
pub fn Log(comptime Options: LogOptions) type {
    return struct {
        const LogType = Log(Options);

        state: atomic(State),
        logger: *anyopaque,
        incr_uncollected_fn_ptr: *const fn (*anyopaque) void,

        level: ?Level,
        instant: ?Instant,
        context: ?[Options.scope_len]u8,
        context_len: ?usize,
        message: ?[Options.message_len]u8,
        message_len: ?usize,
        source_location: ?std.builtin.SourceLocation,

        /// Initialize Log
        pub fn init(logger: anytype) LogType {
            const LoggerType = @TypeOf(logger);
            const Gen = struct {
                fn incrUncollected(ptr: *anyopaque) void {
                    const self: LoggerType = @ptrCast(@alignCast(ptr));
                    self._incrUncollected();
                }
            };

            return .{
                .state = atomic(State).init(.empty),
                .logger = logger,
                .incr_uncollected_fn_ptr = Gen.incrUncollected,
                .level = null,
                .instant = null,
                .context = null,
                .context_len = null,
                .message = null,
                .message_len = null,
                .source_location = null,
            };
        }

        /// Sets instant
        ///
        /// Processing of time is done by Logger, this function simply stamps the time in UTC
        pub fn time(self: *LogType) *LogType {
            self.instant = zeit.instant(.{}) catch unreachable;
            return self;
        }

        /// Sets scope
        pub fn scope(self: *LogType, comptime Scope: []const u8) *LogType {
            comptime if (Options.scope_len < Scope.len)
                @compileError(comptimePrint(
                    "Scope.len ({}) is over Options.scope_len ({})",
                    .{
                        Scope.len,
                        Options.scope_len,
                    },
                ));

            self.context = undefined;
            std.mem.copyForwards(u8, &self.context.?, Scope);
            self.context_len = Scope.len;
            return self;
        }

        /// Sets message
        pub fn print(self: *LogType, comptime Message: []const u8) *LogType {
            comptime if (Options.message_len < Message.len)
                @compileError(comptimePrint(
                    "Message.len ({}) is over Options.message_len ({})",
                    .{
                        Message.len,
                        Options.message_len,
                    },
                ));

            self.message = undefined;
            std.mem.copyForwards(u8, &self.message.?, Message);
            self.message_len = Message.len;
            return self;
        }

        /// Formats a message and sets it
        ///
        /// If formated message length is over `Options.message_len`, function will cause panic.
        pub fn printFmt(self: *LogType, comptime Fmt: []const u8, args: anytype) *LogType {
            comptime if (Options.message_len < Fmt.len)
                @compileError(comptimePrint(
                    "Fmt.len({}) is over Options.message_len({})",
                    .{
                        Fmt.len,
                        Options.message_len,
                    },
                ));

            self.message = undefined;
            const slice = std.fmt.bufPrint(&self.message.?, Fmt, args) catch
                @panic("Length of formated string exceeded `Options.message_len`");
            self.message_len = slice.len;
            return self;
        }

        /// Formats a message and sets it
        ///
        /// If formated message length is over `Options.message_len`, function will return BufPrintError.
        /// If this function returns an error, the Log is still reserved.
        pub fn printTryFmt(self: *LogType, comptime Fmt: []const u8, args: anytype) !*LogType {
            comptime if (Options.message_len < Fmt.len)
                @compileError(comptimePrint(
                    "Fmt.len({}) is over Options.message_len({})",
                    .{
                        Fmt.len,
                        Options.message_len,
                    },
                ));

            self.message = undefined;
            const slice = try std.fmt.bufPrint(&self.message.?, Fmt, args);
            self.message_len = slice.len;
            return self;
        }

        /// Sets source location
        pub fn src(self: *LogType, source_location: std.builtin.SourceLocation) *LogType {
            self.source_location = source_location;
            return self;
        }

        /// Commits Log for collection
        pub fn commit(self: *LogType) void {
            self.state.store(.constructed, .release);
            self.incr_uncollected_fn_ptr(self.logger);
        }

        /// Rolls-back any changes to Log and sets it for reserving
        pub fn rollback(self: *LogType) void {
            self.level = null;
            self.instant = null;
            self.context = null;
            self.context_len = null;
            self.message = null;
            self.message_len = null;
            self.source_location = null;
            self.state.store(.empty, .release);
        }
    };
}

/// Formating functions for Log
pub fn LogFmt(comptime LogType: type, comptime Options: LogFmtOptions) type {
    return struct {
        /// Writes `Log.level` to `writer` based on `Options.level_fmt`
        pub fn levelFmt(arg: *const LogType, writer: *std.Io.Writer) !void {
            assert(arg.*.level != null);

            const delimiter_index = comptime indexOfScalarPos(
                u8,
                Options.level_fmt,
                0,
                '%',
            ) orelse
                @compileError("No '%' in `Options.level_fmt`");
            comptime if (delimiter_index + 1 >= Options.level_fmt.len)
                @compileError("`Options.level_fmt` doesn't contain placeholder");
            const placeholder = Options.level_fmt[delimiter_index + 1];

            if (comptime delimiter_index > 0)
                try writer.writeAll(Options.level_fmt[0..delimiter_index]);

            switch (placeholder) {
                inline 'l' => try writer.writeAll(@tagName(arg.*.level.?)),
                inline 'L' => {
                    switch (arg.*.level.?) {
                        .debug => try writer.writeAll("DEBUG"),
                        .info => try writer.writeAll("INFO"),
                        .warn => try writer.writeAll("WARN"),
                        .err => try writer.writeAll("ERROR"),
                        .fatal => try writer.writeAll("FATAL"),
                    }
                },
                inline else => @compileError("`Options.level_fmt` doesn't contain valid placeholder"),
            }

            if (comptime delimiter_index + 2 < Options.level_fmt.len)
                try writer.writeAll(Options.level_fmt[(delimiter_index + 2)..]);
        }

        /// Writes `Log.instant` converted to time based on `timezone`, to `writer` based on `Options.time_fmt`
        pub fn timeFmt(arg: *const LogType, writer: *std.Io.Writer, timezone: *const TimeZone) !void {
            assert(arg.*.instant != null);

            const time = arg.*.instant.?.in(timezone).time();
            try time.strftime(writer, Options.time_fmt);
        }

        /// Writes `Log.context` to `writer` based on `Options.scope_fmt`
        pub fn scopeFmt(arg: *const LogType, writer: *std.Io.Writer) !void {
            assert(arg.*.context != null);
            assert(arg.*.context_len != null);

            const delimiter_index = comptime indexOfScalarPos(
                u8,
                Options.scope_fmt,
                0,
                '%',
            ) orelse
                @compileError("No '%' in `Options.scope_fmt`");
            comptime if (delimiter_index + 1 >= Options.scope_fmt.len)
                @compileError("`Options.scope_fmt` doesn't contain placeholder");
            const placeholder = Options.scope_fmt[delimiter_index + 1];

            if (comptime delimiter_index > 0)
                try writer.writeAll(Options.scope_fmt[0..delimiter_index]);

            if (comptime placeholder == 's')
                try writer.writeAll(arg.*.context.?[0..arg.*.context_len.?])
            else
                @compileError("`Options.scope_fmt` doesn't contain valid placeholder");

            if (comptime delimiter_index + 2 < Options.scope_fmt.len)
                try writer.writeAll(Options.scope_fmt[(delimiter_index + 2)..]);
        }

        /// Writes `Log.message` to `writer` based on `Options.message_fmt`
        pub fn messageFmt(arg: *const LogType, writer: *std.Io.Writer) !void {
            assert(arg.*.message != null);
            assert(arg.*.message_len != null);

            const delimiter_index = comptime indexOfScalarPos(
                u8,
                Options.message_fmt,
                0,
                '%',
            ) orelse
                @compileError("No '%' in `Options.message_fmt`");
            comptime if (delimiter_index + 1 >= Options.scope_fmt.len)
                @compileError("`Options.message_fmt` doesn't contain placeholder");
            const placeholder = Options.message_fmt[delimiter_index + 1];

            if (comptime delimiter_index > 0)
                try writer.writeAll(Options.message_fmt[0..delimiter_index]);

            if (comptime placeholder == 'm')
                try writer.writeAll(arg.*.message.?[0..arg.*.message_len.?])
            else
                @compileError("`Options.message_fmt` doesn't contain valid placeholder");

            if (comptime delimiter_index + 2 < Options.message_fmt.len)
                try writer.writeAll(Options.message_fmt[(delimiter_index + 2)..]);
        }

        /// Writes `Log.source_location` to `writer` based on `Options.source_location_fmt`
        pub fn sourceLocationFmt(arg: *const LogType, writer: *std.Io.Writer) !void {
            assert(arg.*.source_location != null);
            comptime var origin_point: usize = 0;

            inline while (true) {
                const delimiter_index: usize = comptime indexOfScalarPos(
                    u8,
                    Options.source_location_fmt,
                    origin_point,
                    '%',
                ) orelse break;
                comptime if (delimiter_index + 1 >= Options.source_location_fmt.len)
                    @compileError("`Options.source_location_fmt` doesn't contain one placeholder");
                const placeholder = Options.source_location_fmt[delimiter_index + 1];

                if (comptime delimiter_index > origin_point)
                    try writer.writeAll(Options.source_location_fmt[origin_point..delimiter_index]);

                switch (placeholder) {
                    inline 'm' => try writer.writeAll(arg.*.source_location.?.module),
                    inline 'F' => try writer.writeAll(arg.*.source_location.?.file),
                    inline 'f' => try writer.writeAll(arg.*.source_location.?.fn_name),
                    inline 'l' => try writer.print("{}", .{arg.*.source_location.?.line}),
                    inline 'c' => try writer.print("{}", .{arg.*.source_location.?.column}),
                    inline else => @compileError("`Options.source_location_fmt` contains invalid placeholder"),
                }

                origin_point = delimiter_index + 2;
            }

            comptime if (origin_point == 0)
                @compileError("No '%' in `Options.source_location_fmt`");

            if (comptime origin_point < Options.source_location_fmt.len)
                try writer.writeAll(Options.source_location_fmt[origin_point..]);
        }

        /// Writes formated Log to `writer` based on `Options.fmt`
        pub fn fmt(arg: *const LogType, writer: *std.Io.Writer, timezone: *const TimeZone) !void {
            comptime var origin_point: usize = 0;

            inline while (true) {
                const delimiter_index: usize = comptime indexOfScalarPos(
                    u8,
                    Options.fmt,
                    origin_point,
                    '%',
                ) orelse break;
                comptime if (delimiter_index + 1 >= Options.fmt.len)
                    @compileError("`Options.fmt` doesn't contain one placeholder");
                const placeholder = Options.fmt[delimiter_index + 1];

                if (comptime delimiter_index > origin_point)
                    try writer.writeAll(Options.fmt[origin_point..delimiter_index]);

                switch (placeholder) {
                    inline 'l' => if (arg.level != null) try levelFmt(arg, writer),
                    inline 'L' => if (arg.level != null) try levelFmt(arg, writer) else try writer.writeAll("<NO_LEVEL>"),
                    inline 't' => if (arg.instant != null) try timeFmt(arg, writer, timezone),
                    inline 'T' => if (arg.instant != null) try timeFmt(arg, writer, timezone) else try writer.writeAll("<NO_TIME>"),
                    inline 'c' => if (arg.context != null) try scopeFmt(arg, writer),
                    inline 'C' => if (arg.context != null) try scopeFmt(arg, writer) else try writer.writeAll("<NO_SCOPE>"),
                    inline 'm' => if (arg.message != null) try messageFmt(arg, writer),
                    inline 'M' => if (arg.message != null) try messageFmt(arg, writer) else try writer.writeAll("<NO_MESSAGE>"),
                    inline 's' => if (arg.source_location != null) try sourceLocationFmt(arg, writer),
                    inline 'S' => if (arg.source_location != null) try sourceLocationFmt(arg, writer) else try writer.writeAll("<NO_SOURCE>"),
                    inline else => @compileError("`Options.fmt` contains invalid placeholder"),
                }

                origin_point = delimiter_index + 2;
            }

            comptime if (origin_point == 0)
                @compileError("No '%' in `Options.fmt`");

            if (comptime origin_point < Options.fmt.len)
                try writer.writeAll(Options.fmt[origin_point..]);
        }
    };
}

/// LogProcessor for writing out Logs into console
pub fn ConsoleLogProcessor(comptime LogType: type, comptime Options: LogFmtOptions) type {
    return struct {
        const LogProcessorType = ConsoleLogProcessor(LogType, Options);

        timezone: *const TimeZone,
        buffer: [5_000]u8,
        out_writer: std.fs.File.Writer,

        /// Initialize ConsoleLogProcessor
        ///
        /// `enviroment.time_zone` is required, NEVER pass null
        pub fn init(self: *LogProcessorType, enviroment: *Enviroment) void {
            assert(enviroment.time_zone != null);

            self.timezone = &enviroment.time_zone.?;
            self.out_writer = std.fs.File.stdout().writer(&self.buffer);
        }

        /// Process Log
        pub fn processLog(
            self: *LogProcessorType,
            processed_log: *const LogType,
        ) void {
            LogFmt(LogType, Options).fmt(
                processed_log,
                &self.out_writer.interface,
                self.timezone,
            ) catch |err| {
                self.out_writer.interface.print("\n\n<LOG_PRINT_ERROR>\nCause: {s}\n\n", .{@errorName(err)}) catch
                    @panic("Error occured during printing to the console");
            };
            self.out_writer.interface.flush() catch
                @panic("Error occured during console buffer flushing");
        }
    };
}
