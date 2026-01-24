/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;
const Method = std.http.Method;
const StructField = std.builtin.Type.StructField;

const hasMethod = std.meta.hasMethod;
const eql = std.mem.eql;
const cwd = std.fs.cwd;
const bufPrint = std.fmt.bufPrint;

const buildin = @import("builtin");

const IsDebug = buildin.mode == .Debug;

/// Aura
const core = @import("../core.zig");

const ResourceOptions = core.routing.ResourceOptions;

const fieldPtr = core.utils.fieldPtr;
const assertValidate = core.utils.assertValidate;
const isStaticResource = core.routing.isStaticResource;
const isAPIResource = core.routing.isAPIResource;
const isResourceParameters = core.routing.isResourceParameters;
const isResourceResult = core.routing.isResourceResult;
const methodToLower = core.net.methodToLower;

const HeaderParameters = core.routing.HeaderParameters;
const RequiredHeadersTag = core.routing.RequiredHeadersTag;
const RequiredHeaders = core.routing.RequiredHeaders;
const ResultHeader = core.routing.ResultHeader;
const EnforcedHeadersTag = core.routing.EnforcedHeadersTag;
const EnforcedHeaders = core.routing.EnforcedHeaders;

const MediaType = core.net.headers.MediaType;

const ContentLength = core.net.headers.ContentLength;
const ContentType = core.net.headers.ContentType;
const Accept = core.net.headers.Accept;
const Authorization = core.net.headers.Authorization;
const WWWAuthenticate = core.net.headers.WWWAuthenticate;
const Challenge = WWWAuthenticate.Challenge;

/// Third Party
const zeit = @import("zeit");

const Instant = zeit.Instant;
const Time = zeit.Time;

const instant = zeit.instant;
const time = Instant.time;

const zap = @import("zap");

const StatusCode = zap.http.StatusCode;
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
        if (@typeInfo(field.type) == .pointer and isResourceParameters(@typeInfo(field.type).pointer.child))
            resource_parameters_count += 1;
    }

    var buffer: [resource_parameters_count]StructField = undefined;
    var assign_index: usize = 0;

    for (0..method_parameters_info.@"struct".fields.len) |index| field_loop: {
        if (@typeInfo(method_parameters_info.@"struct".fields[index].type) != .pointer)
            break :field_loop;

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

/// Tuple type representing resource result of `MethodParametersType`
fn ResourceResult(comptime MethodParametersType: type) type {
    const method_parameters_info = @typeInfo(MethodParametersType);
    var resource_result_count: usize = 0;

    for (method_parameters_info.@"struct".fields) |field| {
        if (@typeInfo(field.type) == .pointer and isResourceResult(@typeInfo(field.type).pointer.child))
            resource_result_count += 1;
    }

    var buffer: [resource_result_count]StructField = undefined;
    var assign_index: usize = 0;

    for (0..method_parameters_info.@"struct".fields.len) |index| field_loop: {
        if (@typeInfo(method_parameters_info.@"struct".fields[index].type) != .pointer)
            break :field_loop;

        const resource_result_type = @typeInfo(method_parameters_info.@"struct".fields[index].type).pointer.child;
        if (!isResourceResult(resource_result_type))
            continue;

        buffer[assign_index] = .{
            .name = std.fmt.comptimePrint("{}", .{assign_index}),
            .type = resource_result_type,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(resource_result_type),
        };
        assign_index += 1;
    }

    const resource_result_fields = buffer;

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = resource_result_fields[0..],
            .decls = &.{},
            .is_tuple = true,
        },
    });
}

