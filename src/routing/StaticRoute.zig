/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Method = std.http.Method;
const StructField = std.builtin.Type.StructField;

const hasMethod = std.meta.hasMethod;
const eql = std.mem.eql;
const cwd = std.fs.cwd;
const bufPrint = std.fmt.bufPrint;

/// Aura
const core = @import("../core.zig");

const ResourceOptions = core.routing.ResourceOptions;

const fieldPtr = core.utils.fieldPtr;
const isStaticResource = core.routing.isStaticResource;
const isAPIResource = core.routing.isAPIResource;
const isResourceParameters = core.routing.isResourceParameters;
const methodToLower = core.net.methodToLower;

const HeaderParameters = core.routing.HeaderParameters;
const EnforcedHeadersTag = core.routing.EnforcedHeadersTag;
const EnforcedHeaders = core.routing.EnforcedHeaders;

/// Third Party
const zeit = @import("zeit");

const Instatnt = zeit.Instant;
const Time = zeit.Time;

const zap = @import("zap");

const ErrorStrategy = zap.Endpoint.ErrorStrategy;
const Request = zap.Request;

const ResourceCategory = enum {
    static,
    api,

    fn fromType(comptime Type: type) ResourceCategory {
        if (isStaticResource(Type))
            return .static
        else if (isAPIResource(Type))
            return .api
        else
            @compileError("`Type` is not a supported ResourceCategory");
    }
};

