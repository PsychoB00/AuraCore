/// STD
const std = @import("std");

const StructField = std.builtin.Type.StructField;

const comptimePrint = std.fmt.comptimePrint;
const startsWith = std.mem.startsWith;

/// Aura
const core = @import("../core.zig");
const static_route = @import("StaticRoute.zig");

const StaticRoute = static_route.StaticRoute;
const AuthStaticRoute = static_route.AuthStaticRoute;

const fieldPtr = core.utils.fieldPtr;
const isStaticResource = core.static_resource.isStaticResource;
const isAPIResource = core.routing.isAPIResource;

/// Third Party
const zap = @import("zap");

const ErrorStrategy = zap.Endpoint.ErrorStrategy;

pub const ResourceOptions = struct {
    /// Should endpoint requests for resources in this resource be authenticated by Router
    authenticate: bool,
    /// How should zap handle endpoint request error
    error_strategy: ErrorStrategy = .log_to_console,
};

/// Router which constructs, authenticates and routes to `ResourceTree`
///
/// - `ResourceTree` must be a struct ...
pub fn Router(comptime ResourceTree: anytype, comptime ContextType: type, comptime AuthenticatorType: type) type {
    // Generated Router tools
    const Gen = struct {
        const App = zap.App.Create(ContextType);

        const ResourceTypeCount = struct {
            static: usize = 0,
            api: usize = 0,
        };

        /// Validation of `Node, where `Node` is part of `ResourceTree`
        fn _validateNode(comptime Node: type) void {
            const node_info = @typeInfo(Node);

            if (node_info != .@"struct")
                @compileError("`Node` must be a struct");
            if (node_info.@"struct".is_tuple)
                @compileError("`Node` musn't be a tuple");
            if (node_info.@"struct".fields.len != 0)
                @compileError(comptimePrint(
                    "Fields found in {s}",
                    .{@typeName(Node)},
                ));
            if (node_info.@"struct".decls.len == 0)
                @compileError(comptimePrint(
                    "Node which doesn't lead to resouce found in {s}",
                    .{@typeName(Node)},
                ));

            // Check if every declaration in `Node` is valid
            var resource_names: [node_info.@"struct".decls.len][]const u8 = undefined;
            var resource_names_index: usize = 0;
            for (node_info.@"struct".decls) |decl| {
                const decl_value = @field(Node, decl.name);

                if (@TypeOf(decl_value) != type)
                    @compileError(comptimePrint(
                        "Declaretions which doesn't declare type found in {s}",
                        .{@typeName(Node)},
                    ));

                if (isStaticResource(decl_value)) {
                    resource_names[resource_names_index] = decl.name;
                    resource_names_index += 1;
                } else if (isAPIResource(decl_value)) {
                    if (decl_value.infered_context_t != null and decl_value.infered_context_t != ContextType)
                        @compileError(comptimePrint(
                            "Infered context type of a APIResource is different then `ContexType`, found in {s}",
                            .{@typeName(Node)},
                        ));

                    resource_names[resource_names_index] = decl.name;
                    resource_names_index += 1;
                } else _validateNode(decl_value);
            }

            // Check if resource names in `Node` aren't shadowing each other
            for (0..resource_names_index) |name_index| {
                for (0..resource_names_index) |check_name_index| {
                    if (name_index != check_name_index and
                        startsWith(u8, resource_names[name_index], resource_names[check_name_index]))
                        @compileError(comptimePrint(
                            "Resource name \"{s}\" shadows resource name \"{s}\"",
                            .{ resource_names[name_index], resource_names[check_name_index] },
                        ));
                }
            }
        }

        /// Counts how many resources are in `Node`
        fn _countResources(comptime Node: type) ResourceTypeCount {
            var res: ResourceTypeCount = .{};

            for (@typeInfo(Node).@"struct".decls) |decl| {
                const decl_value = @field(Node, decl.name);

                if (isStaticResource(decl_value)) {
                    res.static += 1;
                } else if (isAPIResource(decl_value)) {
                    res.api += 1;
                } else {
                    const decl_resource_count = _countResources(decl_value);
                    res.static += decl_resource_count.static;
                    res.api += decl_resource_count.api;
                }
            }

            return res;
        }

        /// Generates StaticRoute types based on `Node` resources
        fn _generateStaticRouteFields(
            comptime Node: type,
            comptime Path: []const u8,
            comptime Buffer: [*]StructField,
            comptime Index: *usize,
        ) void {
            for (@typeInfo(Node).@"struct".decls) |decl| {
                const decl_value = @field(Node, decl.name);
                const decl_path = Path ++ "/" ++ decl.name;

                if (isStaticResource(decl_value) or isAPIResource(decl_value)) {
                    const options = decl_value.options;
                    const static_route_type =
                        if (options.authenticate)
                            AuthStaticRoute(
                                decl_value,
                                ContextType,
                                AuthenticatorType,
                                decl_path,
                                options,
                            )
                        else
                            StaticRoute(
                                decl_value,
                                ContextType,
                                decl_path,
                                options,
                            );

                    Buffer[Index.*] = .{
                        .name = comptimePrint("{}", .{Index.*}),
                        .type = static_route_type,
                        .default_value_ptr = null,
                        .is_comptime = false,
                        .alignment = @alignOf(static_route_type),
                    };

                    Index.* += 1;
                } else _generateStaticRouteFields(decl_value, decl_path, Buffer, Index);
            }
        }
    };

    // `ResourceTree` correctness assertion
    Gen._validateNode(ResourceTree);

    // Get resource count in `ResourceTree`
    const resource_count = Gen._countResources(ResourceTree);
    const static_route_count = resource_count.static + resource_count.api;

    // Generate StaticRoute fields
    var buffer: [static_route_count]StructField = undefined;
    var index: usize = 0;
    _ = Gen._generateStaticRouteFields(ResourceTree, "", &buffer, &index);
    const static_routes_fields: [static_route_count]StructField = buffer;

    return struct {
        const RouterType = @This();

        pub const StaticRoutesSet = @Type(.{
            .@"struct" = .{
                .layout = .auto,
                .fields = static_routes_fields[0..],
                .decls = &.{},
                .is_tuple = false,
            },
        });

        static_routes_set: StaticRoutesSet,

        /// Initialize Router and its static_routes_set then register them to `application`
        pub fn init(self: *RouterType, authenticator: *AuthenticatorType) !void {
            inline for (@typeInfo(StaticRoutesSet).@"struct".fields) |static_route_field| {
                const static_route_field_ptr = fieldPtr(
                    StaticRoutesSet,
                    static_route_field.name,
                    &self.static_routes_set,
                );

                if (comptime static_route_field.type.resource_options.authenticate) {
                    static_route_field_ptr.init(authenticator);
                    try Gen.App.register(&static_route_field_ptr.auth_static_route);
                } else {
                    static_route_field_ptr.* = .{};
                    try Gen.App.register(static_route_field_ptr);
                }
            }
        }
    };
}
