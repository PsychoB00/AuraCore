/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;
const StructField = std.builtin.Type.StructField;

const hasFn = std.meta.hasFn;
const cwd = std.fs.cwd;
const bufPrint = std.fmt.bufPrint;

/// Aura
const core = @import("../core.zig");

const ContentDisposition = core.net.ContentDisposition;
const CacheControl = core.net.CacheControl;
const LastModified = core.net.LastModified;

const ResourceOptions = core.routing.ResourceOptions;
const ResourceParametersError = core.routing.ResourceParametersError;

const fieldPtr = core.utils.fieldPtr;
const isStaticResource = core.routing.isStaticResource;
const isAPIResource = core.routing.isAPIResource;
const isResourceParameters = core.routing.isResourceParameters;

/// Third Party
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
    comptime Path: []const u8,
    comptime Options: ResourceOptions,
) type {
    return struct {
        const StaticRouteType = @This();
        pub const resource_options = Options;
        const resource_category = ResourceCategory.fromType(ResourceType);

        path: []const u8 = Path,
        error_strategy: ErrorStrategy = Options.error_strategy,

        /// GET method called by zap
        pub fn get(_: *@This(), allocator: Allocator, context: *ContextType, request: Request) !void {
            switch (resource_category) {
                inline .static => try _sendStaticResource(allocator, &request),
                inline .api => try _callAPIMethod("get", allocator, context, &request),
            }
        }

        /// POST method called by zap
        pub fn post(_: *@This(), allocator: Allocator, context: *ContextType, request: Request) !void {
            switch (resource_category) {
                inline .static => request.setStatus(.method_not_allowed),
                inline .api => try _callAPIMethod("post", allocator, context, &request),
            }
        }

        /// PUT method called by zap
        pub fn put(_: *@This(), allocator: Allocator, context: *ContextType, request: Request) !void {
            switch (resource_category) {
                inline .static => request.setStatus(.method_not_allowed),
                inline .api => try _callAPIMethod("put", allocator, context, &request),
            }
        }

        /// DELETE method called by zap
        pub fn delete(_: *@This(), allocator: Allocator, context: *ContextType, request: Request) !void {
            switch (resource_category) {
                inline .static => request.setStatus(.method_not_allowed),
                inline .api => try _callAPIMethod("delete", allocator, context, &request),
            }
        }

        /// PATCH method called by zap
        pub fn patch(_: *@This(), allocator: Allocator, context: *ContextType, request: Request) !void {
            switch (resource_category) {
                inline .static => request.setStatus(.method_not_allowed),
                inline .api => try _callAPIMethod("patch", allocator, context, &request),
            }
        }

        /// OPTIONS method called by zap
        pub fn options(_: *@This(), allocator: Allocator, context: *ContextType, request: Request) !void {
            switch (resource_category) {
                inline .static => request.setStatus(.method_not_allowed),
                inline .api => try _callAPIMethod("options", allocator, context, &request),
            }
        }

        /// HEAD method called by zap
        pub fn head(_: *@This(), allocator: Allocator, context: *ContextType, request: Request) !void {
            switch (resource_category) {
                inline .static => request.setStatus(.method_not_allowed),
                inline .api => try _callAPIMethod("head", allocator, context, &request),
            }
        }

        /// Sends StaticResource and sets appropriate headers
        fn _sendStaticResource(allocator: Allocator, request: *const Request) !void {
            if (request.path == null or request.path.?.len != Path.len) {
                request.setStatus(.not_found);
                return;
            }

            const body = try cwd().readFileAlloc(
                allocator,
                ResourceType.file_path,
                ResourceType.sr_options.max_bytes,
            );
            defer allocator.free(body);
            var content_length_buffer: [20]u8 = undefined;
            const content_length = try bufPrint(&content_length_buffer, "{}", .{body.len});

            try request.setContentTypeFromFilename(ResourceType.file_path);
            try request.setHeader("content-length", content_length);
            try request.setHeader("content-disposition", ContentDisposition.toString(ResourceType.sr_options.content_disposition));
            try request.setHeader("cache-control", CacheControl.toString(ResourceType.sr_options.cache_control));
            if (ResourceType.sr_options.last_modified) {
                const stat = try cwd().statFile(ResourceType.file_path);
                var buffer: [29]u8 = undefined;
                try LastModified.toString(stat, &buffer);
                try request.setHeader("last-modified", &buffer);
            }

            try request.sendBody(body);
        }

        /// Calls API Method
        ///
        /// Correctness of `request` is checked in respective parsing functions
        fn _callAPIMethod(
            comptime MethodName: []const u8,
            allocator: Allocator,
            context: *ContextType,
            request: *const Request,
        ) !void {
            if (comptime !hasFn(ResourceType.controller_t, MethodName)) {
                request.setStatus(.not_found);
                return;
            }

            const method_fn = @field(ResourceType.controller_t, MethodName);
            const method_type = @TypeOf(method_fn);

            const resource_parameters_type = ResourceParameters(
                MethodParameters(method_type),
            );

            var resource_parameters: resource_parameters_type = undefined;

            // Parse parameters
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
                        field.type.parse(Path.len, allocator, request, parameters_ptr) catch
                            return ResourceParametersError.NotFound;
                    },
                    inline .query => {
                        field.type.parse(allocator, request, parameters_ptr) catch
                            return ResourceParametersError.NotFound;

                        query_parsed = true;
                    },
                    inline .body => {
                        field.type.parse(allocator, request, parameters_ptr) catch
                            return ResourceParametersError.BadRequest;

                        body_parsed = true;
                    },
                }
            }

            if (!(query_parsed orelse true) or !(body_parsed orelse true))
                return ResourceParametersError.BadRequest;

            // Call method
            const call_result = @call(
                .always_inline,
                method_fn,
                _buildMethodParameters(
                    MethodParameters(method_type),
                    allocator,
                    context,
                    request,
                    &resource_parameters,
                ),
            );

            if (comptime @typeInfo(@TypeOf(call_result)) == .error_union)
                request.setStatus(call_result catch |err| return err)
            else
                request.setStatus(call_result);
        }

        /// Builds MethodParameters from already initialized parameters
        fn _buildMethodParameters(
            comptime ParametersType: type,
            allocator: Allocator,
            context: *ContextType,
            request: *const Request,
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
                } else if (comptime field_type == Request) {
                    fieldPtr(ParametersType, field.name, &res).* = request;
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
    comptime Path: []const u8,
    comptime Options: ResourceOptions,
) type {
    const App = zap.App.Create(ContextType);

    return struct {
        const AuthStaticRouteType = @This();
        const resource_t = ResourceType;
        pub const resource_options = Options;
        const static_route_t = StaticRoute(ResourceType, ContextType, Path, Options);
        const auth_static_route_t = App.Endpoint.Authenticating(static_route_t, AuthenticatorType);

        static_route: static_route_t,
        auth_static_route: auth_static_route_t,

        pub fn init(self: *AuthStaticRouteType, authenticator: *AuthenticatorType) void {
            self.static_route = .{};
            self.auth_static_route = auth_static_route_t.init(&self.static_route, authenticator);
        }
    };
}