/// Tuple type representing parameters of `MethodType`
fn MethodParameters(comptime MethodType: type) type {
    const method_info = @typeInfo(MethodType);
    var buffer: [method_info.@"fn".params.len]StructField = undefined;

    for (0..method_info.@"fn".params.len) |index| {
        if (method_info.@"fn".params[index].type == null)
            unreachable;
        const param_type = method_info.@"fn".params[index].type.?;

        buffer[index] = .{
            .name = std.fmt.comptimePrint("{}", .{index}),
            .type = param_type,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(param_type),
        };
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

/// Tuple type representing resource parameters of `MethodParametersType`
fn ResourceParameters(comptime MethodParametersType: type) type {
    const method_parameters_info = @typeInfo(MethodParametersType);
    var resource_parameters_count: usize = 0;

    for (method_parameters_info.@"struct".fields) |field| {
        if (isResourceParameters(@typeInfo(field.type).pointer.child))
            resource_parameters_count += 1;
    }

    var buffer: [resource_parameters_count]StructField = undefined;
    var assign_index: usize = 0;

    for (0..method_parameters_info.@"struct".fields.len) |index| {
        const resource_parameter_type = @typeInfo(method_parameters_info.@"struct".fields[index].type).pointer.child;
        if (!isResourceParameters(resource_parameter_type))
            continue;

        buffer[assign_index] = .{
            .name = std.fmt.comptimePrint("{}", .{assign_index}),
            .type = resource_parameter_type,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(resource_parameter_type),
        };
        assign_index += 1;
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

/// Structure for parsing requests and calling appropriate methods
pub fn StaticRoute(
    comptime ResourceType: type,
    comptime ContextType: type,
    comptime OnRequestProcessorType: type,
    comptime Path: []const u8,
    comptime Options: ResourceOptions,
) type {
    return struct {
        const StaticRouteType = @This();
        pub const static_path = Path;
        pub const resource_options = Options;
        pub const resource_category = ResourceCategory.fromType(ResourceType);

        path: []const u8 = Path,
        error_strategy: ErrorStrategy = Options.error_strategy,

        /// GET method called by zap
        pub fn get(_: *StaticRouteType, allocator: Allocator, context: *ContextType, request: Request) !void {
            switch (resource_category) {
                inline .static => _sendStaticResource(.GET, allocator, context, &request),
                inline .api => _callAPIMethod(.GET, allocator, context, &request),
            }
        }

        /// POST method called by zap
        pub fn post(_: *StaticRouteType, allocator: Allocator, context: *ContextType, request: Request) !void {
            switch (resource_category) {
                inline .static => _sendStaticResource(.POST, allocator, context, &request),
                inline .api => _callAPIMethod(.POST, allocator, context, &request),
            }
        }

        /// PUT method called by zap
        pub fn put(_: *StaticRouteType, allocator: Allocator, context: *ContextType, request: Request) !void {
            switch (resource_category) {
                inline .static => _sendStaticResource(.PUT, allocator, context, &request),
                inline .api => _callAPIMethod(.PUT, allocator, context, &request),
            }
        }

        /// DELETE method called by zap
        pub fn delete(_: *StaticRouteType, allocator: Allocator, context: *ContextType, request: Request) !void {
            switch (resource_category) {
                inline .static => _sendStaticResource(.DELETE, allocator, context, &request),
                inline .api => _callAPIMethod(.DELETE, allocator, context, &request),
            }
        }

        /// PATCH method called by zap
        pub fn patch(_: *StaticRouteType, allocator: Allocator, context: *ContextType, request: Request) !void {
            switch (resource_category) {
                inline .static => _sendStaticResource(.PATCH, allocator, context, &request),
                inline .api => _callAPIMethod(.PATCH, allocator, context, &request),
            }
        }

        /// OPTIONS method called by zap
        pub fn options(_: *StaticRouteType, allocator: Allocator, context: *ContextType, request: Request) !void {
            switch (resource_category) {
                inline .static => _sendStaticResource(.OPTIONS, allocator, context, &request),
                inline .api => _callAPIMethod(.OPTIONS, allocator, context, &request),
            }
        }

        /// HEAD method called by zap
        pub fn head(_: *StaticRouteType, allocator: Allocator, context: *ContextType, request: Request) !void {
            switch (resource_category) {
                inline .static => _sendStaticResource(.HEAD, allocator, context, &request),
                inline .api => _callAPIMethod(.HEAD, allocator, context, &request),
            }
        }

        /// Sends StaticResource and sets appropriate headers
        fn _sendStaticResource(comptime MethodType: Method, allocator: Allocator, context: *ContextType, request: *const Request) void {
            var processor: OnRequestProcessorType = undefined;
            processor.init(StaticRouteType, MethodType, allocator, context, request);
            defer processor.deinit();

            if (comptime !(MethodType == .GET or MethodType == .HEAD)) {
                if (comptime hasMethod(OnRequestProcessorType, "requestInvalid"))
                    processor.requestInvalid(error.UnsupportedMethod);
                request.setStatus(.method_not_allowed);
                return;
            }

            if (request.path == null or request.path.?.len != Path.len) {
                if (comptime hasMethod(OnRequestProcessorType, "requestInvalid"))
                    processor.requestInvalid(error.MalformedPath);
                request.setStatus(.not_found);
                return;
            }

            if (comptime MethodType == .GET) {
                var body_buffer: [ResourceType.sr_options.max_bytes + 1]u8 = undefined;
                const body = cwd().readFile(ResourceType.file_path, &body_buffer) catch |err| {
                    if (comptime hasMethod(OnRequestProcessorType, "readFileError"))
                        processor.readFileError(err);
                    request.setStatus(.internal_server_error);
                    return;
                };
                if (body.len >= body_buffer.len) {
                    if (comptime hasMethod(OnRequestProcessorType, "readFileError"))
                        processor.readFileError(error.FileToBig);
                    request.setStatus(.internal_server_error);
                    return;
                }

                _setStaticResourceHeaders(body.len, request) catch |err| {
                    if (comptime hasMethod(OnRequestProcessorType, "setHeadersError"))
                        processor.setHeadersError(err);
                    request.setStatus(.internal_server_error);
                    return;
                };

                request.sendBody(body) catch |err| {
                    if (comptime hasMethod(OnRequestProcessorType, "sendBodyError"))
                        processor.sendBodyError(err);
                    request.setStatus(.internal_server_error);
                    return;
                };
            } else if (comptime MethodType == .HEAD) {
                _setStaticResourceHeaders(0, request) catch |err| {
                    if (comptime hasMethod(OnRequestProcessorType, "setHeadersError"))
                        processor.setHeadersError(err);
                    request.setStatus(.internal_server_error);
                    return;
                };
            }

            if (comptime hasMethod(OnRequestProcessorType, "success"))
                processor.success(.ok);
        }

        /// Sets appropriate headers for StaticResource
        fn _setStaticResourceHeaders(_: usize, _: *const Request) !void {
            // REWORK
        }

        /// Calls API Method
        ///
        /// Correctness of `request` is checked in respective parsing functions
        fn _callAPIMethod(
            comptime MethodType: Method,
            allocator: Allocator,
            context: *ContextType,
            request: *const Request,
        ) void {
            var processor: OnRequestProcessorType = undefined;
            processor.init(StaticRouteType, MethodType, allocator, context, request);
            defer processor.deinit();

            if (comptime !hasMethod(ResourceType.controller_t, methodToLower(MethodType))) {
                if (comptime MethodType == .GET or MethodType == .HEAD) {
                    if (comptime hasMethod(OnRequestProcessorType, "requestInvalid"))
                        processor.requestInvalid(error.NotFound);
                    request.setStatus(.not_found);
                } else {
                    if (comptime hasMethod(OnRequestProcessorType, "requestInvalid"))
                        processor.requestInvalid(error.NotImplemented);
                    request.setStatus(.not_implemented);
                }
                return;
            }

            const method_fn = @field(ResourceType.controller_t, methodToLower(MethodType));
            const method_type = @TypeOf(method_fn);
            const resource_parameters_type = ResourceParameters(MethodParameters(method_type));

            var resource_parameters: resource_parameters_type = undefined;

            // Parse parameters
            comptime var has_header_parameters: bool = false;
            comptime var has_body_parameters: bool = false;

            inline for (@typeInfo(resource_parameters_type).@"struct".fields) |field| {
                switch (field.type.parameters_type) {
                    inline .header => has_header_parameters = true,
                    inline .body => has_body_parameters = true,
                    inline else => {},
                }
            }

            var query_parsed: ?bool = if (request.query == null) null else false;
            var body_parsed: ?bool = if (request.body == null) null else false;

            inline for (@typeInfo(resource_parameters_type).@"struct".fields) |field| {
                const parameters_ptr = fieldPtr(
                    resource_parameters_type,
                    field.name,
                    &resource_parameters,
                );

                switch (field.type.parameters_type) {
                    inline .path => {
                        // Path
                        field.type.parse(Path, allocator, request, parameters_ptr) catch |err| {
                            if (comptime hasMethod(OnRequestProcessorType, "parametersInvalid"))
                                processor.parametersInvalid(.path, err);
                            request.setStatus(.not_found);
                            return;
                        };
                    },
                    inline .query => {
                        // Query
                        field.type.parse(allocator, request, parameters_ptr) catch |err| {
                            if (comptime hasMethod(OnRequestProcessorType, "parametersInvalid"))
                                processor.parametersInvalid(.query, err);
                            request.setStatus(.not_found);
                            return;
                        };

                        query_parsed = true;
                    },
                    inline .header => {
                        // Header
                        field.type.parse(resource_options.strict_headers, allocator, request, parameters_ptr) catch |err| {
                            if (comptime hasMethod(OnRequestProcessorType, "parametersInvalid"))
                                processor.parametersInvalid(.header, err);
                            request.setStatus(.bad_request);
                            return;
                        };

                        // Enforced headers validation
                        if (comptime has_body_parameters) {
                            if ((request.body orelse "").len != parameters_ptr.data.content_length.length) {
                                if (comptime hasMethod(OnRequestProcessorType, "enforcedHeadersInvalid"))
                                    processor.enforcedHeadersInvalid(error.InvalidContentLength);
                                request.setStatus(.bad_request);
                                return;
                            }
                        }
                    },
                    inline .body => {
                        // Body
                        field.type.parse(allocator, request, parameters_ptr) catch |err| {
                            if (comptime hasMethod(OnRequestProcessorType, "parametersInvalid"))
                                processor.parametersInvalid(.body, err);
                            request.setStatus(.bad_request);
                            return;
                        };

                        body_parsed = true;
                    },
                }
            }

            // Enforced parameters parsing
            if (comptime !has_header_parameters) {
                const header_parameters_type =
                    HeaderParameters(
                        EnforcedHeaders(
                            EnforcedHeadersTag.generate(
                                resource_options.authenticate,
                                has_body_parameters,
                            ),
                        ),
                    );
                var header_parameters: header_parameters_type = undefined;

                header_parameters_type.parse(resource_options.strict_headers, allocator, request, &header_parameters) catch |err| {
                    if (comptime hasMethod(OnRequestProcessorType, "parametersInvalid"))
                        processor.parametersInvalid(.header, err);
                    request.setStatus(.bad_request);
                    return;
                };

                if (comptime has_body_parameters) {
                    if ((request.body orelse "").len != header_parameters.data.content_length.length) {
                        if (comptime hasMethod(OnRequestProcessorType, "enforcedHeadersInvalid"))
                            processor.enforcedHeadersInvalid(error.InvalidContentLength);
                        request.setStatus(.bad_request);
                        return;
                    }
                }
            }

            if (!(query_parsed orelse true)) {
                if (comptime hasMethod(OnRequestProcessorType, "requestInvalid"))
                    processor.requestInvalid(error.ExcessQuery);
                request.setStatus(.not_found);
                return;
            }
            if (!(body_parsed orelse true)) {
                if (comptime hasMethod(OnRequestProcessorType, "requestInvalid"))
                    processor.requestInvalid(error.ExcessBody);
                request.setStatus(.bad_request);
                return;
            }

            // Call method
            const call_result = @call(
                .always_inline,
                method_fn,
                _buildMethodParameters(
                    MethodParameters(method_type),
                    allocator,
                    context,
                    &resource_parameters,
                ),
            );

            if (comptime @typeInfo(@TypeOf(call_result)) == .error_union) {
                const status = call_result catch |err| {
                    if (comptime hasMethod(OnRequestProcessorType, "handlerError"))
                        processor.handlerError(err);
                    request.setStatus(.internal_server_error);
                    return;
                };
                if (comptime hasMethod(OnRequestProcessorType, "success"))
                    processor.success(.ok);
                request.setStatus(status);
            } else {
                if (comptime hasMethod(OnRequestProcessorType, "success"))
                    processor.success(.ok);
                request.setStatus(call_result);
            }
        }

        /// Builds MethodParameters from already initialized parameters
        fn _buildMethodParameters(
            comptime ParametersType: type,
            allocator: Allocator,
            context: *ContextType,
            resource_parameters: *const ResourceParameters(ParametersType),
        ) ParametersType {
            const parameters_info = @typeInfo(ParametersType);
            var res: ParametersType = undefined;

            inline for (parameters_info.@"struct".fields) |field| {
                const field_type = @typeInfo(field.type).pointer.child;

                if (comptime field_type == Allocator) {
                    fieldPtr(ParametersType, field.name, &res).* = allocator;
                } else if (comptime field_type == ContextType) {
                    fieldPtr(ParametersType, field.name, &res).* = context;
                } else if (comptime isResourceParameters(field_type)) {
                    const resource_parameters_info = @typeInfo(ResourceParameters(ParametersType));

                    inline for (resource_parameters_info.@"struct".fields) |res_param_field| {
                        if (comptime res_param_field.type.parameters_type == field_type.parameters_type)
                            fieldPtr(ParametersType, field.name, &res).* = fieldPtr(
                                ResourceParameters(ParametersType),
                                res_param_field.name,
                                resource_parameters,
                            );
                    }
                } else unreachable;
            }

            return res;
        }
    };
}

/// Structure for holding StaticRoute and it auth version
pub fn AuthStaticRoute(
    comptime ResourceType: type,
    comptime ContextType: type,
    comptime AuthenticatorType: type,
    comptime OnRequestProcessorType: type,
    comptime Path: []const u8,
    comptime Options: ResourceOptions,
) type {
    const App = zap.App.Create(ContextType);

    return struct {
        const AuthStaticRouteType = @This();
        const resource_t = ResourceType;
        pub const resource_options = Options;
        const static_route_t = StaticRoute(
            ResourceType,
            ContextType,
            OnRequestProcessorType,
            Path,
            Options,
        );
        const auth_static_route_t = App.Endpoint.Authenticating(static_route_t, AuthenticatorType);

        static_route: static_route_t,
        auth_static_route: auth_static_route_t,

        pub fn init(self: *AuthStaticRouteType, authenticator: *AuthenticatorType) void {
            self.static_route = .{};
            self.auth_static_route = auth_static_route_t.init(&self.static_route, authenticator);
        }
    };
}
