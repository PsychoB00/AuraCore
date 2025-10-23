/// STD
const std = @import("std");

const lastIndexOfScalar = std.mem.lastIndexOfScalar;

/// Aura
const core = @import("../core.zig");

const ContentDisposition = core.net.headers.ContentDisposition;
const CacheControl = core.net.CacheControl;

const ResourceOptions = core.routing.ResourceOptions;

pub const StaticResourceOptions = struct {
    /// How many bytes can file be
    max_bytes: usize = 65_536,
    /// Should the resource be displayed by browsers or downloaded
    content_disposition: ContentDisposition = ContentDisposition{ .disposition = .@"inline", .filename = null },
    /// How should resource be cached
    cache_control: CacheControl = .no_store,
    /// Should the "last-modified" header be set
    last_modified: bool = false,
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
    };
}

pub fn isStaticResource(comptime Type: type) bool {
    return @hasDecl(Type, "file_path") and @TypeOf(Type.file_path) == []const u8 and
        @hasDecl(Type, "file_extention") and @TypeOf(Type.file_extention) == []const u8 and
        @hasDecl(Type, "sr_options") and @TypeOf(Type.sr_options) == StaticResourceOptions and
        @hasDecl(Type, "options") and @TypeOf(Type.options) == ResourceOptions and
        StaticResource(Type.file_path, Type.sr_options, Type.options) == Type;
}
