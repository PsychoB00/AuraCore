/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;
const Method = std.http.Method;
const StructField = std.builtin.Type.StructField;

const comptimePrint = std.fmt.comptimePrint;
const hasMethod = std.meta.hasMethod;
const eql = std.mem.eql;
const cwd = std.fs.cwd;
const bufPrint = std.fmt.bufPrint;

const buildin = @import("builtin");

const IsDebug = buildin.mode == .Debug;

/// Aura
const core = @import("../core.zig");

const ResourceOptions = core.routing.ResourceOptions;
const ResourceParametersType = core.routing.ParametersType;
const ResourceResultType = core.routing.ResultType;

const fieldPtr = core.utils.fieldPtr;
const assertValidate = core.utils.assertValidate;
const isStaticResource = core.routing.isStaticResource;
const isAPIResource = core.routing.isAPIResource;
const isResourceParameters = core.routing.isResourceParameters;
const isResourceResult = core.routing.isResourceResult;
const methodToLower = core.net.methodToLower;
const isStatusCodeSuccess = core.net.isStatusCodeSuccess;
const isStatusCodeRedirect = core.net.isStatusCodeRedirect;

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
const Location = core.net.headers.Location;
const Allow = core.net.headers.Allow;

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
            .name = comptimePrint("{d}", .{assign_index}),
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

        /// Declarations for parsing request, calling `MethodType` and formating result
        fn StaticMethodInfo(comptime MethodType: Method) type {
            return struct {
                // General info
                const has_method = hasMethod(ResourceType.controller_t, methodToLower(MethodType));
                const has_authorization = resource_options.authorize != null;
                const has_ap = AuthorizationProcessorType != null;

                // OnRequestProcessor info
                const orp_type = OnRequestProcessorType orelse void;
                const has_orp = orp_type != void;
                const has_orp_invalid_method = OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "invalidMethod");
                const has_orp_invalid_request = OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "invalidRequest");
                const has_orp_read_file_crash = OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "readFileCrash");
                const has_orp_send_body_error = OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "sendBodyError");
                const has_orp_set_headers_error = OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "setHeadersError");
                const has_orp_success = OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "success");

                // HeaderParameters info
                const required_headers_type =
                    HeaderParameters(RequiredHeaders(RequiredHeadersTag.generate(.{
                        .has_body_parameters = false,
                        .has_authorization = resource_options.authorize != null,
                        .has_result_body = true,
                    })));

                const status: StatusCode = if (MethodType == .HEAD) .no_content else .ok;

                // ClaimSet info
                const claim_set_type = if (AuthorizationProcessorType != null) AuthorizationProcessorType.?.claims_set_t else void;

                // ResultHeader info
                const enforced_headers_type =
                    if (MethodType == .HEAD)
                        ResultHeader(EnforcedHeaders(EnforcedHeadersTag.generate(.{
                            .has_result_body = false,
                        })))
                    else
                        ResultHeader(EnforcedHeaders(EnforcedHeadersTag.generate(.{
                            .has_result_body = true,
                        })));

                const VariablesSet = struct {
                    orp: orp_type,
                    claims_set: claim_set_type,

                    required_headers: required_headers_type,

                    enforced_headers: enforced_headers_type,
                    result_body_buffer: [ResourceType.sr_options.max_bytes + 1]u8,
                    result_body: []u8,
                };
            };
        }

        /// Declarations for parsing request, calling `MethodType` and formating result
        fn APIMethodInfo(comptime MethodType: Method) type {
            const Gen = struct {
                fn _getResourceParameterField(comptime Type: type, comptime ParamType: ResourceParametersType) ?StructField {
                    for (@typeInfo(Type).@"struct".fields) |field| {
                        if (@intFromEnum(field.type.parameters_type) == @intFromEnum(ParamType))
                            return field;
                    }
                    return null;
                }

                fn _getResultHeaderField(comptime Type: type, comptime ResultHeaderType: type) ?StructField {
                    const result_header_structure =
                        if (@typeInfo(ResultHeaderType.structure) == .optional)
                            @typeInfo(ResultHeaderType.structure).optional.child
                        else
                            ResultHeaderType.structure;

                    for (@typeInfo(result_header_structure).@"struct".fields) |field| {
                        const field_type =
                            if (@typeInfo(field.type) == .optional)
                                @typeInfo(field.type).optional.child
                            else
                                field.type;

                        if (field_type == Type)
                            return field;
                    }
                    return null;
                }

                fn _getResourceResultField(comptime Type: type, comptime ResultType: ResourceResultType) ?StructField {
                    for (@typeInfo(Type).@"struct".fields) |field| {
                        if (@intFromEnum(field.type.result_type) == @intFromEnum(ResultType))
                            return field;
                    }
                    return null;
                }
            };

            return if (!hasMethod(ResourceType.controller_t, methodToLower(MethodType)))
                struct {
                    // General info
                    const has_method = hasMethod(ResourceType.controller_t, methodToLower(MethodType));

                    // OnRequestProcessor info
                    const orp_type = OnRequestProcessorType orelse void;
                    const has_orp = orp_type != void;
                    const has_orp_invalid_method = has_orp and hasMethod(OnRequestProcessorType.?, "invalidMethod");

                    // VariablesSet declaration
                    const VariablesSet = struct {
                        orp: orp_type,
                    };
                }
            else
                struct {
                    // Method info
                    const method_fn = @field(ResourceType.controller_t, methodToLower(MethodType));
                    const method_parameters_type = MethodParameters(@TypeOf(method_fn));

                    // General info
                    const has_method = hasMethod(ResourceType.controller_t, methodToLower(MethodType));
                    const has_authorization = resource_options.authorize != null;
                    const has_ap = AuthorizationProcessorType != null;
                    const has_error_return = @typeInfo(@typeInfo(@TypeOf(method_fn)).@"fn".return_type.?) == .error_union;

                    // OnRequestProcessor info
                    const orp_type = OnRequestProcessorType orelse void;
                    const has_orp = orp_type != void;
                    const has_orp_invalid_method = has_orp and hasMethod(OnRequestProcessorType.?, "invalidMethod");
                    const has_orp_invalid_parameters = has_orp and hasMethod(OnRequestProcessorType.?, "invalidParameters");
                    const has_orp_invalid_request = has_orp and hasMethod(OnRequestProcessorType.?, "invalidRequest");
                    const has_orp_controller_error = has_orp and hasMethod(OnRequestProcessorType.?, "controllerError");
                    const has_orp_match_status_to_result_crash = OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "matchStatusCodeToResultCrash");
                    const has_orp_result_composition_crash = OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "resultCompositionCrash");
                    const has_orp_format_result_crash = OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "formatResultCrash");
                    const has_orp_send_body_error = OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "sendBodyError");
                    const has_orp_redirect_error = OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "redirectError");
                    const has_orp_success = OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "success");
                    const has_orp_redirect = OnRequestProcessorType != null and hasMethod(OnRequestProcessorType.?, "redirect");

                    // ClaimSet info
                    const claim_set_type = if (AuthorizationProcessorType != null) AuthorizationProcessorType.?.claims_set_t else void;

                    // Method parameters and result info
                    const resource_parameters_type = ResourceParameters(method_parameters_type);
                    const resource_result_type = ResourceResult(method_parameters_type);

                    // ResourceParameters info
                    const path_parameters_field = Gen._getResourceParameterField(resource_parameters_type, .path);
                    const query_parameters_field = Gen._getResourceParameterField(resource_parameters_type, .query);
                    const header_parameters_field = Gen._getResourceParameterField(resource_parameters_type, .header);
                    const body_parameters_field = Gen._getResourceParameterField(resource_parameters_type, .body);
                    const has_path_parameters = path_parameters_field != null;
                    const has_query_parameters = path_parameters_field != null;
                    const has_header_parameters = path_parameters_field != null;
                    const has_body_parameters = path_parameters_field != null;

                    // HeaderParameters info
                    const header_parameters_type =
                        if (header_parameters_field == null)
                            HeaderParameters(RequiredHeaders(RequiredHeadersTag.generate(.{
                                .has_body_parameters = body_parameters_field != null,
                                .has_authorization = resource_options.authorize != null,
                                .has_result_body = result_body_field != null,
                            })))
                        else
                            header_parameters_field.?.type;

                    // ResourceResult info
                    const result_header_field = Gen._getResourceResultField(resource_result_type, .header);
                    const result_body_field = Gen._getResourceResultField(resource_result_type, .body);
                    const result_redirect_field = Gen._getResourceResultField(resource_result_type, .redirect);
                    const has_result_header = result_header_field != null;
                    const has_result_body = result_body_field != null;
                    const has_result_redirect = result_redirect_field != null;

                    // ResultHeader info
                    const result_header_type =
                        if (has_result_header)
                            result_header_field.?.type
                        else
                            ResultHeader(EnforcedHeaders(EnforcedHeadersTag.generate(.{
                                .has_result_body = result_body_field != null,
                            })));
                    const is_result_header_optional: ?bool =
                        if (has_result_header)
                            @typeInfo(result_header_type.structure) == .optional
                        else
                            null;
                    const result_header_structure =
                        if (is_result_header_optional)
                            @typeInfo(result_header_type.structure).optional.child
                        else
                            result_header_type.structure;
                    const result_header_location_field = Gen._getResultHeaderField(Location, result_header_type);
                    const has_result_header_location = result_header_location_field != null;
                    const is_result_header_location_optional =
                        if (has_result_header_location)
                            @typeInfo(result_header_location_field.?.type) == .optional
                        else
                            null;

                    // ResultBody info
                    const result_body_type =
                        if (has_result_body)
                            result_body_field.?.type
                        else
                            void;
                    const is_result_body_optional: ?bool =
                        if (has_result_body)
                            @typeInfo(result_body_type.structure) == .optional
                        else
                            null;

                    // ResultRedirect info
                    const result_redirect_type =
                        if (has_result_redirect)
                            result_redirect_field.?.type
                        else
                            void;
                    const is_result_redirect_optional: ?bool =
                        if (has_result_redirect)
                            @typeInfo(result_redirect_type.structure) == .optional
                        else
                            null;

                    // VariablesSet declaration
                    const VariablesSet = struct {
                        orp: orp_type,
                        claims_set: claim_set_type,

                        resource_parameters: resource_parameters_type,
                        required_header_parameters: header_parameters_type,
                        header_parameters_ptr: *header_parameters_type,
                        query_parsed: ?bool,
                        body_parsed: ?bool,

                        status: StatusCode,

                        resource_result: resource_result_type,
                        enforced_result_header: result_header_type,
                        result_header_ptr: *result_header_type,
                        result_body_ptr: *result_body_type,
                        result_body_buffer: []u8,
                        result_redirect_ptr: *result_redirect_type,
                    };
                };
        }

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
            // Get Info
            const Info = StaticMethodInfo(MethodType);

            // Get VariablesSet
            var var_set: Info.VariablesSet = undefined;

            if (comptime Info.has_orp) {
                var_set.orp.init(StaticRouteType, MethodType, allocator, context, request);
                defer var_set.orp.deinit();
            }

            if (comptime !(MethodType == .GET or MethodType == .HEAD)) {
                if (comptime Info.has_orp_invalid_method)
                    var_set.orp.invalidMethod(.method_not_allowed);

                const allow_header: Allow = .{
                    .methods = &[_]Method{ .GET, .HEAD },
                };

                var allow_buffer: [Allow.max_value_len]u8 = undefined;
                const allow = bufPrint(&allow_buffer, "{f}", .{allow_header}) catch |err| {
                    if (Info.has_orp_set_headers_error)
                        var_set.orp.setHeadersError(.internal_server_error, err, if (comptime IsDebug) @errorReturnTrace().?.* else {});
                    request.setStatus(.internal_server_error);
                    return;
                };

                request.setHeader(Allow.http_header_name, allow) catch |err| {
                    if (Info.has_orp_set_headers_error)
                        var_set.orp.setHeadersError(.internal_server_error, err, if (comptime IsDebug) @errorReturnTrace().?.* else {});
                    request.setStatus(.internal_server_error);
                    return;
                };
                request.setStatus(.method_not_allowed);
                return;
            }

            if (request.path == null or request.path.?.len != Path.len) {
                if (comptime Info.has_orp_invalid_request)
                    var_set.orp.invalidRequest(.not_found, error.InvalidPath);
                request.setStatus(.not_found);
                return;
            }

            // Required headers parsing
            const successful_header_parse =
                _parseHeaderParameters(
                    Info.required_headers_type,
                    request,
                    &var_set.required_headers,
                    allocator,
                    if (comptime Info.has_orp) &var_set.orp else {},
                );

            if (!successful_header_parse)
                return;

            // Authorization
            if (comptime Info.has_authorization) {
                const successful_authorization =
                    _authorize(
                        MethodType,
                        self.authorization_processor,
                        &var_set.required_headers.data.authorization,
                        &var_set.claims_set,
                        request,
                        allocator,
                        if (comptime Info.has_orp) &var_set.orp else {},
                    );

                if (!successful_authorization)
                    return;
            }

            // Accept
            const succesful_accept =
                _acceptable(
                    ResourceType.infered_media_type,
                    &var_set.required_headers.data.accept,
                    request,
                    if (comptime Info.has_orp) &var_set.orp else {},
                );

            if (!succesful_accept)
                return;

            if (comptime MethodType == .HEAD) {
                // Set EnforcedHeaders
                var_set.enforced_headers = .{
                    .data = .{
                        .date = .{
                            .time = time(instant(.{}) catch unreachable),
                        },
                    },
                };

                const successful_header_set =
                    _setResultHeader(
                        Info.enforced_headers_type,
                        request,
                        &var_set.enforced_headers,
                        allocator,
                        if (Info.has_orp) &var_set.orp else {},
                    );

                if (!successful_header_set)
                    return;
            } else if (comptime MethodType == .GET) {
                // Read body
                var_set.result_body = cwd().readFile(ResourceType.file_path, &var_set.result_body_buffer) catch |err| {
                    if (comptime Info.has_orp_read_file_crash)
                        var_set.orp.readFileCrash(err);
                    unreachable;
                };
                if (var_set.result_body.len >= var_set.result_body_buffer.len) {
                    if (comptime Info.has_orp_read_file_crash)
                        var_set.orp.readFileCrash(error.FileToBig);
                    unreachable;
                }

                // Set EnforcedHeaders
                var_set.enforced_headers = .{
                    .data = .{
                        .date = .{
                            .time = time(instant(.{}) catch unreachable),
                        },
                        .content_length = .{
                            .length = var_set.result_body.len,
                        },
                        .content_type = .{
                            .media_type = ResourceType.infered_media_type,
                        },
                    },
                };

                const successful_header_set =
                    _setResultHeader(
                        Info.enforced_headers_type,
                        request,
                        &var_set.enforced_headers,
                        allocator,
                        if (comptime Info.has_orp) &var_set.orp else {},
                    );

                if (!successful_header_set)
                    return;

                // Send body
                request.sendBody(var_set.result_body) catch |err| {
                    if (comptime Info.has_orp_send_body_error)
                        var_set.orp.sendBodyError(.internal_server_error, err, if (comptime IsDebug) @errorReturnTrace().?.* else {});
                    request.setStatus(.internal_server_error);
                    return;
                };
            } else unreachable;

            if (comptime Info.has_orp_success)
                var_set.orp.success(Info.status);
            request.setStatus(Info.status);
        }

        /// Calls API Method
        fn _callAPIMethod(
            self: *StaticRouteType,
            comptime MethodType: Method,
            allocator: Allocator,
            context: *ContextType,
            request: *const Request,
        ) void {
            // Get Info
            const Info = APIMethodInfo(MethodType);

            // Get VariablesSet
            var var_set: Info.VariablesSet = undefined;

            // Init OnRequestProcessor
            if (comptime Info.has_orp) {
                var_set.orp.init(StaticRouteType, MethodType, allocator, context, request);
                defer var_set.orp.deinit();
            }

            // Method check
            if (comptime !Info.has_method) {
                if (comptime Info.has_orp_invalid_method)
                    var_set.orp.invalidMethod(.not_implemented);
                request.setStatus(.not_implemented);
                return;
            }

            // Parse RequiredHeaders or HeaderParameters
            if (comptime Info.has_header_parameters) {
                // HeaderParameters
                var_set.header_parameters_ptr = fieldPtr(
                    Info.resource_parameters_type,
                    Info.header_parameters_field.?.name,
                    &var_set.resource_parameters,
                );

                const successful_header_parse =
                    _parseHeaderParameters(
                        Info.header_parameters_type,
                        request,
                        var_set.header_parameters_ptr,
                        allocator,
                        if (comptime Info.has_orp) &var_set.orp else {},
                    );

                if (!successful_header_parse)
                    return;
            } else {
                // RequiredHeaders
                var_set.header_parameters_ptr = &var_set.required_header_parameters;

                const successful_header_parse =
                    _parseHeaderParameters(
                        Info.header_parameters_type,
                        request,
                        &var_set.required_header_parameters,
                        allocator,
                        if (comptime Info.has_orp) &var_set.orp else {},
                    );

                if (!successful_header_parse)
                    return;
            }

            // Authorization
            if (comptime Info.has_authorization) {
                const successful_authorization =
                    _authorize(
                        MethodType,
                        self.authorization_processor,
                        &var_set.header_parameters_ptr.data.authorization,
                        &var_set.claims_set,
                        request,
                        allocator,
                        if (Info.has_orp) &var_set.orp else {},
                    );

                if (!successful_authorization)
                    return;
            }

            // Content headers
            if (comptime Info.has_body_parameters) {
                const successful_content_headers_validation =
                    _validateContentHeaders(
                        &Info.body_parameters_found.?.allowed_media_types_array,
                        &var_set.header_parameters_ptr.data.content_length,
                        &var_set.header_parameters_ptr.data.content_type,
                        request,
                        if (comptime Info.has_orp) &var_set.orp else {},
                    );

                if (!successful_content_headers_validation)
                    return;
            }

            // Accept
            if (comptime Info.has_result_body) {
                const succesful_accept =
                    _acceptable(
                        Info.result_body_field.?.type.result_media_type,
                        &var_set.header_parameters_ptr.data.accept,
                        request,
                        if (comptime Info.has_orp) &var_set.orp else {},
                    );

                if (!succesful_accept)
                    return;
            }

            // Parse all yet to be parsed parameters
            var_set.query_parsed = if (request.query == null) null else false;
            var_set.body_parsed = if (request.body == null) null else false;

            inline for (@typeInfo(Info.resource_parameters_type).@"struct".fields) |field| {
                const parameters_ptr = fieldPtr(
                    Info.resource_parameters_type,
                    field.name,
                    &var_set.resource_parameters,
                );

                switch (field.type.parameters_type) {
                    inline .path => {
                        // Path
                        field.type.parse(
                            Path,
                            request,
                            parameters_ptr,
                            allocator,
                        ) catch |err| {
                            if (comptime Info.has_orp_invalid_parameters)
                                var_set.orp.invalidParameters(.path, .not_found, err);
                            request.setStatus(.not_found);
                            return;
                        };
                    },
                    inline .query => {
                        // Query
                        field.type.parse(
                            request,
                            parameters_ptr,
                            allocator,
                        ) catch |err| {
                            if (comptime Info.has_orp_invalid_parameters)
                                var_set.orp.invalidParameters(.query, .not_found, err);
                            request.setStatus(.not_found);
                            return;
                        };

                        var_set.query_parsed = true;
                    },
                    inline .header => {
                        // Header
                        // Already parsed
                    },
                    inline .body => {
                        // Body
                        field.type.parse(
                            request,
                            parameters_ptr,
                            &var_set.header_parameters_ptr.data.content_length,
                            &var_set.header_parameters_ptr.data.content_type,
                            allocator,
                        ) catch |err| {
                            if (comptime Info.has_orp_invalid_parameters)
                                var_set.orp.invalidParameters(.body, .bad_request, err);
                            request.setStatus(.bad_request);
                            return;
                        };

                        var_set.body_parsed = true;
                    },
                }
            }

            // Check for ExcessQuery and ExcessBody
            if (!(var_set.query_parsed orelse true)) {
                if (comptime Info.has_orp_invalid_request)
                    var_set.orp.invalidRequest(.not_found, error.ExcessQuery);
                request.setStatus(.not_found);
                return;
            }
            if (!(var_set.body_parsed orelse true)) {
                if (comptime Info.has_orp_invalid_request)
                    var_set.orp.invalidRequest(.bad_request, error.ExcessBody);
                request.setStatus(.bad_request);
                return;
            }

            // Set null to any optional result
            inline for (@typeInfo(Info.resource_result_type).@"struct".fields) |field| {
                if (comptime @typeInfo(field.type.structure) == .optional) {
                    const result_field_ptr =
                        fieldPtr(
                            Info.resource_result_type,
                            field.name,
                            &var_set.resource_result,
                        );

                    result_field_ptr.data = null;
                }
            }

            // Call method
            const call_result = @call(
                .never_inline,
                Info.method_fn,
                _buildMethodParameters(
                    Info.method_parameters_type,
                    &var_set.resource_parameters,
                    if (comptime Info.has_ap) &var_set.claims_set else {},
                    context,
                    allocator,
                    &var_set.resource_result,
                ),
            );

            // Get status
            if (comptime Info.has_error_return) {
                var_set.status = call_result catch |err| {
                    if (comptime Info.has_orp_controller_error)
                        var_set.orp.controllerError(.internal_server_error, err, if (comptime IsDebug) @errorReturnTrace().?.* else {});
                    request.setStatus(.internal_server_error);
                    return;
                };
            } else var_set.status = call_result;

            // Get result pointers
            if (comptime Info.has_result_header)
                var_set.result_header_ptr =
                    fieldPtr(
                        Info.resource_result_type,
                        Info.result_header_field.?.name,
                        &var_set.resource_result,
                    );

            if (comptime Info.has_result_body)
                var_set.result_body_ptr =
                    fieldPtr(
                        Info.resource_result_type,
                        Info.result_body_field.?.name,
                        &var_set.resource_result,
                    );

            if (comptime Info.has_result_redirect)
                var_set.result_redirect_ptr =
                    fieldPtr(
                        Info.resource_result_type,
                        Info.result_redirect_field.?.name,
                        &var_set.resource_result,
                    );

            // Get ResultBody
            if (comptime Info.has_result_body) {
                body_format_blk: {
                    if (comptime Info.is_result_body_optional.?)
                        if (var_set.result_body_ptr.data != null) {
                            if (!isStatusCodeSuccess(var_set.status)) {
                                if (comptime Info.has_orp_match_status_to_result_crash)
                                    var_set.orp.matchStatusCodeToResultCrash(.body, error.NonSuccessStatusCode);
                                unreachable;
                            }
                        } else {
                            if (comptime Info.has_result_header) {
                                if (var_set.result_header_ptr.data != null) {
                                    if (comptime Info.has_orp_result_composition_crash)
                                        var_set.orp.resultCompositionCrash(error.MissingResultBody);
                                    unreachable;
                                } else break :body_format_blk;
                            } else break :body_format_blk;
                        };

                    var_set.result_body_ptr.format(&var_set.result_body_buffer, allocator) catch |err| {
                        if (comptime Info.has_orp_format_result_crash)
                            var_set.orp.formatResultCrash(.body, err);
                        unreachable;
                    };
                }
            }

            // Set ResultHeader or EnforcedHeaders
            if (comptime Info.has_result_header) {
                // ResultHeader
                header_format_blk: {
                    if (comptime Info.is_result_header_optional.?)
                        if (var_set.result_header_ptr.data != null) {
                            if (!isStatusCodeSuccess(var_set.status)) {
                                if (comptime Info.has_orp_match_status_to_result_crash)
                                    var_set.orp.matchStatusCodeToResultCrash(.header, error.NonSuccessStatusCode);
                                unreachable;
                            }
                        } else {
                            if (comptime Info.has_result_body) {
                                if (var_set.result_body_ptr.data != null) {
                                    if (comptime Info.has_orp_result_composition_crash)
                                        var_set.orp.resultCompositionCrash(error.MissingResultHeader);
                                    unreachable;
                                } else break :header_format_blk;
                            } else break :header_format_blk;
                        };

                    const successful_header_set =
                        _setResultHeader(
                            Info.result_header_type,
                            request,
                            var_set.result_header_ptr,
                            allocator,
                            if (comptime Info.has_orp) &var_set.orp else {},
                        );

                    if (!successful_header_set)
                        return;
                }
            } else {
                // EnforcedHeaders
                if (isStatusCodeSuccess(var_set.status)) {
                    var_set.enforced_result_header =
                        if (comptime Info.has_result_body)
                            .{
                                .data = .{
                                    .date = .{
                                        .time = time(instant(.{}) catch unreachable),
                                    },
                                    .content_length = .{
                                        .length = var_set.result_body_buffer.len,
                                    },
                                    .content_type = .{
                                        .media_type = Info.result_body_field.?.type.result_media_type,
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
                            Info.result_header_type,
                            request,
                            &var_set.enforced_result_header,
                            allocator,
                            if (comptime Info.has_orp) &var_set.orp else {},
                        );

                    if (!successful_header_set)
                        return;
                }
            }

            // Status code checking
            switch (var_set.status) {
                .created => {
                    // Must have Location result header
                    if (!Info.has_result_header_location or (Info.is_result_header_optional.? and var_set.result_header_ptr.data == null)) {
                        if (comptime Info.has_orp_match_status_to_result_crash)
                            var_set.orp.matchStatusCodeToResultCrash(.header, error.MissingLocation);
                        unreachable;
                    }
                    if (Info.is_result_header_location_optional) {
                        const location_ptr = fieldPtr(
                            Info.result_header_structure,
                            Info.result_header_location_field.?.name,
                            if (comptime Info.is_result_header_optional) &var_set.result_header_ptr.*.? else var_set.result_header_ptr,
                        );

                        if (location_ptr.* == null) {
                            if (comptime Info.has_orp_match_status_to_result_crash)
                                var_set.orp.matchStatusCodeToResultCrash(.header, error.MissingLocation);
                            unreachable;
                        }
                    }
                },
                .no_content, .not_modified => {
                    // Mustn't have result body
                    if (comptime Info.has_result_body) {
                        if ((Info.is_result_body_optional.? and var_set.result_body_ptr.data != null) or !Info.is_result_body_optional.?) {
                            if (comptime Info.has_orp_match_status_to_result_crash)
                                var_set.orp.matchStatusCodeToResultCrash(.body, error.ForbiddenResultBody);
                            unreachable;
                        }
                    }
                },
                else => {},
            }

            if (isStatusCodeSuccess(var_set.status)) {
                // Success status
                if (comptime Info.has_result_redirect) {
                    if ((Info.is_result_redirect_optional.? and var_set.result_redirect_ptr.data != null) or !Info.is_result_redirect_optional.?) {
                        if (comptime Info.has_orp_match_status_to_result_crash)
                            var_set.orp.matchStatusCodeToResultCrash(.redirect, error.NonRedirectStatusCode);
                        unreachable;
                    }
                }

                // Send ResultBody
                if (comptime Info.has_result_body) {
                    if (Info.is_result_body_optional.? or var_set.result_body_ptr.data != null)
                        request.sendBody(var_set.result_body_buffer) catch |err| {
                            if (comptime Info.has_orp_send_body_error)
                                var_set.orp.sendBodyError(.internal_server_error, err, if (comptime IsDebug) @errorReturnTrace().?.* else {});
                            request.setStatus(.internal_server_error);
                            return;
                        };
                }

                // Set status code
                if (comptime Info.has_orp_success)
                    var_set.orp.success(var_set.status);
                request.setStatus(var_set.status);
            } else if (isStatusCodeRedirect(var_set.status)) {
                // Redirect status
                if (comptime Info.has_result_header) {
                    if ((Info.is_result_header_optional.? and var_set.result_header_ptr.data != null) or !Info.is_result_header_optional.?) {
                        if (comptime Info.has_orp_match_status_to_result_crash)
                            var_set.orp.matchStatusCodeToResultCrash(.header, error.NonSuccessStatusCode);
                        unreachable;
                    }
                }
                if (comptime Info.has_result_body) {
                    if ((Info.is_result_body_optional.? and var_set.result_body_ptr.data != null) or !Info.is_result_body_optional.?) {
                        if (comptime Info.has_orp_match_status_to_result_crash)
                            var_set.orp.matchStatusCodeToResultCrash(.body, error.NonSuccessStatusCode);
                        unreachable;
                    }
                }

                // Set ResultRedirect
                if (comptime Info.has_result_redirect) {
                    if (Info.is_result_redirect_optional.? and var_set.result_redirect_ptr.data == null) {
                        if (comptime Info.has_orp_result_composition_crash)
                            var_set.orp.resultCompositionCrash(error.MissingResultRedirect);
                        unreachable;
                    }

                    request.redirectTo(
                        if (comptime Info.is_result_redirect_optional.?) var_set.result_redirect_ptr.data.? else var_set.result_redirect_ptr.data,
                        var_set.status,
                    ) catch |err| {
                        if (comptime Info.has_orp_redirect_error)
                            var_set.orp.redirectError(.internal_server_error, err, if (comptime IsDebug) @errorReturnTrace().?.* else {});
                        request.setStatus(.internal_server_error);
                        return;
                    };
                }

                if (comptime Info.has_orp_redirect)
                    var_set.orp.redirect(var_set.status);
            }
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
            const result_header_structure_info =
                if (@typeInfo(ResultHeaderType.structure) == .optional)
                    @typeInfo(@typeInfo(ResultHeaderType.structure).optional.child)
                else
                    @typeInfo(ResultHeaderType.structure);

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
