pub const dome = @embedFile("resources/aura_dome.svg");

pub const utils = @import("Utils.zig").utils;
pub const log = @import("Log.zig").log;
pub const jwt = @import("JWT.zig").jwt;
pub const router = @import("Router.zig").router;
pub const static_resource = @import("StaticResource.zig").static_resource;
pub const api_resource = @import("APIResource.zig").api_resource;
