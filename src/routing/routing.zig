/// STD
const std = @import("std");

const isAlphanumeric = std.ascii.isAlphanumeric;

/// Aura
const authorization_processor = @import("AuthorizationProcessor.zig");
pub const AuthorizationResult = authorization_processor.AuthorizationResult;
pub const isAuthorizationProcessor = authorization_processor.isAuthorizationProcessor;

const on_request_processor = @import("OnRequestProcessor.zig");
pub const LoggingOnRequestProcessor = on_request_processor.LoggingOnRequestProcessor;
pub const isOnRequestProcessor = on_request_processor.isOnRequestProcessor;

const router = @import("Router.zig");
pub const Router = router.Router;
pub const isRouter = router.isRouter;

const static_resource = @import("StaticResource.zig");
pub const StaticResourceOptions = static_resource.StaticResourceOptions;
pub const StaticResource = static_resource.StaticResource;
pub const isStaticResource = static_resource.isStaticResource;

const api_resource = @import("APIResource.zig");
pub const ParametersType = api_resource.ParametersType;
pub const isResourceParameters = api_resource.isResourceParameters;
pub const ResultType = api_resource.ResultType;
pub const isResourceResult = api_resource.isResourceResult;
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

const result_body = @import("ResultBody.zig");
pub const ResultBody = result_body.ResultBody;
pub const isResultBody = result_body.isResultBody;

/// Third Party
const zap = @import("zap");

const ErrorStrategy = zap.Endpoint.ErrorStrategy;

pub const ResourceOptions = struct {
    /// Should endpoint requests for this resource be authorized by AuthorizationProcessor and if so,
    /// what requirements should be used.
    /// Only allowed character for requirements are alphanumeric ascii characters and "-_.:"
    authorize: ?[]const []const u8,
    /// Should endpoint request for resource return error if headers in request aren't defined
    /// in resource. Usefull when working with browsers or if you don't have control over
    /// which headers are send
    strict_headers: bool = false,
    /// How should zap handle endpoint request error
    error_strategy: ErrorStrategy = .raise,

    pub fn validate(self: ResourceOptions) !void {
        if (self.authorize) |authorize_requirements| {
            if (authorize_requirements.len == 0)
                return error.TooFewRequirements;

            for (authorize_requirements) |requirement| {
                if (requirement.len == 0)
                    return error.RequirementTooShort;

                for (requirement) |character| {
                    try validateRequirementChar(character);
                }
            }
        }
    }

    pub fn validateRequirementChar(character: u8) !void {
        const allowed_characters = "-_.:";

        if (isAlphanumeric(character))
            return;

        inline for (allowed_characters) |allowed_character| {
            if (allowed_character == character)
                return;
        }

        return error.InvalidCharacter;
    }
};