/// Structure for parsing requests and calling appropriate methods
pub fn StaticRoute(
    comptime ResourceType: type,
    comptime ContextType: type,
    comptime AuthorizationProcessorType: ?type,
    comptime OnRequestProcessorType: ?type,
    comptime Path: []const u8,
    comptime Options: ResourceOptions,
) type {
    return struct {
        const StaticRouteType = @This();
        pub const static_path = Path;
        pub const resource_options = Options;
        pub const resource_category = ResourceCategory.fromType(ResourceType);

        authorization_processor: if (Options.authorize != null) *const (AuthorizationProcessorType.?) else void,
        path: []const u8 = Path,
        error_strategy: ErrorStrategy = Options.error_strategy,

        /// GET method called by zap
        pub fn get(self: *StaticRouteType, allocator: Allocator, context: *ContextType, request: Request) !void {
            switch (resource_category) {
                inline .static => self._sendStaticResource(.GET, allocator, context, &request),
                inline .api => self._callAPIMethod(.GET, allocator, context, &request),
            }
        }

        /// POST method called by zap
        pub fn post(self: *StaticRouteType, allocator: Allocator, context: *ContextType, request: Request) !void {
            switch (resource_category) {
                inline .static => self._sendStaticResource(.POST, allocator, context, &request),
                inline .api => self._callAPIMethod(.POST, allocator, context, &request),
            }
        }

        /// PUT method called by zap
        pub fn put(self: *StaticRouteType, allocator: Allocator, context: *ContextType, request: Request) !void {
            switch (resource_category) {
                inline .static => self._sendStaticResource(.PUT, allocator, context, &request),
                inline .api => self._callAPIMethod(.PUT, allocator, context, &request),
            }
        }

        /// DELETE method called by zap
        pub fn delete(self: *StaticRouteType, allocator: Allocator, context: *ContextType, request: Request) !void {
            switch (resource_category) {
                inline .static => self._sendStaticResource(.DELETE, allocator, context, &request),
                inline .api => self._callAPIMethod(.DELETE, allocator, context, &request),
            }
        }

        /// PATCH method called by zap
        pub fn patch(self: *StaticRouteType, allocator: Allocator, context: *ContextType, request: Request) !void {
            switch (resource_category) {
                inline .static => self._sendStaticResource(.PATCH, allocator, context, &request),
                inline .api => self._callAPIMethod(.PATCH, allocator, context, &request),
            }
        }

        /// OPTIONS method called by zap
        pub fn options(self: *StaticRouteType, allocator: Allocator, context: *ContextType, request: Request) !void {
            switch (resource_category) {
                inline .static => self._sendStaticResource(.OPTIONS, allocator, context, &request),
                inline .api => self._callAPIMethod(.OPTIONS, allocator, context, &request),
            }
        }

        /// HEAD method called by zap
        pub fn head(self: *StaticRouteType, allocator: Allocator, context: *ContextType, request: Request) !void {
            switch (resource_category) {
                inline .static => self._sendStaticResource(.HEAD, allocator, context, &request),
                inline .api => self._callAPIMethod(.HEAD, allocator, context, &request),
            }
        }

        /// Sends StaticResource and sets appropriate headers
        fn _sendStaticResource(
            self: *StaticRouteType,
            comptime MethodType: Method,
            allocator: Allocator,
            context: *ContextType,
            request: *const Request,
        ) void {
            var processor: (OnRequestProcessorType orelse void) = undefined;
            if (comptime OnRequestProcessorType != null) {
                processor.init(StaticRouteType, MethodType, allocator, context, request);
                defer processor.deinit();
            }

            if (comptime !(MethodType == .GET or MethodType == .HEAD)) {
                if (comptime (OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "invalidMethod")))
                    processor.invalidMethod(.method_not_allowed);
                request.setStatus(.method_not_allowed);
                return;
            }

            if (request.path == null or request.path.?.len != Path.len) {
                if (comptime (OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "invalidRequest")))
                    processor.invalidRequest(.not_found, error.InvalidPath);
                request.setStatus(.not_found);
                return;
            }

            // Required headers parsing
            const required_headers_type =
                HeaderParameters(RequiredHeaders(RequiredHeadersTag.generate(.{
                    .has_body_parameters = false,
                    .has_authorization = resource_options.authorize != null,
                    .has_result_body = true,
                })));

            var required_headers: required_headers_type = undefined;

            const successful_header_parse =
                _parseHeaderParameters(
                    required_headers_type,
                    request,
                    &required_headers,
                    allocator,
                    if (OnRequestProcessorType != null) &processor else {},
                );

            if (!successful_header_parse)
                return;

            // Authorization
            if (comptime Options.authorize != null) {
                var claims_set: AuthorizationProcessorType.?.claims_set_t = undefined;

                const successful_authorization =
                    _authorize(
                        MethodType,
                        self.authorization_processor,
                        &required_headers.data.authorization,
                        &claims_set,
                        request,
                        allocator,
                        if (OnRequestProcessorType != null) &processor else {},
                    );

                if (!successful_authorization)
                    return;
            }

            // Accept
            const succesful_accept =
                _acceptable(
                    ResourceType.infered_media_type,
                    &required_headers.data.accept,
                    request,
                    if (OnRequestProcessorType != null) &processor else {},
                );

            if (!succesful_accept)
                return;

            comptime var status_code: StatusCode = undefined;

            if (comptime MethodType == .HEAD) {
                // Set EnforcedHeaders
                comptime status_code = .no_content;

                const enforced_headers_type =
                    ResultHeader(EnforcedHeaders(EnforcedHeadersTag.generate(.{
                        .has_result_body = false,
                    })));

                var enforced_headers: enforced_headers_type = .{
                    .data = .{
                        .date = .{
                            .time = time(instant(.{}) catch unreachable),
                        },
                    },
                };

                const successful_header_set =
                    _setResultHeader(
                        enforced_headers_type,
                        request,
                        &enforced_headers,
                        allocator,
                        if (OnRequestProcessorType != null) &processor else {},
                    );

                if (!successful_header_set)
                    return;
            } else if (comptime MethodType == .GET) {
                // Read body
                comptime status_code = .ok;

                var body_buffer: [ResourceType.sr_options.max_bytes + 1]u8 = undefined;
                const body = cwd().readFile(ResourceType.file_path, &body_buffer) catch |err| {
                    if (comptime (OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "readFileCrash")))
                        processor.readFileCrash(err);
                    unreachable;
                };
                if (body.len >= body_buffer.len) {
                    if (comptime (OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "readFileCrash")))
                        processor.readFileCrash(error.FileToBig);
                    unreachable;
                }

                // Set EnforcedHeaders
                const enforced_headers_type =
                    ResultHeader(EnforcedHeaders(EnforcedHeadersTag.generate(.{
                        .has_result_body = true,
                    })));

                var enforced_headers: enforced_headers_type = .{
                    .data = .{
                        .date = .{
                            .time = time(instant(.{}) catch unreachable),
                        },
                        .content_length = .{
                            .length = body.len,
                        },
                        .content_type = .{
                            .media_type = ResourceType.infered_media_type,
                        },
                    },
                };

                const successful_header_set =
                    _setResultHeader(
                        enforced_headers_type,
                        request,
                        &enforced_headers,
                        allocator,
                        if (OnRequestProcessorType != null) &processor else {},
                    );

                if (!successful_header_set)
                    return;

                // Send body
                request.sendBody(body) catch |err| {
                    if (comptime (OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "sendBodyError")))
                        processor.sendBodyError(.internal_server_error, err, if (comptime IsDebug) @errorReturnTrace().?.* else {});
                    request.setStatus(.internal_server_error);
                    return;
                };
            } else unreachable;

            if (comptime (OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "success")))
                processor.success(status_code);
            request.setStatus(status_code);
        }

        /// Calls API Method
        ///
        /// Correctness of `request` is checked in respective parsing functions
        fn _callAPIMethod(
            self: *StaticRouteType,
            comptime MethodType: Method,
            allocator: Allocator,
            context: *ContextType,
            request: *const Request,
        ) void {
            // Init OnRequestProcessor
            var processor: (OnRequestProcessorType orelse void) = undefined;
            if (comptime OnRequestProcessorType != null) {
                processor.init(StaticRouteType, MethodType, allocator, context, request);
                defer processor.deinit();
            }

            if (comptime !hasMethod(ResourceType.controller_t, methodToLower(MethodType))) {
                if (comptime (OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "invalidMethod")))
                    processor.invalidMethod(.not_implemented);
                request.setStatus(.not_implemented);
                return;
            }

            const method_fn = @field(ResourceType.controller_t, methodToLower(MethodType));
            const method_type = @TypeOf(method_fn);
            const method_parameters_type = MethodParameters(method_type);

            // Create ResourceParameters
            const resource_parameters_type = ResourceParameters(method_parameters_type);

            var resource_parameters: resource_parameters_type = undefined;

            // Create ResourceResult
            const resource_result_type = ResourceResult(method_parameters_type);

            var resource_result: resource_result_type = undefined;

            // Get HeaderParameters and ResultHeader info
            comptime var header_parameters_field: ?StructField = null;
            comptime var result_header_field: ?StructField = null;
            comptime var body_parameters_found: ?type = null;
            comptime var result_body_field: ?StructField = null;

            inline for (@typeInfo(resource_parameters_type).@"struct".fields) |field| {
                switch (field.type.parameters_type) {
                    inline .header => header_parameters_field = field,
                    inline .body => body_parameters_found = field.type,
                    inline else => {},
                }
            }
            inline for (@typeInfo(resource_result_type).@"struct".fields) |field| {
                switch (field.type.result_type) {
                    inline .body => result_body_field = field,
                    inline .header => result_header_field = field,
                }
            }

            const header_parameters_type =
                comptime if (header_parameters_field == null)
                    HeaderParameters(RequiredHeaders(RequiredHeadersTag.generate(.{
                        .has_body_parameters = body_parameters_found != null,
                        .has_authorization = resource_options.authorize != null,
                        .has_result_body = result_body_field != null,
                    })))
                else
                    header_parameters_field.?.type;

            const result_header_type =
                comptime if (result_header_field == null)
                    ResultHeader(EnforcedHeaders(EnforcedHeadersTag.generate(.{
                        .has_result_body = result_body_field != null,
                    })))
                else
                    result_header_field.?.type;

            // Parse RequiredHeaders or HeaderParameters
            var header_parameters: header_parameters_type = undefined;
            var header_parameters_ptr: *header_parameters_type = undefined;

            if (comptime header_parameters_field == null) {
                // RequiredHeaders
                const successful_header_parse =
                    _parseHeaderParameters(
                        header_parameters_type,
                        request,
                        &header_parameters,
                        allocator,
                        if (OnRequestProcessorType != null) &processor else {},
                    );

                if (!successful_header_parse)
                    return;

                header_parameters_ptr = &header_parameters;
            } else {
                // HeaderParameters
                const parameters_ptr = fieldPtr(
                    resource_parameters_type,
                    header_parameters_field.?.name,
                    &resource_parameters,
                );

                const successful_header_parse =
                    _parseHeaderParameters(
                        header_parameters_field.?.type,
                        request,
                        parameters_ptr,
                        allocator,
                        if (OnRequestProcessorType != null) &processor else {},
                    );

                if (!successful_header_parse)
                    return;

                header_parameters_ptr = parameters_ptr;
            }

            // Content headers
            if (comptime body_parameters_found != null) {
                const successful_content_headers_validation =
                    _validateContentHeaders(
                        &body_parameters_found.?.allowed_media_types_array,
                        &header_parameters_ptr.data.content_length,
                        &header_parameters_ptr.data.content_type,
                        request,
                        if (OnRequestProcessorType != null) &processor else {},
                    );

                if (!successful_content_headers_validation)
                    return;
            }

            // Authorization
            var claims_set: if (AuthorizationProcessorType != null) AuthorizationProcessorType.?.claims_set_t else void = undefined;

            if (comptime Options.authorize != null) {
                const successful_authorization =
                    _authorize(
                        MethodType,
                        self.authorization_processor,
                        &header_parameters_ptr.data.authorization,
                        &claims_set,
                        request,
                        allocator,
                        if (OnRequestProcessorType != null) &processor else {},
                    );

                if (!successful_authorization)
                    return;
            }

            // Accept
            if (result_body_field != null) {
                const succesful_accept =
                    _acceptable(
                        result_body_field.?.type.result_media_type,
                        &header_parameters_ptr.data.accept,
                        request,
                        if (OnRequestProcessorType != null) &processor else {},
                    );

                if (!succesful_accept)
                    return;
            }

            // Parse all yet to be parsed parameters
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
                        field.type.parse(Path, request, parameters_ptr, allocator) catch |err| {
                            if (comptime (OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "invalidParameters")))
                                processor.invalidParameters(.path, .not_found, err);
                            request.setStatus(.not_found);
                            return;
                        };
                    },
                    inline .query => {
                        // Query
                        field.type.parse(request, parameters_ptr, allocator) catch |err| {
                            if (comptime (OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "invalidParameters")))
                                processor.invalidParameters(.query, .not_found, err);
                            request.setStatus(.not_found);
                            return;
                        };

                        query_parsed = true;
                    },
                    inline .header => {
                        // Header
                    },
                    inline .body => {
                        // Body
                        field.type.parse(request, parameters_ptr, &header_parameters_ptr.data.content_length, &header_parameters_ptr.data.content_type, allocator) catch |err| {
                            if (comptime (OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "invalidParameters")))
                                processor.invalidParameters(.body, .bad_request, err);
                            request.setStatus(.bad_request);
                            return;
                        };

                        body_parsed = true;
                    },
                }
            }

            if (!(query_parsed orelse true)) {
                if (comptime (OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "invalidRequest")))
                    processor.invalidRequest(.not_found, error.ExcessQuery);
                request.setStatus(.not_found);
                return;
            }
            if (!(body_parsed orelse true)) {
                if (comptime (OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "invalidRequest")))
                    processor.invalidRequest(.bad_request, error.ExcessBody);
                request.setStatus(.bad_request);
                return;
            }

            // Call method
            const call_result = @call(
                .never_inline,
                method_fn,
                _buildMethodParameters(
                    MethodParameters(method_type),
                    &resource_parameters,
                    if (AuthorizationProcessorType != null) &claims_set else void,
                    context,
                    allocator,
                    &resource_result,
                ),
            );

            // Get status
            var status: StatusCode = undefined;
            if (comptime @typeInfo(@TypeOf(call_result)) == .error_union) {
                status = call_result catch |err| {
                    if (comptime (OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "controllerError")))
                        processor.controllerError(.internal_server_error, err, if (comptime IsDebug) @errorReturnTrace().?.* else {});
                    request.setStatus(.internal_server_error);
                    return;
                };
            } else status = call_result;

            // Get ResultBody
            var result_body_buffer: []u8 = undefined;

            if (result_body_field != null) {
                const result_body_ptr = fieldPtr(
                    resource_result_type,
                    result_body_field.?.name,
                    &resource_result,
                );

                result_body_ptr.format(&result_body_buffer, allocator) catch |err| {
                    if (comptime (OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "formatResultCrash")))
                        processor.formatResultCrash(.body, err);
                    unreachable;
                };
            }

            // Set ResultHeader or EnforcedHeaders
            if (result_header_field == null) {
                // EnforcedHeaders
                const result_header: result_header_type =
                    if (comptime result_body_field != null)
                        .{
                            .data = .{
                                .date = .{
                                    .time = time(instant(.{}) catch unreachable),
                                },
                                .content_length = .{
                                    .length = result_body_buffer.len,
                                },
                                .content_type = .{
                                    .media_type = result_body_field.?.type.result_media_type,
                                },
                            },
                        }
                    else
                        .{
                            .data = .{
                                .date = .{
                                    .time = time(instant(.{}) catch unreachable),
                                },
                            },
                        };

                const successful_header_set =
                    _setResultHeader(
                        result_header_type,
                        request,
                        &result_header,
                        allocator,
                        if (OnRequestProcessorType != null) &processor else {},
                    );

                if (!successful_header_set)
                    return;
            } else {
                // ResultHeader
                const result_header_ptr =
                    fieldPtr(resource_result_type, result_header_field.?.name, &resource_result);

                const successful_header_set =
                    _setResultHeader(
                        result_header_type,
                        request,
                        result_header_ptr,
                        allocator,
                        if (OnRequestProcessorType != null) &processor else {},
                    );

                if (!successful_header_set)
                    return;
            }

            // Send ResourceResult
            if (result_body_field != null) {
                request.sendBody(result_body_buffer) catch |err| {
                    if (comptime (OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "sendBodyError")))
                        processor.sendBodyError(.internal_server_error, err, if (comptime IsDebug) @errorReturnTrace().?.* else {});
                    request.setStatus(.internal_server_error);
                    return;
                };
            }

            if (comptime (OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "success")))
                processor.success(status);
            request.setStatus(status);
        }

        fn _buildMethodParameters(
            comptime ParametersType: type,
            resource_parameters: *const ResourceParameters(ParametersType),
            claims_set: if (AuthorizationProcessorType != null) *AuthorizationProcessorType.?.claims_set_t else void,
            context: *ContextType,
            allocator: Allocator,
            resource_result: *ResourceResult(ParametersType),
        ) ParametersType {
            const parameters_info = @typeInfo(ParametersType);
            var res: ParametersType = undefined;

            inline for (parameters_info.@"struct".fields) |field| {
                const field_type =
                    if (comptime @typeInfo(field.type) == .pointer)
                        @typeInfo(field.type).pointer.child
                    else
                        field.type;

                if (comptime field_type == Allocator) {
                    fieldPtr(ParametersType, field.name, &res).* = allocator;
                } else if (comptime AuthorizationProcessorType != null and field_type == AuthorizationProcessorType.?.claims_set_t) {
                    fieldPtr(ParametersType, field.name, &res).* = claims_set;
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
                } else if (comptime isResourceResult(field_type)) {
                    const resource_result_info = @typeInfo(ResourceResult(ParametersType));

                    inline for (resource_result_info.@"struct".fields) |res_result_field| {
                        if (comptime res_result_field.type.result_type == field_type.result_type)
                            fieldPtr(ParametersType, field.name, &res).* = fieldPtr(
                                ResourceResult(ParametersType),
                                res_result_field.name,
                                resource_result,
                            );
                    }
                } else unreachable;
            }

            return res;
        }

        fn _parseHeaderParameters(
            comptime HeaderParametersType: type,
            request: *const Request,
            header_parameters: *HeaderParametersType,
            allocator: Allocator,
            processor: if (OnRequestProcessorType != null) *(OnRequestProcessorType.?) else void,
        ) bool {
            HeaderParametersType.parse(
                resource_options.strict_headers,
                request,
                header_parameters,
                allocator,
            ) catch |err| switch (err) {
                error.Unauthorized => {
                    if (comptime Options.authorize == null)
                        // Branch can't ever occur, needs to be pruned for compiler
                        return false;

                    var challenges: [WWWAuthenticate.challenges_capacity]Challenge = undefined;
                    var challenge_count: usize = 0;

                    AuthorizationProcessorType.?.raiseChallenge(
                        Options.authorize.?,
                        &challenges,
                        &challenge_count,
                        error.MissingAuthorizationHeader,
                    );

                    const successful_set_www_authenticate =
                        _setWWWAuthentication(
                            challenges,
                            challenge_count,
                            request,
                            if (OnRequestProcessorType != null) processor else {},
                        );

                    if (!successful_set_www_authenticate)
                        return false;

                    if (comptime (OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "invalidAuthorization")))
                        processor.invalidAuthorization(.unauthorized);
                    request.setStatus(.unauthorized);
                    return false;
                },
                else => {
                    if (comptime (OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "invalidParameters")))
                        processor.invalidParameters(.header, .bad_request, err);
                    request.setStatus(.bad_request);
                    return false;
                },
            };

            return true;
        }

        fn _validateContentHeaders(
            comptime AllowedMediaTypes: []const MediaType,
            content_length: *const ContentLength,
            content_type: *const ContentType,
            request: *const Request,
            processor: if (OnRequestProcessorType != null) *(OnRequestProcessorType.?) else void,
        ) bool {
            if ((request.body orelse "").len != content_length.length) {
                if (comptime (OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "invalidParameters")))
                    processor.invalidParameters(.header, .bad_request, error.InvalidContentLength);
                request.setStatus(.bad_request);
                return false;
            }

            var allowed_media_type: ?*const MediaType = null;
            inline for (AllowedMediaTypes) |media_type| media_type_loop: {
                if (!MediaType.areOverlapping(content_type.media_type, media_type))
                    break :media_type_loop;

                allowed_media_type = &media_type;
            }

            if (allowed_media_type == null) {
                if (comptime (OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "invalidParameters")))
                    processor.invalidParameters(.header, .unsupported_media_type, error.InvalidContentType);
                request.setStatus(.unsupported_media_type);
                return false;
            }

            return true;
        }

        fn _authorize(
            comptime MethodType: Method,
            authorization_processor: *const (AuthorizationProcessorType.?),
            authorization_header: *const Authorization,
            claims_set: *AuthorizationProcessorType.?.claims_set_t,
            request: *const Request,
            allocator: Allocator,
            processor: if (OnRequestProcessorType != null) *(OnRequestProcessorType.?) else void,
        ) bool {
            var challenges: [WWWAuthenticate.challenges_capacity]Challenge = undefined;
            var challenge_count: usize = 0;

            const authorization_result =
                authorization_processor.authorize(
                    MethodType,
                    Options.authorize.?,
                    authorization_header,
                    claims_set,
                    &challenges,
                    &challenge_count,
                    allocator,
                );

            if (authorization_result != .authorized) {
                const successful_set_www_authenticate =
                    _setWWWAuthentication(
                        challenges,
                        challenge_count,
                        request,
                        if (OnRequestProcessorType != null) processor else {},
                    );

                if (!successful_set_www_authenticate)
                    return false;
            }

            switch (authorization_result) {
                .unauthorized => {
                    if (comptime (OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "invalidAuthorization")))
                        processor.invalidAuthorization(.unauthorized);
                    request.setStatus(.unauthorized);
                    return false;
                },
                .forbidden => {
                    if (comptime (OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "invalidAuthorization")))
                        processor.invalidAuthorization(.forbidden);
                    request.setStatus(.forbidden);
                    return false;
                },
                .authorized => return true,
            }
        }

        fn _acceptable(
            comptime AcceptableMediaType: MediaType,
            accept_header: *const Accept,
            request: *const Request,
            processor: if (OnRequestProcessorType != null) *(OnRequestProcessorType.?) else void,
        ) bool {
            var accept_result: bool = false;

            for (accept_header.media_ranges) |media_range| {
                if (media_range.media_type.areOverlapping(AcceptableMediaType)) {
                    accept_result = true;
                    break;
                }
            }

            if (!accept_result) {
                if (comptime (OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "invalidParameters")))
                    processor.invalidParameters(.header, .not_acceptable, error.InvalidAccept);
                request.setStatus(.not_acceptable);
            }

            return accept_result;
        }

        fn _setResultHeader(
            comptime ResultHeaderType: type,
            request: *const Request,
            result_headers: *const ResultHeaderType,
            allocator: Allocator,
            processor: if (OnRequestProcessorType != null) *(OnRequestProcessorType.?) else void,
        ) bool {
            const result_header_structure_info = @typeInfo(ResultHeaderType.structure);

            var header_buffers: [result_header_structure_info.@"struct".fields.len][]u8 = undefined;

            ResultHeaderType.format(
                result_headers,
                &header_buffers,
                allocator,
            ) catch |err| {
                if (comptime (OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "formatResultCrash")))
                    processor.formatResultCrash(.header, err);
                unreachable;
            };

            inline for (result_header_structure_info.@"struct".fields, 0..) |field, index| {
                request.setHeader(field.type.http_header_name, header_buffers[index]) catch |err| {
                    if (comptime (OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "setHeadersError")))
                        processor.setHeadersError(.internal_server_error, err, if (comptime IsDebug) @errorReturnTrace().?.* else {});
                    request.setStatus(.internal_server_error);
                    return false;
                };
            }

            return true;
        }

        fn _setWWWAuthentication(
            challenges: [WWWAuthenticate.challenges_capacity]Challenge,
            challenge_count: usize,
            request: *const Request,
            processor: if (OnRequestProcessorType != null) *(OnRequestProcessorType.?) else void,
        ) bool {
            const www_authenticate_header: WWWAuthenticate = .{ .challenges = challenges[0..challenge_count] };

            var www_authenticate_buffer: [WWWAuthenticate.max_value_len]u8 = undefined;
            const www_authenticate = bufPrint(&www_authenticate_buffer, "{f}", .{www_authenticate_header}) catch unreachable;

            request.setHeader(WWWAuthenticate.http_header_name, www_authenticate) catch |err| {
                if (comptime (OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "setHeadersError")))
                    processor.setHeadersError(.internal_server_error, err, if (comptime IsDebug) @errorReturnTrace().?.* else {});
                request.setStatus(.internal_server_error);
                return false;
            };

            return true;
        }
    };
}
