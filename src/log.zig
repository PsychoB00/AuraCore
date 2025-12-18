/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;
const atomic = std.atomic.Value;
const Futex = std.Thread.Futex;
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;
const SourceLocation = std.builtin.SourceLocation;

const assert = std.debug.assert;
const hasMethod = std.meta.hasMethod;
const comptimePrint = std.fmt.comptimePrint;
const copyForwards = std.mem.copyForwards;
const bufPrint = std.fmt.bufPrint;
const isLower = std.ascii.isLower;
const toUpper = std.ascii.toUpper;

/// Aura
const core = @import("core.zig");

const Enviroment = core.context.Environment;

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
    /// When formated, how many bytes can Log scope string be?
    scope_len: usize = 64,
    /// When formated, how many bytes can Log message string be?
    message_len: usize = 1_024,
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
    fmt: []const u8 = "%L%t%c%m%s\n",
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

    pub fn isValid(self: LogFmtOptions) !void {
        try _hasFmtValidPlaceholdersCaseExclusive("ltcms", self.fmt);
        try _hasFmtValidPlaceholdersCaseExclusive("l", self.level_fmt);
        try _hasFmtValidPlaceholders("aAbBcCdDeFfGgHhIjklMmmOPpRrSsTtUuVWwXxYyZz%", self.scope_fmt);
        try _hasFmtValidPlaceholders("s", self.scope_fmt);
        try _hasFmtValidPlaceholders("m", self.message_fmt);
        try _hasFmtValidPlaceholders("mFflc", self.source_location_fmt);
    }

    /// Checks if `fmt` has at least one placeholder defined in `valid_placeholders` and placeholders aren't duplicit
    fn _hasFmtValidPlaceholders(comptime valid_placeholders: []const u8, fmt: []const u8) !void {
        var placeholder_check_array = [1]bool{false} ** valid_placeholders.len;

        if (fmt.len == 0)
            return error.FmtTooShort;

        var validate_placeholder: bool = false;

        for (fmt) |character| fmt_loop: {
            if (validate_placeholder) {
                inline for (valid_placeholders, 0..) |placeholder, index| placeholder_loop: {
                    if (character != placeholder)
                        break :placeholder_loop;

                    if (placeholder_check_array[index])
                        return error.DuplicatePlaceholder;

                    validate_placeholder = false;
                    placeholder_check_array[index] = true;
                    break :fmt_loop;
                }

                return error.InvalidPlaceholder;
            }

            if (character == '%')
                validate_placeholder = true;
        }

        inline for (placeholder_check_array) |check| {
            if (check)
                return;
        }

        return error.MissingPlaceholder;
    }

    /// Checks if `fmt` has at least one placeholder (upper or lower) defined in `valid_placeholders` and placeholders aren't duplicit
    fn _hasFmtValidPlaceholdersCaseExclusive(comptime valid_placeholders: []const u8, fmt: []const u8) !void {
        var placeholder_check_array = [1]bool{false} ** valid_placeholders.len;

        if (fmt.len == 0)
            return error.FmtTooShort;

        var validate_placeholder: bool = false;

        for (fmt) |character| fmt_loop: {
            if (validate_placeholder) {
                inline for (valid_placeholders, 0..) |placeholder, index| placeholder_loop: {
                    comptime if (!isLower(placeholder))
                        @compileError("Valid placeholder must be lowercase");

                    if (character != placeholder and character != comptime toUpper(placeholder))
                        break :placeholder_loop;

                    if (placeholder_check_array[index])
                        return error.DuplicatePlaceholder;

                    validate_placeholder = false;
                    placeholder_check_array[index] = true;
                    break :fmt_loop;
                }

                return error.InvalidPlaceholder;
            }

            if (character == '%')
                validate_placeholder = true;
        }

        inline for (placeholder_check_array) |check| {
            if (check)
                return;
        }

        return error.MissingPlaceholder;
    }
};

