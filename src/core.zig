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
};

pub const context = @import("context.zig");
pub const log = @import("log.zig");
pub const jwt = @import("jwt.zig");
pub const json = @import("json.zig");

pub const net = struct {
    pub const headers = @import("net/headers.zig");
    pub const CacheControl = headers.CacheControl;
    pub const LastModified = headers.LastModified;

    const method = @import("net/method.zig");
    pub const methodToLower = method.methodToLower;
    pub const methodToUpper = method.methodToUpper;

    const status_code = @import("net/status_code.zig");
    pub const statusCodeToLower = status_code.statusCodeToLower;
    pub const statusCodeToUpper = status_code.statusCodeToUpper;
};

pub const routing = struct {
    const route_processor = @import("routing/OnRequestProcessor.zig");
    pub const LoggingOnRequestProcessor = route_processor.LoggingOnRequestProcessor;
    pub const isOnRequestProcessor = route_processor.isOnRequestProcessor;

    const router = @import("routing/Router.zig");
    pub const ResourceOptions = router.ResourceOptions;
    pub const Router = router.Router;

    const static_resource = @import("routing/StaticResource.zig");
    pub const StaticResourceOptions = static_resource.StaticResourceOptions;
    pub const StaticResource = static_resource.StaticResource;
    pub const isStaticResource = static_resource.isStaticResource;

    const api_resource = @import("routing/APIResource.zig");
    pub const ParametersType = api_resource.ParametersType;
    pub const isResourceParameters = api_resource.isResourceParameters;
    pub const APIResource = api_resource.APIResource;
    pub const isAPIResource = api_resource.isAPIResource;

    const path_parameters = @import("routing/PathParameters.zig");
    pub const PathParameters = path_parameters.PathParameters;
    pub const isPathParameters = path_parameters.isPathParameters;

    const query_parameters = @import("routing/QueryParameters.zig");
    pub const QueryParameters = query_parameters.QueryParameters;
    pub const isQueryParameters = query_parameters.isQueryParameters;

    const body_parameters = @import("routing/BodyParameters.zig");
    pub const BodyParameters = body_parameters.BodyParameters;
    pub const isBodyParameters = body_parameters.isBodyParameters;
};
