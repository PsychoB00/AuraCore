/// STD
const std = @import("std");

const Writer = std.Io.Writer;
const WriterError = Writer.Error;
const Reader = std.Io.Reader;

const Allocator = std.mem.Allocator;

const Method = std.http.Method;

const stringToEnum = std.meta.stringToEnum;
const isWhitespace = std.ascii.isWhitespace;

/// Aura
const core = @import("../../core.zig");

const HttpHeaderType = core.net.headers.HttpHeaderType;

const assertValidate = core.utils.assertValidate;
const formatMethodToLower = core.net.formatMethodToLower;

/// Http header Host, lists the set of request methods supported by a resource
pub const Allow = struct {
    const methods_capacity: usize = 9;

    pub const http_header_name: []const u8 = "allow";
    pub const http_header_type: HttpHeaderType = .response;
    pub const max_value_len: usize = 60;

    methods: []const Method,

    fn _validatMethods(methods: []const Method) !void {
        if (methods.len == 0)
            return error.TooFewMethods;
        if (methods.len > methods_capacity)
            return error.TooManyMethods;

        for (methods, 0..) |method, index| {
            if (index == methods.len - 1)
                continue;

            for (methods[index + 1 ..]) |check_method| {
                if (@intFromEnum(method) == @intFromEnum(check_method))
                    return error.DuplicateMethods;
            }
        }
    }

    pub fn validate(self: Allow) anyerror!void {
        try _validatMethods(self.methods);
    }

    /// Formats the header value to `writer`
    pub fn format(self: Allow, writer: *Writer) WriterError!void {
        assertValidate(self.validate());

        for (self.methods) |method| {
            try formatMethodToLower(method, writer);
            try writer.writeAll(", ");
        }
        writer.undo(2);
    }

    /// Parses the header value from `reader`
    ///
    /// `allocator` MUST BE arena allocator, this parse is leaky
    pub fn parse(self: *Allow, reader: *Reader, allocator: Allocator) anyerror!void {
        var methods: [methods_capacity]Method = undefined;
        var index: usize = 0;

        while (index < methods_capacity) {
            const method_value = try reader.takeDelimiterExclusive(',');

            methods[index] = stringToEnum(Method, method_value);

            index += 1;

            if (reader.bufferedLen() == 0)
                // `reader` is empty
                break;
            if (reader.bufferedLen() < 4)
                // `reader` doesn't have minimal nessesary bytes for Method
                return error.ExcessHeaderTail;

            const method_delimiter_value = try reader.takeByte();

            if (method_delimiter_value != ',')
                return error.InvalidMethodDelimiter;

            const whitespace_value = try reader.peekByte();

            if (isWhitespace(whitespace_value))
                reader.toss(1);
        }

        if (reader.bufferedLen() != 0)
            return error.ExcessHeaderTail;

        try _validatMethods(&methods);

        self.methods = try allocator.dupe(Method, methods[0 .. index + 1]);
    }
};
