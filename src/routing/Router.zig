/// STD
const std = @import("std");

const StructField = std.builtin.Type.StructField;

const comptimePrint = std.fmt.comptimePrint;
const startsWith = std.mem.startsWith;

/// Aura
const core = @import("../core.zig");
const static_route = @import("StaticRoute.zig");

const StaticRoute = static_route.StaticRoute;

const fieldPtr = core.utils.fieldPtr;
const isContext = core.context.isContext;
const isAuthorizationProcessor = core.routing.isAuthorizationProcessor;
const isOnRequestProcessor = core.routing.isOnRequestProcessor;
const isStaticResource = core.routing.isStaticResource;
const isAPIResource = core.routing.isAPIResource;

/// Third party
const zap = @import("zap");

/// Router which constructs, authorizes and routes to `ResourceTreeType`
///
/// - `ResourceTreeType` must be a struct ...
/// - `ContextType` must fulfill the isContext trait check
/// - `AuthorizationProcessorType` must fulfill the isAuthorizationProcessor trait check or be null
/// - `OnRequestProcessorType` must fulfill the isOnRequestProcessor trait check or be null
pub fn Router(
    comptime ResourceTreeType: type,
    comptime ContextType: type,
    comptime AuthorizationProcessorType: ?type,
    comptime OnRequestProcessorType: ?type,
) type {
    // Generated Router tools
    const Gen = struct {
        const App = zap.App.Create(ContextType);

        const ResourceTypeCount = struct {
            static: usize = 0,
            api: usize = 0,
        };

        /// Validation of `Node, where `Node` is part of `ResourceTreeType`
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
                    if (AuthorizationProcessorType == null and decl_value.options.authorize != null)
                        @compileError(comptimePrint(
                            "APIResource which should authorize but doesn't have `AuthorizationProcessorType`, found in {s}",
                            .{@typeName(Node)},
                        ));

                    resource_names[resource_names_index] = decl.name;
                    resource_names_index += 1;
                } else if (isAPIResource(decl_value)) {
                    if (AuthorizationProcessorType == null and decl_value.options.authorize != null)
                        @compileError(comptimePrint(
                            "APIResource which should authorize but doesn't have `AuthorizationProcessorType`, found in {s}",
                            .{@typeName(Node)},
                        ));

                    if (decl_value.infered_context_t != null and decl_value.infered_context_t.? != ContextType)
                        @compileError(comptimePrint(
                            "Infered context type of a APIResource ({s}) is different then `ContexType`, found in {s}",
                            .{ @typeName(decl_value.infered_context_t.?), @typeName(Node) },
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

                const is_static_resource = isStaticResource(decl_value);
                const is_api_resource = isAPIResource(decl_value);
                if (is_static_resource or is_api_resource) {
                    const options = decl_value.options;
                    const resource_path =
                        if (is_static_resource)
                            decl_path ++ decl_value.file_extention
                        else
                            decl_path;

                    const static_route_type =
                        StaticRoute(
                            decl_value,
                            ContextType,
                            AuthorizationProcessorType,
                            OnRequestProcessorType,
                            resource_path,
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

    // `ResourceTreeType` correctness assertion
    Gen._validateNode(ResourceTreeType);

    // `ContextType` correctness assertion
    if (!isContext(ContextType))
        @compileError("`ContextType` must be Context");

    // `AuthorizationProcessorType` correctness assertion
    if (!(AuthorizationProcessorType == null or isAuthorizationProcessor(AuthorizationProcessorType.?)))
        @compileError("`AuthorizationProcessorType` must be AuthorizationProcessor");

    // `OnRequestProcessorType` correctness assertion
    if (!(OnRequestProcessorType == null or isOnRequestProcessor(OnRequestProcessorType.?)))
        @compileError("`OnRequestProcessorType` must be OnRequestProcessor");
    if (!(OnRequestProcessorType == null or OnRequestProcessorType.?.context_t == ContextType))
        @compileError("Context of `OnRequestProcessorType` isn't same as `ContextType`");

    // Get resource count in `ResourceTreeType`
    const resource_count = Gen._countResources(ResourceTreeType);
    const static_route_count = resource_count.static + resource_count.api;

    // Generate StaticRoute fields
    var buffer: [static_route_count]StructField = undefined;
    var index: usize = 0;
    Gen._generateStaticRouteFields(ResourceTreeType, "", &buffer, &index);
    const static_routes_fields: [static_route_count]StructField = buffer;

    return struct {
        const RouterType = @This();

        pub const resource_tree_t = ResourceTreeType;
        pub const context_t = ContextType;
        pub const authorization_processor_t = AuthorizationProcessorType;
        pub const on_request_processor_t = OnRequestProcessorType;

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
        pub fn init(
            self: *RouterType,
            authorization_processor: if (AuthorizationProcessorType == null) void else *const AuthorizationProcessorType.?,
        ) !void {
            inline for (@typeInfo(StaticRoutesSet).@"struct".fields) |static_route_field| {
                const static_route_field_ptr = fieldPtr(
                    StaticRoutesSet,
                    static_route_field.name,
                    &self.static_routes_set,
                );

                static_route_field_ptr.* = .{
                    .authorization_processor = if (static_route_field.type.resource_options.authorize != null)
                        authorization_processor
                    else
                        undefined,
                };
                try Gen.App.register(static_route_field_ptr);
            }
        }
    };
}

/// Trait check for Router
///
/// - `Type` must be struct
/// - `Type` must have declaration of what resource tree it is using, named "resource_tree_t"
///     - `resource_tree_t` must be decleration of type
/// - `Type` must have declaration of what context it is using, named "context_t"
///     - `context_t` must be decleration of type
/// - `Type` must have declaration of what authentication processor it is using, named "authorization_processor_t"
///     - `authorization_processor_t` must be decleration of ?type
/// - `Type` must have declaration of what on-request processor it is using, named "on_request_processor_t"
///     - `on_request_processor_t` must be decleration of ?type
/// - `Type` must be able to generate `Type` using its declarations and function Router
pub fn isRouter(comptime Type: type) bool {
    if (@typeInfo(Type) != .@"struct")
        return false;

    const has_resourcer_tree_type =
        @hasDecl(Type, "resource_tree_t") and
        @TypeOf(Type.resource_tree_t) == type;

    const has_context_type =
        @hasDecl(Type, "context_t") and
        @TypeOf(Type.context_t) == type;

    const has_authorization_processor_type =
        @hasDecl(Type, "authorization_processor_t") and
        @TypeOf(Type.authorization_processor_t) == ?type;

    const has_on_request_processor_type =
        @hasDecl(Type, "on_request_processor_t") and
        @TypeOf(Type.on_request_processor_t) == ?type;

    const can_generate_self =
        has_resourcer_tree_type and has_context_type and has_authorization_processor_type and has_on_request_processor_type and
        Router(Type.resource_tree_t, Type.context_t, Type.authorization_processor_t, Type.on_request_processor_t) == Type;

    return can_generate_self;
}
