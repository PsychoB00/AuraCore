/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;

const comptimePrint = std.fmt.comptimePrint;
const eql = std.mem.eql;

/// Aura
const core = @import("../core.zig");

const ResourceOptions = core.routing.ResourceOptions;
const RequiredHeadersTag = core.routing.RequiredHeadersTag;
const RequiredHeaders = core.routing.RequiredHeaders;
const EnforcedHeadersTag = core.routing.EnforcedHeadersTag;
const EnforcedHeaders = core.routing.EnforcedHeaders;

const isPathParameters = core.routing.isPathParameters;
const isQueryParameters = core.routing.isQueryParameters;
const isHeaderParameters = core.routing.isHeaderParameters;
const isBodyParameters = core.routing.isBodyParameters;
const isContext = core.context.isContext;
const isResultHeader = core.routing.isResultHeader;
const isResultBody = core.routing.isResultBody;
const isResultRedirect = core.routing.isResultRedirect;

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

pub const ResultType = enum {
    header,
    body,
    redirect,

    pub fn toString(comptime Type: ResultType) []const u8 {
        switch (Type) {
            .header => return "Header",
            .body => return "Body",
            .redirect => return "Redirect",
        }
    }
};

/// Trait check for ResourceResult
///
/// - `Type` must be struct
/// - `Type` must have declaration for type of result which it is, named "result_type"
///     - `result_type` must be declaration of ResultType
/// - `Type` must have declaration for type of structure which it uses, named "structure"
///     - `structure` must be declaration of a type
/// - `Type` must have field of its data named "data"
///     - `data` must be field of `structure`
pub fn isResourceResult(comptime Type: type) bool {
    if (@typeInfo(Type) != .@"struct")
        return false;

    const has_result_type =
        @hasDecl(Type, "result_type") and
        @TypeOf(Type.result_type) == ResultType;

    const has_structure =
        @hasDecl(Type, "structure") and
        @TypeOf(Type.structure) == type;

    const has_data =
        has_structure and
        @hasField(Type, "data") and
        @FieldType(Type, "data") == Type.structure;

    return has_result_type and has_structure and has_data;
}

