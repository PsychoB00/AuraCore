pub const packages = struct {
    pub const @"jwt-0.0.1-HbWOu6Y-AAAazOpY5quBwgxLtHBcZxtfMn7OCim45glZ" = struct {
        pub const build_root = "/home/dan/.cache/zig/p/jwt-0.0.1-HbWOu6Y-AAAazOpY5quBwgxLtHBcZxtfMn7OCim45glZ";
        pub const build_zig = @import("jwt-0.0.1-HbWOu6Y-AAAazOpY5quBwgxLtHBcZxtfMn7OCim45glZ");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
    pub const @"zap-0.9.1-GoeB85JTJAADY1vAnA4lTuU66t6JJiuhGos5ex6CpifA" = struct {
        pub const build_root = "/home/dan/.cache/zig/p/zap-0.9.1-GoeB85JTJAADY1vAnA4lTuU66t6JJiuhGos5ex6CpifA";
        pub const build_zig = @import("zap-0.9.1-GoeB85JTJAADY1vAnA4lTuU66t6JJiuhGos5ex6CpifA");
        pub const deps: []const struct { []const u8, []const u8 } = &.{
        };
    };
};

pub const root_deps: []const struct { []const u8, []const u8 } = &.{
    .{ "zap", "zap-0.9.1-GoeB85JTJAADY1vAnA4lTuU66t6JJiuhGos5ex6CpifA" },
    .{ "jwt", "jwt-0.0.1-HbWOu6Y-AAAazOpY5quBwgxLtHBcZxtfMn7OCim45glZ" },
};
