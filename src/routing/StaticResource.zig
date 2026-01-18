/// STD
const std = @import("std");

const lastIndexOfScalar = std.mem.lastIndexOfScalar;

/// Aura
const core = @import("../core.zig");

const ResourceOptions = core.routing.ResourceOptions;
const MediaType = core.net.headers.MediaType;

pub const StaticResourceOptions = struct {
    /// How many bytes can file be
    max_bytes: usize = 65_536,
};

/// Structure for binding `FilePath`, `SROptions` and `Options` together to define Static file resource
///
/// `FilePath` must be valid file path relative to current working directory and end with extention
/// `SROptions` are options for both file reading and responce building
/// Only GET and HEAD requests van be called on StaticResource
pub fn StaticResource(comptime FilePath: []const u8, comptime SROptions: StaticResourceOptions, comptime Options: ResourceOptions) type {
    // `FilePath` correctness assertion
    const file_extention_start_index = lastIndexOfScalar(u8, FilePath, '.') orelse
        @compileError("`FilePath` must end with file extention");
    if (file_extention_start_index == FilePath.len - 1)
        @compileError("`FilePath` must end with non-empty file extention");

    for (FilePath[(file_extention_start_index + 1)..]) |character| {
        if (character < 'a' or character > 'z')
            @compileError("File extention containes unsupported characters");
    }

    return struct {
        pub const file_path = FilePath;
        pub const file_extention: []const u8 = FilePath[file_extention_start_index..];
        pub const sr_options = SROptions;
        pub const options = Options;
        pub const infered_media_type = MediaType.fromFileExtention(file_extention);
    };
}

/// Trait check for StaticResource
///
/// - `Type` must be struct
/// - `Type` must have declaration for relative filepath which it is using, named "file_path"
///     - `file_path` must be declaration of []const u8
/// - `Type` must have declaration for static resource options which it uses, named "sr_options"
///     - `sr_options` must be declaration of StaticResourceOptions
/// - `Type` must have declaration for options which it uses, named "options"
///     - `options` must be declaration of ResourceOptions
/// - `Type` must be able to generate `Type` using its declarations and function StaticResource
pub fn isStaticResource(comptime Type: type) bool {
    if (@typeInfo(Type) != .@"struct")
        return false;

    const has_file_path =
        @hasDecl(Type, "file_path") and
        @TypeOf(Type.file_path) == []const u8;

    const has_static_resource_options =
        @hasDecl(Type, "sr_options") and
        @TypeOf(Type.sr_options) == StaticResourceOptions;

    const has_options =
        @hasDecl(Type, "options") and
        @TypeOf(Type.options) == ResourceOptions;

    const can_generate_self =
        has_file_path and has_static_resource_options and has_options and
        StaticResource(Type.file_path, Type.sr_options, Type.options) == Type;

    return can_generate_self;
}
