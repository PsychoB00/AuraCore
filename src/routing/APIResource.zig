/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;
const StatusCode = zap.http.StatusCode;

const comptimePrint = std.fmt.comptimePrint;
const eql = std.mem.eql;

/// Aura
const core = @import("../core.zig");

const ResourceOptions = core.routing.ResourceOptions;

const isPathParameters = core.routing.isPathParameters;
const isQueryParameters = core.routing.isQueryParameters;
const isBodyParameters = core.routing.isBodyParameters;
const isContext = core.context.isContext;

/// Third Party
const zap = @import("zap");
const Request = zap.Request;

pub const ParametersType = enum {
    path,
    query,
    body,
};

pub const ResourceParametersError = error{
    NotFound,
    BadRequest,
};

pub fn isResourceParameters(comptime Type: type) bool {
    return @hasDecl(Type, "parameters_type") and @TypeOf(Type.parameters_type) == ParametersType and
        @hasDecl(Type, "structure") and @TypeOf(Type.structure) == type and
        @hasField(Type, "data") and @FieldType(Type, "data") == Type.structure;
}

/// Structure for binding `Controller` and `Options` together
///
/// - `Controller` must be a struct type with at least one http method.
/// - Every function can have one parameter typed:
///     - *const PathParameters
///     - *const QueryParameters
///     - *const BodyParameters
///     - *const Request
///     - *Context
///     - Allocator
/// - Return type of http method must be either StatusCode or !StatusCode.
/// - If `Options.authenticate` is true, `Controller` can have function `unauthorized`.
/// - For brevity of APIResource type decleration, exact Context type is not checked until StaticRoute
///   generation in Router.
pub fn APIResource(comptime Controller: type, comptime Options: ResourceOptions) type {
    // `Controller` correctness asssertion
    const controller_info = @typeInfo(Controller);
    const function_names = [_][]const u8{
        "unauthorized",
        "get",
        "post",
        "put",
        "delete",
        "patch",
        "options",
        "head",
    };

    if (controller_info != .@"struct")
        @compileError("`Controller` must be a struct");
    if (controller_info.@"struct".is_tuple)
        @compileError("`Controller` must be non-tuple struct");

    // Methods correctness assertion
    var has_methods = false;
    var context_type: ?type = null;

    for (controller_info.@"struct".decls) |decl| {
        switch (@typeInfo(@TypeOf(@field(Controller, decl.name)))) {
            .@"fn" => |info| {
                // Name validity assertion
                const checked_method_name =
                    if (Options.authenticate)
                        function_names
                    else
                        function_names[1..];
                var valid_method_name_found = false;

                for (checked_method_name) |name| methode_name_loop: {
                    if (eql(u8, name, decl.name)) {
                        has_methods = !eql(u8, "unauthorized", decl.name);
                        valid_method_name_found = true;
                        break :methode_name_loop;
                    }
                }
                if (!valid_method_name_found)
                    @compileError(comptimePrint(
                        "Function with unsupported name ({s}) found in {s}",
                        .{ decl.name, @typeName(Controller) },
                    ));

                // Parameters correctness assertion
                var path_param_found = false;
                var query_param_found = false;
                var body_param_found = false;
                var request_param_found = false;
                var context_param_found = false;
                var allocator_param_found = false;

                for (info.params) |param| {
                    if (param.type == null)
                        @compileError(comptimePrint(
                            "Parameter without type found in {s}.{s}",
                            .{ @typeName(Controller), decl.name },
                        ));

                    switch (@typeInfo(param.type.?)) {
                        .@"struct" => {
                            // Allocator
                            if (param.type != Allocator)
                                @compileError(comptimePrint(
                                    "Unsupported parameter type found in {s}.{s}",
                                    .{ @typeName(Controller), decl.name },
                                ));
                            if (allocator_param_found)
                                @compileError(comptimePrint(
                                    "Duplicate Allocator parameter found in {s}.{s}",
                                    .{ @typeName(Controller), decl.name },
                                ));
                            allocator_param_found = true;
                        },
                        .pointer => |param_info| {
                            if (param_info.is_const) {
                                if (param_info.child == Request) {
                                    // Request
                                    if (request_param_found)
                                        @compileError(comptimePrint(
                                            "Duplicate Request parameter found in {s}.{s}",
                                            .{ @typeName(Controller), decl.name },
                                        ));
                                    request_param_found = true;
                                } else if (isPathParameters(param_info.child)) {
                                    // Path parameters
                                    if (path_param_found)
                                        @compileError(comptimePrint(
                                            "Duplicate Path parameters found in {s}.{s}",
                                            .{ @typeName(Controller), decl.name },
                                        ));
                                    path_param_found = true;
                                } else if (isQueryParameters(param_info.child)) {
                                    // Query parameters
                                    if (query_param_found)
                                        @compileError(comptimePrint(
                                            "Duplicate Query parameters found in {s}.{s}",
                                            .{ @typeName(Controller), decl.name },
                                        ));
                                    query_param_found = true;
                                } else if (isBodyParameters(param_info.child)) {
                                    // Body parameters
                                    if (body_param_found)
                                        @compileError(comptimePrint(
                                            "Duplicate Body parameters found in {s}.{s}",
                                            .{ @typeName(Controller), decl.name },
                                        ));
                                    body_param_found = true;
                                } else @compileError(comptimePrint(
                                    "Unsupported parameter type found in {s}.{s}",
                                    .{ @typeName(Controller), decl.name },
                                ));
                            } else {
                                // Context
                                if (!isContext(param_info.child) or
                                    (context_type != null and context_type != param_info.child))
                                    @compileError(comptimePrint(
                                        "Unsupported parameter type found in {s}.{s}",
                                        .{ @typeName(Controller), decl.name },
                                    ));
                                if (context_param_found)
                                    @compileError(comptimePrint(
                                        "Duplicate Context parameter found in {s}.{s}",
                                        .{ @typeName(Controller), decl.name },
                                    ));
                                context_type = param_info.child;
                                context_param_found = true;
                            }
                        },
                        else => @compileError(comptimePrint(
                            "Unsupported parameter type found in {s}.{s}",
                            .{ @typeName(Controller), decl.name },
                        )),
                    }
                }

                // Return type correctness assertion
                if (info.return_type == null)
                    @compileError(comptimePrint(
                        "Function without return type found in {s}.{s}",
                        .{ @typeName(Controller), decl.name },
                    ));

                const return_type =
                    if (@typeInfo(info.return_type.?) == .error_union)
                        @typeInfo(info.return_type.?).error_union.payload
                    else
                        info.return_type.?;

                if (return_type != StatusCode)
                    @compileError(comptimePrint(
                        "Return payload type which isn't StatusCode found in {s}",
                        .{decl.name},
                    ));
            },
            else => {},
        }
    }

    if (!has_methods)
        @compileError(comptimePrint(
            "No method found in {s}",
            .{@typeName(Controller)},
        ));

    const infereted_context_type = context_type;

    return struct {
        const APIResourceType = @This();
        pub const controller_t = Controller;
        pub const options = Options;
        pub const infered_context_t = infereted_context_type;
    };
}

pub fn isAPIResource(comptime Type: type) bool {
    return @hasDecl(Type, "controller_t") and @TypeOf(Type.controller_t) == type and
        @hasDecl(Type, "options") and @TypeOf(Type.options) == ResourceOptions and
        APIResource(Type.controller_t, Type.options) == Type;
}