/// Structure for binding `Controller` and `Options` together to define REST API resource
///
/// - `Controller` must be a struct type with at least one http method.
/// - Every function can have one parameter typed:
///     - *const PathParameters
///     - *const QueryParameters
///     - *const HeaderParameters
///     - *const BodyParameters
///     - *const ClaimsSet
///     - *Context
///     - Allocator
///     - *ResultBody
///     - *ResultHeader
///     - *ResultRedirect
/// - Return type of http method must be either StatusCode or !StatusCode.
/// - For brevity of APIResource type declaration, exact Context type and ClaimsSet type are not checked until StaticRoute
///   generation in Router.
pub fn APIResource(comptime Controller: type, comptime Options: ResourceOptions) type {
    // `Options` correctness assertion
    Options.validate() catch |err|
        @compileError(comptimePrint(
            "`Options` are invalid, cause {s}",
            .{@errorName(err)},
        ));

    // `Controller` correctness asssertion
    const controller_info = @typeInfo(Controller);
    const function_names = [_][]const u8{
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

    var path_param_found: ?type = null;
    var query_param_found: ?type = null;
    var header_param_found: ?type = null;
    var body_param_found: ?type = null;
    var claims_set_param_found: ?type = null;
    var context_param_found: ?type = null;
    var allocator_param_found = false;
    var result_header_found: ?type = null;
    var result_body_found: ?type = null;
    var result_redirect_found: ?type = null;

    for (controller_info.@"struct".decls) |decl| {
        switch (@typeInfo(@TypeOf(@field(Controller, decl.name)))) {
            .@"fn" => |info| {
                // Name validity assertion
                var valid_method_name_found: ?[]const u8 = null;

                for (function_names) |name| methode_name_loop: {
                    if (eql(u8, name, decl.name)) {
                        has_methods = true;
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
                                } else {
                                    if (Options.authorize != null) {
                                        // ClaimsSet
                                        if (claims_set_param_found != null)
                                            @compileError(comptimePrint(
                                                "Duplicate ClaimsSet found in {s}.{s}",
                                                .{ @typeName(Controller), decl.name },
                                            ));
                                        claims_set_param_found = param_info.child;
                                    } else @compileError(comptimePrint(
                                        "Unsupported parameter type found in {s}.{s}",
                                        .{ @typeName(Controller), decl.name },
                                    ));
                                }
                            } else {
                                if (isResultHeader(param_info.child)) {
                                    // Result header
                                    if (result_header_found != null)
                                        @compileError(comptimePrint(
                                            "Duplicate result Header found in {s}.{s}",
                                            .{ @typeName(Controller), decl.name },
                                        ));
                                    result_header_found = param_info.child;
                                } else if (isResultBody(param_info.child)) {
                                    // Result body
                                    if (result_body_found != null)
                                        @compileError(comptimePrint(
                                            "Duplicate result Body found in {s}.{s}",
                                            .{ @typeName(Controller), decl.name },
                                        ));
                                    if (eql(u8, valid_method_name_found.?, "head"))
                                        @compileError(comptimePrint(
                                            "Method HEAD with result Body found in {s}.{s}",
                                            .{ @typeName(Controller), decl.name },
                                        ));
                                    result_body_found = param_info.child;
                                } else if (isResultRedirect(param_info.child)) {
                                    // Result redirect
                                    if (result_redirect_found != null)
                                        @compileError(comptimePrint(
                                            "Duplicate result Redirect found in {s}.{s}",
                                            .{ @typeName(Controller), decl.name },
                                        ));
                                    result_redirect_found = param_info.child;
                                } else {
                                    // Context
                                    if (!isContext(param_info.child) or
                                        (context_param_found != null and context_param_found != param_info.child))
                                        @compileError(comptimePrint(
                                            "Unsupported parameter type found in {s}.{s}",
                                            .{ @typeName(Controller), decl.name },
                                        ));
                                    if (context_param_found != null)
                                        @compileError(comptimePrint(
                                            "Duplicate Context parameter found in {s}.{s}",
                                            .{ @typeName(Controller), decl.name },
                                        ));
                                    context_param_found = param_info.child;
                                }
                            }
                        },
                        else => @compileError(comptimePrint(
                            "Unsupported parameter type found in {s}.{s}",
                            .{ @typeName(Controller), decl.name },
                        )),
                    }
                }

                // Derived required headers correctness assertion
                const derived_required_headers =
                    RequiredHeaders(RequiredHeadersTag.generate(.{
                        .has_body_parameters = body_param_found != null,
                        .has_authorization = Options.authorize != null,
                        .has_result_body = result_body_found != null,
                    }));

                if (header_param_found) |header_parameters_type|
                    if (!RequiredHeadersTag.derivedFulfilled(derived_required_headers.tag, header_parameters_type.infered_required_headers_t.tag))
                        @compileError(comptimePrint(
                            "Infered required headers of a APIResource({s}) doesn't fulfill derived required headers, found in {s}",
                            .{ @typeName(Controller), valid_method_name_found.? },
                        ));

                // Derived enforced headers correctness assertion
                const derived_enforced_headers =
                    EnforcedHeaders(EnforcedHeadersTag.generate(.{
                        .has_result_body = result_body_found != null,
                    }));

                if (result_header_found) |result_header_type|
                    if (!EnforcedHeadersTag.derivedFulfilled(derived_enforced_headers.tag, result_header_type.infered_enforced_headers_t.tag))
                        @compileError(comptimePrint(
                            "Infered enforced headers of a APIResource({s}) doesn't fulfill derived enforced headers, found in {s}",
                            .{ @typeName(Controller), valid_method_name_found.? },
                        ));

                // Result composition correctness assertion
                if (result_header_found != null and result_body_found != null and
                    (@typeInfo(result_header_found.?.structure) != .optional or @typeInfo(result_body_found.?.structure) != .optional) and
                    (@typeInfo(result_header_found.?.structure) == .optional or @typeInfo(result_body_found.?.structure) == .optional))
                    @compileError(comptimePrint(
                        "ResultHeader with different data optionality then ResultBody, found in APIResource({s}) {s}",
                        .{ @typeName(Controller), valid_method_name_found.? },
                    ));

                if (result_redirect_found != null and (result_header_found != null or result_body_found != null)) {
                    const is_result_redirect_optional = @typeInfo(result_redirect_found.?.structure) == .optional;

                    const are_result_header_body_optional =
                        if (result_header_found != null)
                            @typeInfo(result_header_found.?.structure) == .optional
                        else
                            @typeInfo(result_body_found.?.structure) == .optional;

                    if (!is_result_redirect_optional or !are_result_header_body_optional)
                        @compileError(comptimePrint(
                            "ResourceResult with non-optional data, while both redirect and success ResourceResults are defined, found in APIResource({s}) {s}",
                            .{ @typeName(Controller), valid_method_name_found.? },
                        ));
                }

                if (result_redirect_found != null and result_header_found == null and result_body_found == null and @typeInfo(result_redirect_found.?.structure) == .optional)
                    @compileError(comptimePrint(
                        "ResultRedirect with optional data, while ResultHeader and ResultBody are not defined, found in APIResource({s}) {s}",
                        .{ @typeName(Controller), valid_method_name_found.? },
                    ));

                if (result_redirect_found == null and
                    ((result_header_found != null and @typeInfo(result_header_found.?.structure) == .optional) or
                        (result_body_found != null and @typeInfo(result_body_found.?.structure) == .optional)))
                    @compileError(comptimePrint(
                        "ResultHeader or ResultBody with optional data, while ResultRedirect is not defined, found in APIResource({s}) {s}",
                        .{ @typeName(Controller), valid_method_name_found.? },
                    ));

                if (result_redirect_found != null)

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

    const infered_context_type = context_param_found;
    const infered_claims_set_type = claims_set_param_found;

    return struct {
        const APIResourceType = @This();
        pub const controller_t = Controller;
        pub const options = Options;
        pub const infered_context_t = infered_context_type;
        pub const infered_claims_set_t = infered_claims_set_type;
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
