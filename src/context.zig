/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;
const EnvMap = std.process.EnvMap;

const hasMethod = std.meta.hasMethod;

const buildin = @import("builtin");

const IsDebug = buildin.mode == .Debug;

/// Aura
const core = @import("core.zig");

const isOnRequestProcessor = core.routing.isOnRequestProcessor;

/// Third Party
const zeit = @import("zeit");

const TimeZone = zeit.TimeZone;

const zap = @import("zap");

const Request = zap.Request;

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

/// This function redirects any request with path "/" to `Location`, any other request will respond with 404 NOT_FOUND
pub fn unhandledRequestRedirect(
    comptime Location: []const u8,
    comptime ContextType: type,
    comptime OnRequestProcessorType: ?type,
    context: *ContextType,
    allocator: Allocator,
    request: Request,
) void {
    comptime {
        // `Location` correctness assertion
        if (Location.len <= 1)
            @compileError("`Location` must be longer then 1 character");
        if (Location.len > 253)
            @compileError("`Location` must be shorter then 254 characters");

        // `ContextType` correctness assertion
        if (OnRequestProcessorType != null and ContextType != OnRequestProcessorType.?.context_t)
            @compileError("`ContextType` and `OnRequestProcessorType.context_t` must be same");

        // `OnRequestProcessorType` correctness assertion
        if (OnRequestProcessorType != null and !isOnRequestProcessor(OnRequestProcessorType.?))
            @compileError("`isOnRequestProcessor` must be OnRequestProcessor");
    }

    var orp: if (OnRequestProcessorType != null) OnRequestProcessorType.? else void = undefined;
    if (comptime OnRequestProcessorType != null) {
        switch (request.methodAsEnum()) {
            .GET => orp.initUnhandledRequest(.GET, allocator, context, &request),
            .POST => orp.initUnhandledRequest(.POST, allocator, context, &request),
            .PUT => orp.initUnhandledRequest(.PUT, allocator, context, &request),
            .DELETE => orp.initUnhandledRequest(.DELETE, allocator, context, &request),
            .PATCH => orp.initUnhandledRequest(.PATCH, allocator, context, &request),
            .OPTIONS => orp.initUnhandledRequest(.OPTIONS, allocator, context, &request),
            .HEAD => orp.initUnhandledRequest(.HEAD, allocator, context, &request),
            else => unreachable,
        }
        defer orp.deinit();
    }

    if (request.path) |path| {
        if (path.len == 1 and path[0] == '/') {
            request.redirectTo(Location, .found) catch |err| {
                if (comptime (OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "redirectError")))
                    orp.redirectError(.internal_server_error, err, if (comptime IsDebug) @errorReturnTrace().?.* else {});
                request.setStatus(.internal_server_error);
                return;
            };
            if (comptime (OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "redirect")))
                orp.redirect(.found);
            return;
        }
    }

    if (comptime (OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "invalidRequest")))
        orp.invalidRequest(.not_found, error.InvalidPath);
    request.setStatus(.not_found);
}

/// Trait check for Context
///
/// - `Type` must be struct
/// - `Type` must have declaration for initializing method, named "init"
///     - `init` must have function signiture fn(*Type, Allocator) anyerror!void
/// - `Type` must have declaration for deinitializing method, named "deinit"
///     - `deinit` must have function signiture fn(*Type, Allocator) void
/// - `Type` must have declaration for handeling unhandled request, named "unhandledRequest"
///     - `unhandledRequest` must have function signiture fn(*Type, Allocator, Request) anyerror!void
pub fn isContext(comptime Type: type) bool {
    if (@typeInfo(Type) != .@"struct")
        return false;

    const has_init =
        hasMethod(Type, "init") and
        @TypeOf(Type.init) == fn (*Type, Allocator) anyerror!void;

    const has_deinit =
        hasMethod(Type, "deinit") and
        @TypeOf(Type.deinit) == fn (*Type, Allocator) void;

    const has_unhandled_request =
        hasMethod(Type, "unhandledRequest") and
        @TypeOf(Type.unhandledRequest) == fn (*Type, Allocator, Request) anyerror!void;

    return has_init and has_deinit and has_unhandled_request;
}

pub fn hasLogger(comptime Type: type) ?type {
    if (!isContext(Type))
        @compileError("`Type` must be a Context");

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
