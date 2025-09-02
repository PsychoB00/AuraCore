pub const static_resource = struct {
    pub const FileType = enum {
        html,
        txt,
        png,
        svg,
    };

    pub fn StaticResource(comptime Type: FileType, comptime Data: []const u8) type {
        return struct {
            pub const file_type = Type;
            pub const data = Data;
        };
    }

    pub fn isStaticResource(comptime Type: type) bool {
        return @hasDecl(Type, "file_type") and @TypeOf(Type.file_type) == static_resource.FileType and
            @hasDecl(Type, "data") and @TypeOf(Type.data) == []const u8;
    }
};
