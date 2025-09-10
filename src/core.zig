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

pub const routing = struct {
    const api_resource = @import("routing/APIResource.zig");
    pub const ParametersType = api_resource.ParametersType;
    pub const ResourceParametersError = api_resource.ResourceParametersError;
    pub const isResourceParameters = api_resource.isResourceParameters;

    const path_parameters = @import("routing/PathParameters.zig");
    pub const PathParameters = path_parameters.PathParameters;
    pub const isPathParameters = path_parameters.isPathParameters;

    const query_parameters = @import("routing/QueryParameters.zig");
    pub const QueryParameters = query_parameters.QueryParameters;
    pub const isQueryParameters = query_parameters.isQueryParameters;

    const body_parameters = @import("routing/BodyParameters.zig");
    pub const MIMEType = body_parameters.MIMEType;
    pub const BodyParameters = body_parameters.BodyParameters;
    pub const isBodyParameters = body_parameters.isBodyParameters;
};
pub const router = @import("Router.zig");
pub const static_resource = @import("StaticResource.zig").static_resource;
