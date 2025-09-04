/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;
const EnvMap = std.process.EnvMap;

/// Aura
pub const utils = @This();

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

/// Gets pointer to a field of parent based on `Name`
pub fn fieldPtr(comptime ParentType: type, comptime Name: []const u8, parent: *const ParentType) *@FieldType(ParentType, Name) {
    return @as(
        *@FieldType(ParentType, Name),
        @ptrFromInt(@intFromPtr(parent) + @offsetOf(ParentType, Name)),
    );
}