/// Multi-thread safe, statically sized Logger
///
/// - To log call `log`, which will return a pointer to reserved Log. Make sure you call `commit` or `rollback` on it
///   after, otherwise the Log will be pernamently reserved in `log_pool`, exhausting it.
/// - Requesting Log when `log_pool` has been exhausted will lead to blocking of requesting thread. Ensure that `Options.log_pool_size` is set
///   appropriately to the amount of threads utilizing this Logger, frequency of Log requests and compexity of Log processing.
/// - `LogProcessor` handles the processing of collected Logs. It must fullfill the 'isLogProcessor' trait check.
pub fn Logger(comptime LogType: type, comptime LogProcessorType: type, comptime Options: LoggerOptions) type {
    // `LogType` validation
    if (!isLog(LogType))
        @compileError("`LogType` must be Log");

    // `LogProcessorType` validation
    if (!isLogProcessor(LogProcessorType))
        @compileError("`LogProcessorType` must be isLogProcessor");

    // `Options` validation
    if (Options.log_pool_size == 0)
        @compileError("`Options.log_pool_size` must be non zero");

    return struct {
        const LoggerType = @This();
        pub const log_t = LogType;
        pub const log_processor_t = LogProcessorType;
        pub const options = Options;

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

            self.uncollected.store(1, .release);
            self.thread = try std.Thread.spawn(
                .{},
                _collect,
                .{self},
            );

            // Waiting for collecting thread to initialize it's stack
            Futex.wait(&self.uncollected, 1);
        }

        /// Initialize collecting thread stack and start collecting loop
        ///
        /// DO NOT CALL, internal use only
        fn _collect(self: *LoggerType) void {
            assert(!self.thread_running.load(.acquire));

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
            self.uncollected.store(0, .release);

            // Collecting loop
            while (self.thread_running.load(.acquire) or self.uncollected.load(.acquire) != 0) {
                Futex.wait(&self.uncollected, 0);

                for (&self.log_pool.?) |*log_request| {
                    if (self.uncollected.load(.acquire) == 0) break;

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

/// Trait check for Logger
///
/// - `Type` must be struct
/// - `Type` must have declaration for self named "LoggerType"
///     - `LoggerType` must be declaration of type which is the same as `Type`
/// - `Type` must have declaration for type of Log which it uses, named "log_t"
///     - `log_t` must be declaration of a type
///     - `log_t` must fulfill trait check `isLog`
/// - `Type` must have declaration for type of LogProcessor which it uses, named "log_processor_t"
///     - `log_processor_t` must be declaration of a type
///     - `log_processor_t` must fulfill trait check `isLogProcessor`
/// - `Type` must have declaration of its options named "options"
///     - `options` must be declaration of LoggerOptions
/// - `Type` must be able to generate `Type` using its declarations and function Logger
pub fn isLogger(comptime Type: type) bool {
    const is_struct = @typeInfo(Type) == .@"struct";

    const has_logger_type =
        @hasDecl(Type, "LoggerType") and
        @TypeOf(Type.LoggerType) == type and
        Type.LoggerType == Type;

    const has_log_type =
        @hasDecl(Type, "log_t") and
        @TypeOf(Type.log_t) == type and
        isLog(Type.log_t);

    const has_log_processor_type =
        @hasDecl(Type, "log_processor_t") and
        @TypeOf(Type.log_processor_t) == type and
        isLogProcessor(Type.log_processor_t);

    const has_options =
        @hasDecl(Type, "options") and
        @TypeOf(Type.options) == LoggerOptions;

    const can_generate_self =
        has_log_type and has_options and has_log_processor_type and
        Logger(Type.log_t, Type.log_processor_t, Type.options) == Type;

    return is_struct and has_logger_type and has_log_type and has_log_processor_type and has_options and can_generate_self;
}

/// Statically sized Log
///
/// - Log allows construction chaining (except of `printTryFmt` and `scopeTryFmt`).
/// - Must call `commit` to set Log for collecting or `rollback` to set Log for reserving.
/// - Exceeding `Options.message_len` or `Options.scope_len` by length of string formated in `printFmt` and `scopeFmt`, respective,
///   will cause panic. Therefore, if you are unsure about lenght of formated string use try versions of the functions and
///   `catch` the result. If error is caught when calling respective dunctions, the Log on which it was called on IS STILL RESERVED
///   in `log_pool` make sure it's properly commited or rolled-back.
/// - Log can be used by any Logger type which has opaque methode `_incrUncollected`.
pub fn Log(comptime Options: LogOptions) type {
    return struct {
        const LogType = @This();
        pub const options = Options;

        state: atomic(State),
        logger: *anyopaque,
        incr_uncollected_fn_ptr: *const fn (*anyopaque) void,

        level: ?Level,
        instant: ?Instant,
        context: ?[Options.scope_len]u8,
        context_len: ?usize,
        message: ?[Options.message_len]u8,
        message_len: ?usize,
        source_location: ?SourceLocation,

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
            copyForwards(u8, &self.context.?, Scope);
            self.context_len = Scope.len;
            return self;
        }

        /// Formats a scope and sets it
        ///
        /// If formated scope length is over `Options.scope_len`, function will cause panic.
        pub fn scopeFmt(self: *LogType, comptime Fmt: []const u8, args: anytype) *LogType {
            comptime if (Options.scope_len < Fmt.len)
                @compileError(comptimePrint(
                    "Fmt.len({}) is over Options.scope_len({})",
                    .{
                        Fmt.len,
                        Options.scope_len,
                    },
                ));

            self.context = undefined;
            const slice = bufPrint(&self.context.?, Fmt, args) catch
                @panic("Length of formated string exceeded `Options.scope_len`");
            self.context_len = slice.len;
            return self;
        }

        /// Formats a scope and sets it
        ///
        /// If formated scope length is over `Options.scope_len`, function will return BufPrintError.
        /// If this function returns an error, the Log is still reserved.
        pub fn scopeTryFmt(self: *LogType, comptime Fmt: []const u8, args: anytype) !*LogType {
            comptime if (Options.scope_len < Fmt.len)
                @compileError(comptimePrint(
                    "Fmt.len({}) is over Options.scope_len({})",
                    .{
                        Fmt.len,
                        Options.scope_len,
                    },
                ));

            self.context = undefined;
            const slice = try bufPrint(&self.context.?, Fmt, args);
            self.context_len = slice.len;
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
            copyForwards(u8, &self.message.?, Message);
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
            const slice = bufPrint(&self.message.?, Fmt, args) catch
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
            const slice = try bufPrint(&self.message.?, Fmt, args);
            self.message_len = slice.len;
            return self;
        }

        /// Sets source location
        pub fn src(self: *LogType, source_location: SourceLocation) *LogType {
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

/// Trait check for Log
///
/// - `Type` must be struct
/// - `Type` must have declaration for self named "LogType"
///     - `LogType` must be declaration of type which is the same as `Type`
/// - `Type` must have declaration of its options named "options"
///     - `options` must be declaration of LogOptions
/// - `Type` must be able to generate `Type` using its declarations and function Log
pub fn isLog(comptime Type: type) bool {
    const is_struct = @typeInfo(Type) == .@"struct";

    const has_log_type =
        @hasDecl(Type, "LogType") and
        @TypeOf(Type.LogType) == type and
        Type.LogType == Type;

    const has_options =
        @hasDecl(Type, "options") and
        @TypeOf(Type.options) == LogOptions;

    const can_generate_self =
        has_options and
        Log(Type.options) == Type;

    return is_struct and has_log_type and has_options and can_generate_self;
}

/// Formating functions for Log
pub fn LogFmt(comptime LogType: type, comptime Options: LogFmtOptions) type {
    // `LogType` validation
    if (!isLog(LogType))
        @compileError("`LogType` must be Log");

    // `Options` validation
    Options.isValid() catch @compileError("`Options` must be valid");

    return struct {
        /// Writes `Log.level` to `writer` based on `Options.level_fmt`
        pub fn levelFmt(arg: *const LogType, writer: *Writer) !void {
            assert(arg.*.level != null);

            comptime var reader = Reader.fixed(Options.level_fmt);

            const level_prefix = comptime try reader.takeDelimiterExclusive('%');
            if (comptime level_prefix.len > 0)
                try writer.writeAll(level_prefix);

            const placeholder = comptime try reader.take(2);

            switch (placeholder[1]) {
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
                inline else => unreachable,
            }

            const level_postfix = comptime try reader.take(reader.bufferedLen());
            if (comptime level_postfix.len > 0)
                try writer.writeAll(level_postfix);
        }

        /// Writes `Log.instant` converted to time based on `timezone`, to `writer` based on `Options.time_fmt`
        pub fn timeFmt(arg: *const LogType, writer: *Writer, timezone: *const TimeZone) !void {
            assert(arg.*.instant != null);

            const time = arg.*.instant.?.in(timezone).time();
            try time.strftime(writer, Options.time_fmt);
        }

        /// Writes `Log.context` to `writer` based on `Options.scope_fmt`
        pub fn scopeFmt(arg: *const LogType, writer: *Writer) !void {
            assert(arg.*.context != null);
            assert(arg.*.context_len != null);

            comptime var reader = Reader.fixed(Options.scope_fmt);

            const scope_prefix = comptime try reader.takeDelimiterExclusive('%');
            if (comptime scope_prefix.len > 0)
                try writer.writeAll(scope_prefix);

            _ = comptime try reader.take(2);

            try writer.writeAll(arg.*.context.?[0..arg.*.context_len.?]);

            const scope_postfix = comptime try reader.take(reader.bufferedLen());
            if (comptime scope_postfix.len > 0)
                try writer.writeAll(scope_postfix);
        }

        /// Writes `Log.message` to `writer` based on `Options.message_fmt`
        pub fn messageFmt(arg: *const LogType, writer: *Writer) !void {
            assert(arg.*.message != null);
            assert(arg.*.message_len != null);

            comptime var reader = Reader.fixed(Options.message_fmt);

            const message_prefix = comptime try reader.takeDelimiterExclusive('%');
            if (comptime message_prefix.len > 0)
                try writer.writeAll(message_prefix);

            _ = comptime try reader.take(2);

            try writer.writeAll(arg.*.message.?[0..arg.*.message_len.?]);

            const message_postfix = comptime try reader.take(reader.bufferedLen());
            if (comptime message_postfix.len > 0)
                try writer.writeAll(message_postfix);
        }

        /// Writes `Log.source_location` to `writer` based on `Options.source_location_fmt`
        pub fn sourceLocationFmt(arg: *const LogType, writer: *Writer) !void {
            assert(arg.*.source_location != null);

            comptime var reader = Reader.fixed(Options.source_location_fmt);

            inline while (true) {
                const source_location_segment = comptime reader.takeDelimiterExclusive('%') catch break;
                if (source_location_segment.len > 0)
                    try writer.writeAll(source_location_segment);

                comptime if (reader.bufferedLen() == 0)
                    break;

                const placeholder = comptime try reader.take(2);

                switch (placeholder[1]) {
                    inline 'm' => try writer.writeAll(arg.*.source_location.?.module),
                    inline 'F' => try writer.writeAll(arg.*.source_location.?.file),
                    inline 'f' => try writer.writeAll(arg.*.source_location.?.fn_name),
                    inline 'l' => try writer.print("{d}", .{arg.*.source_location.?.line}),
                    inline 'c' => try writer.print("{d}", .{arg.*.source_location.?.column}),
                    inline else => unreachable,
                }
            }
        }

        /// Writes formated Log to `writer` based on `Options.fmt`
        pub fn fmt(arg: *const LogType, writer: *Writer, timezone: *const TimeZone) !void {
            comptime var reader = Reader.fixed(Options.fmt);

            inline while (true) {
                const fmt_segment = comptime reader.takeDelimiterExclusive('%') catch break;
                if (fmt_segment.len > 0)
                    try writer.writeAll(fmt_segment);

                comptime if (reader.bufferedLen() == 0)
                    break;

                const placeholder = comptime try reader.take(2);

                switch (placeholder[1]) {
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
                    inline else => unreachable,
                }
            }
        }
    };
}

/// LogProcessor for writing out Logs into console
///
/// If `BufferLen` is null, the size of the console buffer is approximated.
pub fn ConsoleLogProcessor(comptime LogType: type, comptime Options: LogFmtOptions, comptime BufferLen: ?usize) type {
    // `LogType` validation
    if (!isLog(LogType))
        @compileError("`LogType` must be Log");

    // Generated LogProcessor tools
    const Gen = struct {
        fn _getApproximatBufferLen() usize {
            var time_variable_count = 0;
            for (Options.time_fmt) |character| {
                if (character == '%')
                    time_variable_count += 1;
            }

            var source_location_variable_count = 0;
            for (Options.source_location_fmt) |character| {
                if (character == '%')
                    source_location_variable_count += 1;
            }

            return (Options.level_fmt.len + 3) +
                (Options.time_fmt.len + time_variable_count) +
                (Options.scope_fmt.len + LogType.options.scope_len) +
                (Options.message_fmt.len + LogType.options.message_len) +
                (Options.source_location_fmt.len + (source_location_variable_count * 5));
        }
    };

    return struct {
        const LogProcessorType = @This();
        pub const log_t = LogType;

        timezone: *const TimeZone,
        buffer: [BufferLen orelse Gen._getApproximatBufferLen()]u8,
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

/// Trait check for LogProcessor
///
/// - `Type` must be a struct
/// - `Type` must have declaration for type of Log which it uses, named "log_t"
///     - `log_t` must be declaration of a type
///     - `log_t` must fulfill trait check `isLog`
/// - `Type` must have method declaration named "init"
///     - `init` must have function signiture of fn (*Type, *Enviroment) void
/// - `Type` must have method declaration named "processLog"
///     - `processLog` must have function signiture of fn (*Type, *const Type.log_t) void
pub fn isLogProcessor(comptime Type: type) bool {
    const is_struct = @typeInfo(Type) == .@"struct";

    const has_log_type =
        @hasDecl(Type, "log_t") and
        @TypeOf(Type.log_t) == type and
        isLog(Type.log_t);

    const has_init =
        hasMethod(Type, "init") and
        @TypeOf(Type.init) == fn (*Type, *Enviroment) void;

    const has_process_log =
        hasMethod(Type, "processLog") and
        @TypeOf(Type.processLog) == fn (*Type, *const Type.log_t) void;

    return is_struct and has_log_type and has_init and has_process_log;
}
