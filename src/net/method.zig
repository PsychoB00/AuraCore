/// STD
const std = @import("std");

const Method = std.http.Method;

pub fn methodToLower(comptime MethodType: Method) []const u8 {
    switch (MethodType) {
        .GET => return "get",
        .POST => return "post",
        .PUT => return "put",
        .PATCH => return "patch",
        .DELETE => return "delete",
        .HEAD => return "head",
        .OPTIONS => return "options",
        .CONNECT => return "connect",
        .TRACE => return "trace",
    }
}

pub fn methodToUpper(comptime MethodType: Method) []const u8 {
    return @tagName(MethodType);
}
