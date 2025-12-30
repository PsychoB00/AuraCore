/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;

const comptimePrint = std.fmt.comptimePrint;
const eql = std.mem.eql;

/// Aura
const core = @import("../core.zig");

const ResourceOptions = core.routing.ResourceOptions;
const EnforcedHeadersTag = core.routing.EnforcedHeadersTag;
const EnforcedHeaders = core.routing.EnforcedHeaders;

const isPathParameters = core.routing.isPathParameters;
const isQueryParameters = core.routing.isQueryParameters;
const isHeaderParameters = core.routing.isHeaderParameters;
const isBodyParameters = core.routing.isBodyParameters;
const isContext = core.context.isContext;

/// Third Party
const zap = @import("zap");

const StatusCode = zap.http.StatusCode;

pub const ParametersType = enum {
    path,
    query,
    header,
    body,

    pub fn toString(comptime Type: ParametersType) []const u8 {
        switch (Type) {
            .path => return "Path",
            .query => return "Query",
            .header => return "Header",
            .body => return "Body",
        }
    }
};

/// Trait check for ResourceParameters
///
/// - `Type` must be struct
/// - `Type` must have declaration for type of parameters which it is, named "parameters_type"
///     - `parameters_type` must be declaration of ParametersType
/// - `Type` must have declaration for type of structure which it uses, named "structure"
///     - `structure` must be declaration of a type
/// - `Type` must have field of its data named "data"
///     - `data` must be field of `structure`
pub fn isResourceParameters(comptime Type: type) bool {
    if (@typeInfo(Type) != .@"struct")
        return false;

    const has_parameters_type =
        @hasDecl(Type, "parameters_type") and
        @TypeOf(Type.parameters_type) == ParametersType;

    const has_structure =
        @hasDecl(Type, "structure") and
        @TypeOf(Type.structure) == type;

    const has_data =
        has_structure and
        @hasField(Type, "data") and
        @FieldType(Type, "data") == Type.structure;

    return has_parameters_type and has_structure and has_data;
}

/// Structure for binding `Controller` and `Options` together to define REST API resource
///
/// - `Controller` must be a struct type with at least one http method.
/// - Every function can have one parameter typed:
///     - *const PathParameters
///     - *const QueryParameters
///     - *const HeaderParameters
///     - *const BodyParameters
///     - *Context
///     - Allocator
/// - Return type of http method must be either StatusCode or !StatusCode.
/// - If `Options.authenticate` is true, `Controller` can have function `unauthorized`.
/// - For brevity of APIResource type declaration, exact Context type is not checked until StaticRoute
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
                var valid_method_name_found: ?[]const u8 = null;

                for (checked_method_name) |name| methode_name_loop: {
                    if (eql(u8, name, decl.name)) {
                        has_methods = !eql(u8, "unauthorized", decl.name);
                        valid_method_name_found = decl.name;
                        break :methode_name_loop;
                    }
                }
                if (valid_method_name_found == null)
                    @compileError(comptimePrint(
                        "Function with unsupported name ({s}) found in {s}",
                        .{ decl.name, @typeName(Controller) },
                    ));

                // Parameters correctness assertion
                var path_param_found: ?type = null;
                var query_param_found: ?type = null;
                var header_param_found: ?type = null;
                var body_param_found: ?type = null;
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
                                if (isPathParameters(param_info.child)) {
                                    // Path parameters
                                    if (path_param_found != null)
                                        @compileError(comptimePrint(
                                            "Duplicate Path parameters found in {s}.{s}",
                                            .{ @typeName(Controller), decl.name },
                                        ));
                                    path_param_found = param_info.child;
                                } else if (isQueryParameters(param_info.child)) {
                                    // Query parameters
                                    if (query_param_found != null)
                                        @compileError(comptimePrint(
                                            "Duplicate Query parameters found in {s}.{s}",
                                            .{ @typeName(Controller), decl.name },
                                        ));
                                    query_param_found = param_info.child;
                                } else if (isHeaderParameters(param_info.child)) {
                                    // Header parameters
                                    if (header_param_found != null)
                                        @compileError(comptimePrint(
                                            "Duplicate Header parameters found in {s}.{s}",
                                            .{ @typeName(Controller), decl.name },
                                        ));
                                    header_param_found = param_info.child;
                                } else if (isBodyParameters(param_info.child)) {
                                    // Body parameters
                                    if (body_param_found != null)
                                        @compileError(comptimePrint(
                                            "Duplicate Body parameters found in {s}.{s}",
                                            .{ @typeName(Controller), decl.name },
                                        ));
                                    body_param_found = param_info.child;
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

                const enforced_headers =
                    EnforcedHeaders(
                        EnforcedHeadersTag.generate(
                            Options.authenticate,
                            body_param_found != null,
                        ),
                    );

                if (header_param_found) |header_parameters_type|
                    if (header_parameters_type.infered_enforced_headers_t != enforced_headers)
                        @compileError(comptimePrint(
                            "Infered enforced headers of a APIResource ({s}) is different then observed enforced headers, found in {s}",
                            .{ @typeName(@This()), valid_method_name_found.? },
                        ));

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

    const infered_context_type = context_type;

    return struct {
        const APIResourceType = @This();
        pub const controller_t = Controller;
        pub const options = Options;
        pub const infered_context_t = infered_context_type;
    };
}

/// Trait check for APIResource
///
/// - `Type` must be struct
/// - `Type` must have declaration for type of controller which it is using, named "controller_t"
///     - `controller_t` must be declaration of type
/// - `Type` must have declaration for options which it uses, named "options"
///     - `options` must be declaration of ResourceOptions
/// - `Type` must be able to generate `Type` using its declarations and function APIResource
pub fn isAPIResource(comptime Type: type) bool {
    if (@typeInfo(Type) != .@"struct")
        return false;

    const has_controller_type =
        @hasDecl(Type, "controller_t") and
        @TypeOf(Type.controller_t) == type;

    const has_options =
        @hasDecl(Type, "options") and
        @TypeOf(Type.options) == ResourceOptions;

    const can_generate_self =
        has_controller_type and has_options and
        APIResource(Type.controller_t, Type.options) == Type;

    return can_generate_self;
}
