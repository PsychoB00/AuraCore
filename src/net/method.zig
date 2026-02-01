/// STD
const std = @import("std");

const Method = std.http.Method;

const Writer = std.Io.Writer;
const WriterError = Writer.Error;

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

pub fn formatToLower(method: Method, writer: *Writer) WriterError!void {
    switch (method) {
        .GET => return try writer.writeAll("get"),
        .POST => return try writer.writeAll("post"),
        .PUT => return try writer.writeAll("put"),
        .PATCH => return try writer.writeAll("patch"),
        .DELETE => return try writer.writeAll("delete"),
        .HEAD => return try writer.writeAll("head"),
        .OPTIONS => return try writer.writeAll("options"),
        .CONNECT => return try writer.writeAll("connect"),
        .TRACE => return try writer.writeAll("trace"),
    }
}
