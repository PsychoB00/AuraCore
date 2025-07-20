/// STD
const std = @import("std");

/// Aura
const log = @import("core").log;

const LoggerOptions = log.LoggerOptions{};
const LogOptions = log.LogOptions{};
const LogFmtOptions = log.LogFmtOptions{};

const Log = log.Log(LogOptions);
const LogProcessor = log.ConsoleLogProcessor(Log, LogFmtOptions);
const Logger = log.Logger(LoggerOptions, Log, LogProcessor);

/// Third Party
const zeit = @import("zeit");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();
    const timezone = try zeit.local(allocator, &env);

    var logger = Logger.init(&timezone);
    try logger.spawn();
    defer logger.join();

    var t1 = try std.Thread.spawn(.{}, run, .{ "thread1", &logger });
    defer t1.join();
    var t2 = try std.Thread.spawn(.{}, run, .{ "thread2", &logger });
    defer t2.join();
    var t3 = try std.Thread.spawn(.{}, run, .{ "thread3", &logger });
    defer t3.join();
    var t4 = try std.Thread.spawn(.{}, run, .{ "thread4", &logger });
    defer t4.join();
}

fn run(name: []const u8, logger: *Logger) void {
    for (0..10) |i| {
        logger.log(.debug).time().scope("TestExe/main").printFmt("{s} has {}", .{ name, i }).src(@src()).commit();
    }
}
