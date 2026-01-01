/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;
const EnvMap = std.process.EnvMap;

const hasMethod = std.meta.hasMethod;

/// Aura
const core = @import("core.zig");

/// Third Party
const zeit = @import("zeit");
const TimeZone = zeit.TimeZone;

/// General structure for holding common Aura variables
pub const Environment = struct {
    allocator: ?Allocator,
    env: ?EnvMap,
    time_zone: ?TimeZone,

    /// Initialize all fields with
    ///
    /// - Local TimeZone
    pub fn initAll(self: *Environment, allocator: Allocator) !void {
        self.allocator = allocator;
        self.env = EnvMap.init(allocator);
        self.time_zone = try zeit.local(allocator, &self.env.?);
    }

    /// Deinitialize any non-null fields
    pub fn deinit(self: *Environment) void {
        if (self.env != null)
            self.env.?.deinit();
        if (self.time_zone != null)
            self.time_zone.?.deinit();
    }
};

/// Trait check for Context
///
/// - `Type` must be struct
/// - `Type` must have declaration for initializing method, named "init"
///     - `init` must have function signiture fn(*Type, Allocator) anyerror!void
/// - `Type` must have declaration for deinitializing method, named "deinit"
///     - `deinit` must have function signiture fn(*Type, Allocator) void
pub fn isContext(comptime Type: type) bool {
    if (@typeInfo(Type) != .@"struct")
        return false;

    const has_init =
        hasMethod(Type, "init") and
        @TypeOf(Type.init) == fn (*Type, Allocator) anyerror!void;

    const has_deinit =
        hasMethod(Type, "deinit") and
        @TypeOf(Type.deinit) == fn (*Type, Allocator) void;

    return has_init and has_deinit;
}

pub fn hasLogger(comptime Type: type) ?type {
    if (!isContext(Type))
        @compileError("`Type` must be a non-tuple struct");

    for (@typeInfo(Type).@"struct".fields) |field| {
        if (core.log.isLogger(field.type))
            return field.type;
    }

    return null;
}

pub fn getLogger(comptime LoggerType: type, context_ptr: anytype) *LoggerType {
    const info = @typeInfo(@TypeOf(context_ptr));
    comptime if (info != .pointer)
        @compileError("`context_ptr` must be a pointer");
    const context_type = info.pointer.child;
    comptime if (!isContext(context_type))
        @compileError("`context_ptr` must point to non-tuple struct");

    inline for (@typeInfo(context_type).@"struct".fields) |field| {
        comptime if (!core.log.isLogger(field.type))
            continue;
        comptime if (LoggerType != field.type)
            @compileError("`LoggerType` must be same as the type of the first found logger");

        return core.utils.fieldPtr(context_type, field.name, context_ptr);
    }

    @compileError("Logger not found in `context_ptr`");
}
