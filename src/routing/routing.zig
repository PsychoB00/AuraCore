/// Aura
const route_processor = @import("OnRequestProcessor.zig");
pub const LoggingOnRequestProcessor = route_processor.LoggingOnRequestProcessor;
pub const isOnRequestProcessor = route_processor.isOnRequestProcessor;

const router = @import("Router.zig");
pub const Router = router.Router;

const static_resource = @import("StaticResource.zig");
pub const StaticResourceOptions = static_resource.StaticResourceOptions;
pub const StaticResource = static_resource.StaticResource;
pub const isStaticResource = static_resource.isStaticResource;

const api_resource = @import("APIResource.zig");
pub const ParametersType = api_resource.ParametersType;
pub const isResourceParameters = api_resource.isResourceParameters;
pub const APIResource = api_resource.APIResource;
pub const isAPIResource = api_resource.isAPIResource;

const path_parameters = @import("PathParameters.zig");
pub const PathParameters = path_parameters.PathParameters;
pub const isPathParameters = path_parameters.isPathParameters;

const query_parameters = @import("QueryParameters.zig");
pub const QueryParameters = query_parameters.QueryParameters;
pub const isQueryParameters = query_parameters.isQueryParameters;

const header_parameters = @import("HeaderParameters.zig");
pub const EnforcedHeadersTag = header_parameters.EnforcedHeadersTag;
pub const EnforcedHeaders = header_parameters.EnforcedHeaders;
pub const HeaderParameters = header_parameters.HeaderParameters;
pub const isHeaderParameters = header_parameters.isHeaderParameters;

const body_parameters = @import("BodyParameters.zig");
pub const BodyParameters = body_parameters.BodyParameters;
pub const isBodyParameters = body_parameters.isBodyParameters;

/// Third Party
const zap = @import("zap");

const ErrorStrategy = zap.Endpoint.ErrorStrategy;

pub const ResourceOptions = struct {
    /// Should endpoint requests for resources in this resource be authenticated by Router
    authenticate: bool,
    /// Should endpoint request for resource return error if headers in request aren't defined
    /// in resource. Usefull when working with browsers or if you don't have control over
    /// which headers are send
    strict_headers: bool = false,
    /// How should zap handle endpoint request error
    error_strategy: ErrorStrategy = .log_to_console,
};
