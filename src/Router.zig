/// STD
const std = @import("std");
const Allocator = std.mem.Allocator;
const Methode = std.http.Method;
const comptimePrint = std.fmt.comptimePrint;

/// Aura
const core = @import("root.zig");
const static_resource = @import("StaticResource.zig").static_resource;
const api_resource = @import("APIResource.zig").api_resource;
const ResourceParametersError = api_resource.ResourceParametersError;
const json = @import("json.zig").json;

/// Third Party
const zap = @import("zap");
const ErrorStrategy = zap.Endpoint.ErrorStrategy;
const Request = zap.Request;
const StatusCode = zap.http.StatusCode;

const zeit = @import("zeit");
const Time = zeit.Time;

const zimdjson = @import("zimdjson");
const JsonParser = zimdjson.ondemand.FullParser(.default);

pub const router = struct {
    pub const ResourceType = enum {
        static,
        api,
    };

    pub const ResourceTreeOptions = struct {
        /// What type of resource/s does ResourceTree hold
        resource_type: ResourceType,
        /// Should endpoint requests for resources in this ResourceTree be authenticated by Router
        authenticated: bool,
        /// How should zap handle endpoint request error
        error_strategy: ErrorStrategy = .log_to_console,
    };

    /// Struct for binding `Options` to `Controller`
    ///
    /// - For ResourceTree with `Options.resource_type` == `static`
    ///     - `Controller` is a type which has either declaration for root directory type or declaration for StaticResource type.
    ///     - Router will only route GET requests to this ResourceTree, other methode types will result in "METHOD_NOT_ALLOWED".
    ///     - Requests must have path formated as "/root/sub-dir/index.html".
    /// - For ResourceTree with `Options.resource_type` == `api`
    ///     - `Controller` is a type which has either declaration for root directory type or declaration for APIResource type.
    ///     - APIResource type has to have one or more functions which
    ///         - Must have http methode name `get`, `post`, `put`, `delete`, `patch`, `options` or `head`.
    ///         - Can have allocator parameter typed *const Allocator.
    ///         - Can have request parameter typed *const Request.
    ///         - Can have context parameter typed *Context.
    ///         - Can have resource parameters typed *const ResourceParameters(...).
    ///         - Must have either zap.http.StatusCode or !zap.http.StatusCode return type.
    ///     - Requests must have path formated as "/root/sub-dir/resources/{resource_id}/sub_resources/{sub_resource_id}?param1={param1_value}&param2={param2_value}".
    ///     - For brevity of ResourceTree type decleration, Context type is ommited. Its correctnes is validated during generating of static routes by Router.
    ///     - The paths generate by Router for static routes will shadow each other, if one starts with the other. So paths like
    ///       "/root/sub-dir/resource" and "/root/sub-dir/resources" are not valid and their correctnes will be validated during generating of static routes by Router.
    pub fn ResourceTree(comptime Controller: type, comptime Options: ResourceTreeOptions) type {
        // Generated Path tools
        const Gen = struct {
            const method_names = [_][]const u8{
                "get",
                "post",
                "put",
                "delete",
                "patch",
                "options",
                "head",
            };

            /// Recursive function for validating `Segment`
            fn _validateSegment(comptime Segment: type, comptime Name: []const u8) void {
                const segment_info = @typeInfo(Segment);

                if (segment_info.@"struct".fields.len != 0)
                    @compileError(comptimePrint(
                        "Field/s found in {s}",
                        .{@typeName(Segment)},
                    ));

                for (segment_info.@"struct".decls) |decl| {
                    // `decl` validation
                    var is_directory: ?bool = null;

                    if (@TypeOf(@field(Segment, decl.name)) == type and
                        @typeInfo(@field(Segment, decl.name)) == .@"struct")
                    {
                        // `decl` is struct type declaration
                        const struct_value: type = @field(Segment, decl.name);

                        if (is_directory != null and !is_directory.?)
                            @compileError(comptimePrint(
                                "Directory declaration found in Resource, in {s}",
                                .{@typeName(Segment)},
                            ));

                        is_directory = true;

                        if (static_resource.isStaticResource(struct_value)) {
                            if (Options.resource_type != .static)
                                @compileError(comptimePrint(
                                    "StaticResource declaration found in {s}, despite `Options.resource_type` != .static",
                                    .{@typeName(Segment)},
                                ));
                        } else _validateSegment(struct_value, decl.name);
                    } else if (@TypeOf(@field(Segment, decl.name)) != type and
                        @typeInfo(@TypeOf(@field(Segment, decl.name))) == .@"fn")
                    {
                        // `decl` is fn declaration
                        const fn_value: std.builtin.Type.Fn = @typeInfo(@TypeOf(@field(Segment, decl.name))).@"fn";

                        if (Options.resource_type != .api)
                            @compileError(comptimePrint(
                                "Function decleration found in {s}, despite `Options.resource_type` != .api",
                                .{@typeName(Segment)},
                            ));
                        if (is_directory != null and is_directory.?)
                            @compileError(comptimePrint(
                                "Function decleration found in directory, in {s}",
                                .{@typeName(Segment)},
                            ));

                        is_directory = false;

                        // Check if fn name is supported http methode name
                        var valid_name_found = false;

                        for (method_names) |method_name| {
                            if (std.mem.eql(u8, decl.name, method_name))
                                valid_name_found = true;
                        }
                        if (!valid_name_found)
                            @compileError(comptimePrint(
                                "Function without name matching any http methode, found in {s}",
                                .{@typeName(Segment)},
                            ));

                        // Validate fn parameters
                        var allocator_param_found = false;
                        var context_param_found = false;
                        var request_param_found = false;

                        var path_param_found = false;
                        var query_param_found = false;
                        var body_param_found = false;

                        for (fn_value.params) |param| {
                            if (param.type != null) {
                                if (@typeInfo(param.type.?) == .pointer) {
                                    const pointer_param_info = @typeInfo(param.type.?).pointer;
                                    const param_type = pointer_param_info.child;

                                    if (param_type == Allocator) {
                                        // Validate Allocator parameter
                                        if (!pointer_param_info.is_const)
                                            @compileError(comptimePrint(
                                                "Function with parameter type as non-const pointer to Allocator, found in {s}",
                                                .{@typeName(Segment)},
                                            ));
                                        if (allocator_param_found)
                                            @compileError(comptimePrint(
                                                "Function with duplicate Allocator parameter, found in {s}",
                                                .{@typeName(Segment)},
                                            ));

                                        allocator_param_found = true;
                                    } else if (param_type == Request) {
                                        // Validate Request parameter
                                        if (!pointer_param_info.is_const)
                                            @compileError(comptimePrint(
                                                "Function with parameter type as non-const pointer to Request, found in {s}",
                                                .{@typeName(Segment)},
                                            ));
                                        if (request_param_found)
                                            @compileError(comptimePrint(
                                                "Function with duplicate Request parameter, found in {s}",
                                                .{@typeName(Segment)},
                                            ));

                                        request_param_found = true;
                                    } else if (@typeInfo(param_type) == .@"struct") {
                                        // Validate ResourceParameters parameter
                                        if (api_resource.isResourceParameters(param_type)) {
                                            if (!pointer_param_info.is_const)
                                                @compileError(comptimePrint(
                                                    "Function with parameter type as non-const pointer to ResourceParameters, found in {s}",
                                                    .{@typeName(Segment)},
                                                ));

                                            switch (param_type.parameters_type) {
                                                .path => {
                                                    if (!std.mem.eql(u8, @typeInfo(param_type.structure).@"struct".fields[0].name, Name))
                                                        @compileError(comptimePrint(
                                                            "Path parameter with name of the first field different to name of `Segment`, found in {s}",
                                                            .{@typeName(Segment)},
                                                        ));
                                                    if (path_param_found)
                                                        @compileError(comptimePrint(
                                                            "Function with duplicate Path parameter, found in {s}",
                                                            .{@typeName(Segment)},
                                                        ));

                                                    path_param_found = true;
                                                },
                                                .query => {
                                                    if (query_param_found)
                                                        @compileError(comptimePrint(
                                                            "Function with duplicate Query parameter, found in {s}",
                                                            .{@typeName(Segment)},
                                                        ));

                                                    query_param_found = true;
                                                },
                                                .body => {
                                                    if (body_param_found)
                                                        @compileError(comptimePrint(
                                                            "Function with duplicate Body parameter, found in {s}",
                                                            .{@typeName(Segment)},
                                                        ));

                                                    body_param_found = true;
                                                },
                                            }
                                        } else {
                                            // Validate Context parameter
                                            if (pointer_param_info.is_const)
                                                @compileError(comptimePrint(
                                                    "Function with parameter type as const pointer to Context, found in {s}",
                                                    .{@typeName(Segment)},
                                                ));
                                            if (context_param_found)
                                                @compileError(comptimePrint(
                                                    "Function with duplicate Context parameter, found in {s}",
                                                    .{@typeName(Segment)},
                                                ));

                                            context_param_found = true;
                                        }
                                    } else @compileError(comptimePrint(
                                        "Function with unsupported parameter pointer type, found in {s}",
                                        .{@typeName(Segment)},
                                    ));
                                } else @compileError(comptimePrint(
                                    "Function with non-pointer parameter type, found in {s}",
                                    .{@typeName(Segment)},
                                ));
                            } else @compileError(comptimePrint(
                                "Function with invalid parameter type, found in {s}",
                                .{@typeName(Segment)},
                            ));
                        }

                        // Validate fn return type
                        if (fn_value.return_type) |fn_return_type| {
                            const fn_return_info = @typeInfo(fn_return_type);

                            if ((fn_return_info == .error_union and fn_return_info.error_union.payload != StatusCode) or
                                (fn_return_info != .error_union and fn_return_type != StatusCode))
                                @compileError(comptimePrint(
                                    "Function without zap.http.StatusCode return type, found in {s}",
                                    .{@typeName(Segment)},
                                ));
                        } else @compileError(comptimePrint(
                            "Function with invalid return type, found in {s}",
                            .{@typeName(Segment)},
                        ));
                    } else @compileError(comptimePrint("Decleration type other then struct or function, found in {s}", .{@typeName(Segment)}));
                }
            }
        };

        // `Controller` validation
        const controller_info = @typeInfo(Controller);

        if (controller_info != .@"struct")
            @compileError("`Controller` must be struct");
        if (controller_info.@"struct".is_tuple)
            @compileError("`Controller` mustn't be tuple");
        if (controller_info.@"struct".fields.len != 0)
            @compileError("`Controller` mustn't have fields");
        if (controller_info.@"struct".decls.len != 1)
            @compileError("`Controller` must have only one declaration");
        if (@TypeOf(@field(Controller, controller_info.@"struct".decls[0].name)) != type)
            @compileError("`Controller` must declare one type");

        // root_segment validation
        const root_name = controller_info.@"struct".decls[0].name;
        const root_segment: type = @field(Controller, root_name);

        if (@typeInfo(root_segment) != .@"struct")
            @compileError("Root segment must be struct");
        if (@typeInfo(root_segment).@"struct".is_tuple)
            @compileError("Root segment mustn't be tuple");

        Gen._validateSegment(Controller, root_name);

        return struct {
            const controller = Controller;
            const options = Options;
        };
    }

    /// Router which constructs, authenticates and routes to `ResourceTreeSet`
    ///
    /// - `ResourceTreeSet` must be a tuple of ResourceTree types.
    /// - Every root segments inside `ResourceTreeSet` must have unique name
    pub fn Router(comptime ResourceTreeSet: anytype, comptime ContextType: type, comptime AuthenticatorType: type) type {
        // Generated Router tools
        const Gen = struct {
            const App = zap.App.Create(ContextType);

            /// Generated type used by zap for routing Requests
            fn StaticRoute(comptime Resource: type, comptime Path: []const u8, comptime Options: ResourceTreeOptions) type {
                return struct {
                    const static_path = Path;
                    const resource_tree_options = Options;

                    /// Tuple type representing parameters of `MethodeType`
                    fn MethodeParameters(comptime MethodeType: type) type {
                        const methode_info = @typeInfo(MethodeType);

                        var buffer: [methode_info.@"fn".params.len]std.builtin.Type.StructField = undefined;

                        for (0..methode_info.@"fn".params.len) |index| {
                            if (methode_info.@"fn".params[index].type) |param_type| {
                                buffer[index] = .{
                                    .name = std.fmt.comptimePrint("{}", .{index}),
                                    .type = param_type,
                                    .default_value_ptr = null,
                                    .is_comptime = false,
                                    .alignment = @alignOf(param_type),
                                };
                            } else @compileError(std.fmt.comptimePrint("Parameter with invalid type found in {s}", .{@typeName(Resource)}));
                        }

                        const parameters_fields = buffer;

                        return @Type(.{
                            .@"struct" = .{
                                .layout = .auto,
                                .fields = parameters_fields[0..],
                                .decls = &.{},
                                .is_tuple = true,
                            },
                        });
                    }

                    /// Tuple type representing resource parameters of `MethodeParametersType`
                    fn ResourceParameters(comptime MethodeParametersType: type) type {
                        const methode_parameters_info = @typeInfo(MethodeParametersType);
                        var resource_parameters_count = 0;

                        for (methode_parameters_info.@"struct".fields) |field| {
                            if (api_resource.isResourceParameters(@typeInfo(field.type).pointer.child))
                                resource_parameters_count += 1;
                        }

                        var buffer: [resource_parameters_count]std.builtin.Type.StructField = undefined;
                        var assign_index: usize = 0;

                        for (0..methode_parameters_info.@"struct".fields.len) |index| {
                            const resource_parameter_type = @typeInfo(methode_parameters_info.@"struct".fields[index].type).pointer.child;

                            if (api_resource.isResourceParameters(resource_parameter_type)) {
                                buffer[assign_index] = .{
                                    .name = std.fmt.comptimePrint("{}", .{assign_index}),
                                    .type = resource_parameter_type,
                                    .default_value_ptr = null,
                                    .is_comptime = false,
                                    .alignment = @alignOf(resource_parameter_type),
                                };
                                assign_index += 1;
                            }
                        }

                        const resource_parameters_fields = buffer;

                        return @Type(.{
                            .@"struct" = .{
                                .layout = .auto,
                                .fields = resource_parameters_fields[0..],
                                .decls = &.{},
                                .is_tuple = true,
                            },
                        });
                    }

                    path: []const u8 = Path,
                    error_strategy: zap.Endpoint.ErrorStrategy = Options.error_strategy,

                    /// GET methode called by zap
                    pub fn get(_: *@This(), allocator: Allocator, context: *ContextType, request: Request) !void {
                        switch (Options.resource_type) {
                            inline .static => {
                                if (request.path) |path| {
                                    if (path.len == Path.len) {
                                        try request.setContentTypeFromFilename(Path);
                                        try request.sendBody(Resource.data);
                                        request.setStatus(.ok);
                                    } else request.setStatus(.not_found);
                                } else request.setStatus(.internal_server_error);
                            },
                            inline .api => try _callAPIMethode(
                                "get",
                                &allocator,
                                context,
                                &request,
                            ),
                        }
                    }

                    /// POST methode called by zap
                    pub fn post(_: *@This(), allocator: Allocator, context: *ContextType, request: Request) !void {
                        switch (Options.resource_type) {
                            inline .static => request.setStatus(.method_not_allowed),
                            inline .api => try _callAPIMethode(
                                "post",
                                &allocator,
                                context,
                                &request,
                            ),
                        }
                    }

                    /// PUT methode called by zap
                    pub fn put(_: *@This(), allocator: Allocator, context: *ContextType, request: Request) !void {
                        switch (Options.resource_type) {
                            inline .static => request.setStatus(.method_not_allowed),
                            inline .api => try _callAPIMethode(
                                "put",
                                &allocator,
                                context,
                                &request,
                            ),
                        }
                    }

                    /// DELETE methode called by zap
                    pub fn delete(_: *@This(), allocator: Allocator, context: *ContextType, request: Request) !void {
                        switch (Options.resource_type) {
                            inline .static => request.setStatus(.method_not_allowed),
                            inline .api => try _callAPIMethode(
                                "delete",
                                &allocator,
                                context,
                                &request,
                            ),
                        }
                    }

                    /// PATCH methode called by zap
                    pub fn patch(_: *@This(), allocator: Allocator, context: *ContextType, request: Request) !void {
                        switch (Options.resource_type) {
                            inline .static => request.setStatus(.method_not_allowed),
                            inline .api => try _callAPIMethode(
                                "patch",
                                &allocator,
                                context,
                                &request,
                            ),
                        }
                    }

                    /// OPTIONS methode called by zap
                    pub fn options(_: *@This(), allocator: Allocator, context: *ContextType, request: Request) !void {
                        switch (Options.resource_type) {
                            inline .static => request.setStatus(.method_not_allowed),
                            inline .api => try _callAPIMethode(
                                "options",
                                &allocator,
                                context,
                                &request,
                            ),
                        }
                    }

                    /// HEAD methode called by zap
                    pub fn head(_: *@This(), allocator: Allocator, context: *ContextType, request: Request) !void {
                        switch (Options.resource_type) {
                            inline .static => request.setStatus(.method_not_allowed),
                            inline .api => try _callAPIMethode(
                                "head",
                                &allocator,
                                context,
                                &request,
                            ),
                        }
                    }

                    /// Calls API Methode
                    fn _callAPIMethode(
                        comptime MethodeName: []const u8,
                        allocator: *const Allocator,
                        context: *ContextType,
                        request: *const Request,
                    ) !void {
                        if (comptime std.meta.hasFn(Resource, MethodeName)) {
                            const methode_fn = @field(Resource, MethodeName);
                            const methode_parameters_type = MethodeParameters(@TypeOf(methode_fn));
                            const resource_parameters_type = ResourceParameters(methode_parameters_type);
                            const resource_parameters_info = @typeInfo(resource_parameters_type);

                            // Check `request` correctness
                            comptime var has_enforced_query_params: ?bool = null;
                            comptime var has_enforced_body_params: ?bool = null;

                            comptime {
                                for (resource_parameters_info.@"struct".fields) |field| {
                                    switch (field.type.parameters_type) {
                                        inline .query => {
                                            has_enforced_query_params = false;
                                            for (@typeInfo(field.type.structure).@"struct".fields) |param_field| {
                                                if (@typeInfo(param_field.type) != .optional) {
                                                    has_enforced_query_params = true;
                                                    break;
                                                }
                                            }
                                        },
                                        inline .body => has_enforced_body_params = @typeInfo(field.type.structure) != .optional,
                                        inline else => {},
                                    }
                                }
                            }

                            const path = request.path orelse return ResourceParametersError.NotFound;

                            if (comptime has_enforced_query_params == null) {
                                if (request.query != null)
                                    return ResourceParametersError.NotFound;
                            }
                            if (comptime has_enforced_body_params == null) {
                                if (request.body != null)
                                    return ResourceParametersError.BadRequest;
                            }

                            var json_parser = JsonParser.init;
                            defer json_parser.deinit(allocator.*);
                            var status_code: StatusCode = undefined;
                            var resource_parameters: resource_parameters_type = undefined;

                            // Parse parameters
                            inline for (resource_parameters_info.@"struct".fields) |field| {
                                switch (field.type.parameters_type) {
                                    inline .path => _parsePathParameters(
                                        resource_parameters_type,
                                        field,
                                        path,
                                        &resource_parameters,
                                    ) catch return ResourceParametersError.NotFound,
                                    inline .query => _parseQueryParameters(
                                        resource_parameters_type,
                                        field,
                                        has_enforced_query_params.?,
                                        request.query,
                                        &resource_parameters,
                                    ) catch return ResourceParametersError.NotFound,
                                    inline .body => {
                                        _parseBodyParameters(
                                            resource_parameters_type,
                                            field,
                                            has_enforced_body_params.?,
                                            &json_parser,
                                            allocator,
                                            request,
                                            &resource_parameters,
                                        ) catch return ResourceParametersError.BadRequest;
                                    },
                                }
                            }

                            // Call methode
                            if (@typeInfo(@typeInfo(@TypeOf(methode_fn)).@"fn".return_type.?) == .error_union) {
                                status_code = try @call(
                                    .always_inline,
                                    methode_fn,
                                    _buildMethodeParameters(
                                        MethodeParameters(@TypeOf(methode_fn)),
                                        allocator,
                                        context,
                                        request,
                                        &resource_parameters,
                                    ),
                                );
                            } else {
                                status_code = @call(
                                    .always_inline,
                                    methode_fn,
                                    _buildMethodeParameters(
                                        MethodeParameters(@TypeOf(methode_fn)),
                                        allocator,
                                        context,
                                        request,
                                        &resource_parameters,
                                    ),
                                );
                            }
                            request.setStatus(status_code);
                        } else request.setStatus(.not_found);
                    }

                    /// Builds MethodeParameters from already initialized parameters
                    fn _buildMethodeParameters(
                        comptime ParametersType: type,
                        allocator: *const Allocator,
                        context: *ContextType,
                        request: *const Request,
                        resource_parameters: *const ResourceParameters(ParametersType),
                    ) ParametersType {
                        const parameters_info = @typeInfo(ParametersType);

                        var res: ParametersType = undefined;

                        inline for (parameters_info.@"struct".fields) |field| {
                            const field_type = @typeInfo(field.type).pointer.child;

                            if (comptime field_type == Allocator) {
                                core.utils.fieldPtr(ParametersType, field.name, &res).* = allocator;
                            } else if (comptime field_type == ContextType) {
                                core.utils.fieldPtr(ParametersType, field.name, &res).* = context;
                            } else if (comptime field_type == Request) {
                                core.utils.fieldPtr(ParametersType, field.name, &res).* = request;
                            } else if (comptime api_resource.isResourceParameters(field_type)) {
                                const resource_parameters_info = @typeInfo(ResourceParameters(ParametersType));

                                inline for (resource_parameters_info.@"struct".fields) |res_param_field| {
                                    if (comptime res_param_field.type.parameters_type == field_type.parameters_type)
                                        core.utils.fieldPtr(
                                            ParametersType,
                                            field.name,
                                            &res,
                                        ).* = core.utils.fieldPtr(
                                            ResourceParameters(ParametersType),
                                            res_param_field.name,
                                            resource_parameters,
                                        );
                                }
                            } else unreachable;
                        }

                        return res;
                    }

                    /// Parse PathParameters from `path` to `resource_parameters`
                    fn _parsePathParameters(
                        comptime ResourceParametersType: type,
                        comptime Field: std.builtin.Type.StructField,
                        path: []const u8,
                        resource_parameters: *const ResourceParametersType,
                    ) !void {
                        const param_structure_info = @typeInfo(Field.type.structure);
                        var parameter_start_index = Path.len - param_structure_info.@"struct".fields[0].name.len;
                        var parsed_params_count: usize = 0;
                        const next_param_count =
                            blk: {
                                var count: usize = 0;

                                for (path[parameter_start_index..]) |char| {
                                    if (char == '/')
                                        count += 1;
                                }

                                break :blk count;
                            };
                        var null_optional_found: bool = false;

                        inline for (param_structure_info.@"struct".fields) |param_field| {
                            const param_field_info = @typeInfo(param_field.type);
                            const param_field_type =
                                if (param_field_info == .optional)
                                    param_field_info.optional.child
                                else
                                    param_field.type;

                            const field_ptr = core.utils.fieldPtr(
                                ResourceParametersType,
                                Field.name,
                                resource_parameters,
                            );
                            const param_field_ptr = core.utils.fieldPtr(
                                Field.type.structure,
                                param_field.name,
                                &field_ptr.data,
                            );

                            var value_start_index: usize =
                                if (!null_optional_found)
                                    std.mem.indexOfScalarPos(
                                        u8,
                                        path,
                                        parameter_start_index,
                                        '/',
                                    ) orelse blk: {
                                        if (param_field_info != .optional)
                                            return ResourceParametersError.NotFound;

                                        null_optional_found = true;
                                        break :blk 0;
                                    }
                                else
                                    0;

                            if (!null_optional_found) {
                                var parameter_end_index: usize = undefined;
                                value_start_index += 1;

                                if (!std.mem.eql(
                                    u8,
                                    path[parameter_start_index..(value_start_index - 1)],
                                    param_field.name,
                                )) return ResourceParametersError.NotFound;
                                if (value_start_index >= path.len)
                                    return ResourceParametersError.NotFound;

                                parameter_end_index = std.mem.indexOfScalarPos(
                                    u8,
                                    path,
                                    value_start_index,
                                    '/',
                                ) orelse path.len;

                                switch (@typeInfo(param_field_type)) {
                                    inline .int => {
                                        param_field_ptr.* = try std.fmt.parseInt(
                                            param_field_type,
                                            path[value_start_index..parameter_end_index],
                                            10,
                                        );
                                    },
                                    inline else => {
                                        if (comptime param_field_type == []const u8)
                                            param_field_ptr.* = path[value_start_index..parameter_end_index]
                                        else if (comptime param_field_type == Time)
                                            param_field_ptr.* = try Time.fromISO8601(path[value_start_index..parameter_end_index])
                                        else
                                            unreachable;
                                    },
                                }

                                parameter_start_index = parameter_end_index + 1;
                                parsed_params_count += 2;
                            } else {
                                if (param_field_info == .optional)
                                    core.utils.fieldPtr(
                                        Field.type.structure,
                                        param_field.name,
                                        &field_ptr.data,
                                    ).* = null
                                else
                                    unreachable;
                            }
                        }

                        if (next_param_count + 1 != parsed_params_count)
                            return ResourceParametersError.NotFound;
                    }

                    /// Parse QueryParameters from `path` to `resource_parameters`
                    fn _parseQueryParameters(
                        comptime ResourceParametersType: type,
                        comptime Field: std.builtin.Type.StructField,
                        comptime HasEnforcedQueryParameters: bool,
                        query: ?[]const u8,
                        resource_parameters: *const ResourceParametersType,
                    ) !void {
                        const param_structure_info = @typeInfo(Field.type.structure);
                        var parsed_params_count: usize = 0;
                        const next_param_count =
                            if (query == null)
                                0
                            else blk: {
                                var count: usize = 0;

                                for (query.?) |char| {
                                    if (char == '&')
                                        count += 1;
                                }

                                break :blk count;
                            };

                        inline for (param_structure_info.@"struct".fields) |param_field| inline_loop: {
                            const param_field_info = @typeInfo(param_field.type);
                            const param_field_type =
                                if (param_field_info == .optional)
                                    param_field_info.optional.child
                                else
                                    param_field.type;
                            const param_name = param_field.name ++ "=";

                            const field_ptr = core.utils.fieldPtr(
                                ResourceParametersType,
                                Field.name,
                                resource_parameters,
                            );
                            const param_field_ptr = core.utils.fieldPtr(
                                Field.type.structure,
                                param_field.name,
                                &field_ptr.data,
                            );

                            if (query == null) {
                                if (comptime HasEnforcedQueryParameters)
                                    return ResourceParametersError.NotFound
                                else {
                                    param_field_ptr.* = null;
                                    break :inline_loop;
                                }
                            }

                            var value_start_index = std.mem.indexOf(
                                u8,
                                query.?,
                                param_name,
                            ) orelse {
                                if (comptime param_field_info == .optional) {
                                    param_field_ptr.* = null;
                                    break :inline_loop;
                                } else return ResourceParametersError.NotFound;
                            };

                            value_start_index += param_name.len;

                            const parameter_end_index = std.mem.indexOfScalarPos(
                                u8,
                                query.?,
                                value_start_index,
                                '&',
                            ) orelse query.?.len;

                            switch (@typeInfo(param_field_type)) {
                                inline .bool => {
                                    const is_true = std.ascii.eqlIgnoreCase(
                                        query.?[value_start_index..parameter_end_index],
                                        "true",
                                    );
                                    const is_false = std.ascii.eqlIgnoreCase(
                                        query.?[value_start_index..parameter_end_index],
                                        "false",
                                    );

                                    if (!(is_true or is_false))
                                        return ResourceParametersError.NotFound;
                                    param_field_ptr.* = is_true;
                                },
                                inline .int => param_field_ptr.* = try std.fmt.parseInt(
                                    param_field_type,
                                    query.?[value_start_index..parameter_end_index],
                                    10,
                                ),
                                inline .float => param_field_ptr.* = try std.fmt.parseFloat(
                                    param_field_type,
                                    query.?[value_start_index..parameter_end_index],
                                ),
                                inline .@"enum" => param_field_ptr.* = std.meta.stringToEnum(
                                    param_field_type,
                                    query.?[value_start_index..parameter_end_index],
                                ) orelse return ResourceParametersError.NotFound,
                                inline else => {
                                    if (comptime param_field_type == []const u8)
                                        param_field_ptr.* = query.?[value_start_index..parameter_end_index]
                                    else if (comptime param_field_type == Time)
                                        param_field_ptr.* = try Time.fromISO8601(query.?[value_start_index..parameter_end_index])
                                    else
                                        unreachable;
                                },
                            }

                            parsed_params_count += 1;
                        }

                        if (next_param_count + 1 != parsed_params_count)
                            return ResourceParametersError.NotFound;
                    }

                    /// Parse BodyParameters from `request` to `resource_parameters`
                    fn _parseBodyParameters(
                        comptime ResourceParametersType: type,
                        comptime Field: std.builtin.Type.StructField,
                        comptime HasEnforcedBodyParameters: bool,
                        json_parser: *JsonParser,
                        allocator: *const Allocator,
                        request: *const Request,
                        resource_parameters: *const ResourceParametersType,
                    ) !void {
                        if (comptime HasEnforcedBodyParameters) {
                            if (request.body == null)
                                return ResourceParametersError.BadRequest;
                        } else {
                            if (request.body == null)
                                return;
                        }

                        const content_type = request.getHeaderCommon(.content_type) orelse return ResourceParametersError.BadRequest;
                        const delimiter_index = std.mem.indexOfScalar(
                            u8,
                            content_type,
                            '/',
                        ) orelse return ResourceParametersError.BadRequest;
                        if (delimiter_index == content_type.len - 1)
                            return ResourceParametersError.BadRequest;

                        const field_ptr = core.utils.fieldPtr(
                            ResourceParametersType,
                            Field.name,
                            resource_parameters,
                        );

                        if (std.mem.eql(u8, content_type[0..delimiter_index], "text")) {
                            if (std.mem.eql(u8, content_type[(delimiter_index + 1)..], "plain")) {
                                if (comptime HasEnforcedBodyParameters and Field.type.structure != []const u8)
                                    return ResourceParametersError.BadRequest
                                else if (comptime !HasEnforcedBodyParameters and Field.type.structure != ?[]const u8)
                                    return ResourceParametersError.BadRequest;

                                field_ptr.data = request.body.?;
                            } else return ResourceParametersError.BadRequest;
                        } else if (std.mem.eql(u8, content_type[0..delimiter_index], "application")) {
                            if (std.mem.eql(u8, content_type[(delimiter_index + 1)..], "json")) {
                                const document = json_parser.parseFromSlice(
                                    allocator.*,
                                    request.body.?,
                                ) catch return ResourceParametersError.BadRequest;

                                const value = document.asAny() catch return ResourceParametersError.BadRequest;

                                field_ptr.data = json.asAnyLeaky(
                                    JsonParser,
                                    Field.type.structure,
                                    &value,
                                    allocator,
                                ) catch |err| {
                                    std.debug.print("{s}\n", .{@errorName(err)});
                                    return ResourceParametersError.BadRequest;
                                };
                            } else return ResourceParametersError.BadRequest;
                        } else return ResourceParametersError.BadRequest;
                    }
                };
            }

            // Generated type for managing StaticRoute and its authenticating version
            fn AuthStaticRoute(comptime Path: []const u8, comptime Options: ResourceTreeOptions) type {
                return struct {
                    const resource_tree_options = Options;

                    const static_route = StaticRoute(Path, Options);
                    const auth_static_route = App.Endpoint.Authenticating(StaticRoute(Path, Options), AuthenticatorType);

                    sr: static_route,
                    auth_sr: auth_static_route,

                    pub fn init(self: *@This(), authenticator: *AuthenticatorType) void {
                        self.sr = .{};
                        self.auth_sr = auth_static_route.init(&self.sr, authenticator);
                    }
                };
            }

            // Generates StaticRoutes fields
            fn _generateStaticRoutesFields(
                comptime Segment: type,
                comptime Options: ResourceTreeOptions,
                comptime Path: []const u8,
                comptime BufferLen: comptime_int,
                comptime Buffer: *[BufferLen]std.builtin.Type.StructField,
                comptime Index: usize,
            ) usize {
                const segment_info = @typeInfo(Segment);
                var index = Index;

                for (segment_info.@"struct".decls) |decl| {
                    if (@TypeOf(@field(Segment, decl.name)) == type and
                        @typeInfo(@field(Segment, decl.name)) == .@"struct")
                    {
                        // `decl` is struct type definition
                        const struct_value: type = @field(Segment, decl.name);

                        if (Options.resource_type == .static and static_resource.isStaticResource(struct_value)) {
                            // StaticRoute leads to StaticResource
                            const path = comptimePrint(
                                "{s}/{s}.{s}",
                                .{
                                    Path,
                                    decl.name,
                                    @tagName(struct_value.file_type),
                                },
                            );
                            const static_route_type =
                                if (Options.authenticated)
                                    AuthStaticRoute(struct_value, path, Options)
                                else
                                    StaticRoute(struct_value, path, Options);

                            Buffer.*[index] = .{
                                .name = comptimePrint("{}", .{index}),
                                .type = static_route_type,
                                .default_value_ptr = null,
                                .is_comptime = false,
                                .alignment = @alignOf(static_route_type),
                            };
                            index += 1;

                            continue;
                        }

                        index = _generateStaticRoutesFields(
                            struct_value,
                            Options,
                            comptimePrint("{s}/{s}", .{ Path, decl.name }),
                            BufferLen,
                            Buffer,
                            index,
                        );
                    } else if (@TypeOf(@field(Segment, decl.name)) != type and
                        @typeInfo(@TypeOf(@field(Segment, decl.name))) == .@"fn")
                    {
                        // `decl` is functione definition

                        // Check of Context parameter type validity
                        for (@typeInfo(@TypeOf(@field(Segment, decl.name))).@"fn".params) |param| {
                            const param_type = @typeInfo(param.type.?).pointer.child;
                            if (param_type != Allocator and
                                param_type != ContextType and
                                param_type != Request and
                                (@typeInfo(param_type) == .@"struct" and !api_resource.isResourceParameters(param_type)))
                                @compileError(comptimePrint(
                                    "Invalid Context type in {s}",
                                    .{@typeName(Segment)},
                                ));
                        }

                        const static_route_type =
                            if (Options.authenticated)
                                AuthStaticRoute(Segment, Path, Options)
                            else
                                StaticRoute(Segment, Path, Options);

                        Buffer.*[index] = .{
                            .name = comptimePrint("{}", .{index}),
                            .type = static_route_type,
                            .default_value_ptr = null,
                            .is_comptime = false,
                            .alignment = @alignOf(static_route_type),
                        };
                        index += 1;

                        break;
                    } else unreachable;
                }

                return index;
            }

            // Recursive function for counting static routes in `Segment`
            fn _countStaticRoutesInSegment(comptime Segment: type, comptime Options: ResourceTreeOptions) comptime_int {
                const segment_info = @typeInfo(Segment);
                var res = 0;

                for (segment_info.@"struct".decls) |decl| {
                    if (@TypeOf(@field(Segment, decl.name)) == type and
                        @typeInfo(@field(Segment, decl.name)) == .@"struct")
                    {
                        const struct_value: type = @field(Segment, decl.name);

                        if (Options.resource_type == .static and static_resource.isStaticResource(struct_value)) {
                            res += 1;
                            continue;
                        }

                        res += _countStaticRoutesInSegment(struct_value, Options);
                    } else if (@TypeOf(@field(Segment, decl.name)) != type and
                        @typeInfo(@TypeOf(@field(Segment, decl.name))) == .@"fn")
                    {
                        res += 1;
                        break;
                    } else unreachable;
                }

                return res;
            }
        };

        var static_route_count: comptime_int = 0;
        const resource_tree_set_info = @typeInfo(@TypeOf(ResourceTreeSet));
        const resource_tree_set_fields = resource_tree_set_info.@"struct".fields;

        // `ResourceTreeSet` validation
        if (resource_tree_set_info != .@"struct" or !resource_tree_set_info.@"struct".is_tuple)
            @compileError("`ResourceTreeSet` must be a tuple");
        if (resource_tree_set_info.@"struct".decls.len > 0)
            @compileError("`ResourceTreeSet` mustn't have any declarations");

        for (resource_tree_set_fields) |field| {
            if (field.type != type)
                @compileError("`ResourceTreeSet` must contain only fields of types");

            // ResourceTree validation
            const resource_tree_type: type = @field(ResourceTreeSet, field.name);
            if (!(@typeInfo(resource_tree_type) == .@"struct" and
                @hasDecl(resource_tree_type, "controller") and @typeInfo(resource_tree_type.controller) == .@"struct" and
                @hasDecl(resource_tree_type, "options") and @TypeOf(resource_tree_type.options) == ResourceTreeOptions))
                @compileError("`ResourceTreeSet` must contain only fields of ResourceTree types");

            const options: ResourceTreeOptions = resource_tree_type.options;

            // Static routes counting
            static_route_count += Gen._countStaticRoutesInSegment(resource_tree_type.controller, options);
        }

        // Generate StaticRoute fields from `ResourceTreeSet`
        var buffer: [static_route_count]std.builtin.Type.StructField = undefined;
        var generated_index: usize = 0;

        for (resource_tree_set_fields, 0..resource_tree_set_fields.len) |field, index| {
            const resource_tree_type: type = @field(ResourceTreeSet, field.name);

            for (resource_tree_set_fields[(index + 1)..]) |check_field| {
                const check_resource_tree_type: type = @field(ResourceTreeSet, check_field.name);
                if (std.mem.eql(
                    u8,
                    @typeInfo(resource_tree_type.controller).@"struct".decls[0].name,
                    @typeInfo(check_resource_tree_type.controller).@"struct".decls[0].name,
                )) @compileError("`ResourceTreeSet` must contain only ResourceTree types with unique root segment names");
            }

            generated_index = Gen._generateStaticRoutesFields(
                resource_tree_type.controller,
                resource_tree_type.options,
                "",
                static_route_count,
                &buffer,
                generated_index,
            );
        }

        // StaticRoutes path shadowing validation
        for (buffer, 0..buffer.len) |field, index| {
            const static_route_type =
                if (@hasDecl(field.type, "static_route") and @TypeOf(field.type.static_route) == type and
                @hasDecl(field.type, "auth_static_route") and @TypeOf(field.type.auth_static_route) == type)
                    field.type.static_route
                else
                    field.type;

            for (buffer, 0..buffer.len) |check_field, check_index| {
                if (index == check_index)
                    continue;

                const check_static_route_type =
                    if (@hasDecl(check_field.type, "static_route") and @TypeOf(check_field.type.static_route) == type and
                    @hasDecl(check_field.type, "auth_static_route") and @TypeOf(check_field.type.auth_static_route) == type)
                        check_field.type.static_route
                    else
                        check_field.type;

                if (std.mem.startsWith(u8, static_route_type.static_path, check_static_route_type.static_path))
                    @compileError(comptimePrint(
                        "StaticRoute path shadowing found, \"{s}\" starts with \"{s}\"",
                        .{
                            static_route_type.static_path,
                            check_static_route_type.static_path,
                        },
                    ));
            }
        }

        const static_routes_fields = buffer;

        return struct {
            const RouterType = @This();
            const AppType = Gen.App;

            pub const StaticRoutesSet = @Type(.{
                .@"struct" = .{
                    .layout = .auto,
                    .fields = static_routes_fields[0..],
                    .decls = &.{},
                    .is_tuple = false,
                },
            });

            static_routes_set: StaticRoutesSet,

            /// Initialize Router and its `static_routes_set` then register them to `application`
            pub fn init(self: *RouterType, authenticator: *AuthenticatorType) !void {
                inline for (@typeInfo(StaticRoutesSet).@"struct".fields) |static_route| {
                    const static_route_field_ptr = core.utils.fieldPtr(
                        StaticRoutesSet,
                        static_route.name,
                        &self.static_routes_set,
                    );

                    if (comptime static_route.type.resource_tree_options.authenticated) {
                        static_route_field_ptr.init(authenticator);
                        try AppType.register(&static_route_field_ptr.auth_sr);
                    } else {
                        static_route_field_ptr.* = .{};
                        try AppType.register(static_route_field_ptr);
                    }
                }
            }
        };
    }
};
