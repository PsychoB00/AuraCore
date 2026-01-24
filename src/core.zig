/// STD
const std = @import("std");

const assert = std.debug.assert;
const toUpper = std.ascii.toUpper;
const isHex = std.ascii.isHex;
const isDigit = std.ascii.isDigit;

/// Aura
pub const getVersion = @import("version.zig").getVersion;
pub const dome = @embedFile("resources/aura_dome.svg");

pub const utils = struct {
    /// Gets pointer to a field of parent based on `Name`
    pub fn fieldPtr(comptime ParentType: type, comptime Name: []const u8, parent: *const ParentType) *@FieldType(ParentType, Name) {
        return @as(
            *@FieldType(ParentType, Name),
            @ptrFromInt(@intFromPtr(parent) + @offsetOf(ParentType, Name)),
        );
    }

    pub fn assertValidate(not_error: anyerror!void) void {
        assert(assert_blk: {
            not_error catch break :assert_blk false;
            break :assert_blk true;
        });
    }
};

pub const fmt = @import("fmt.zig");
pub const application = @import("application.zig");
pub const context = @import("context.zig");
pub const log = @import("log.zig");
pub const time = @import("time.zig");
pub const json = @import("json.zig");
pub const jwt = @import("jwt.zig");

pub const net = struct {
    pub const headers = @import("net/headers/headers.zig");

    pub const uri = @import("net/uri.zig");

    const method = @import("net/method.zig");
    pub const methodToLower = method.methodToLower;
    pub const methodToUpper = method.methodToUpper;

    pub const status_code = @import("net/status_code.zig");
    pub const statusCodeToUpper = status_code.statusCodeToUpper;
    pub const statusCodeFormat = status_code.format;
};

pub const routing = @import("routing/routing.zig");
