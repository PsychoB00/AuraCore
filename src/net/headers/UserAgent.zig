/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;

const Writer = std.Io.Writer;
const WriterError = Writer.Error;
const Reader = std.Io.Reader;

/// Aura
const core = @import("../../core.zig");

const HttpHeaderType = core.net.headers.HttpHeaderType;

const assertValidate = core.utils.assertValidate;
const validateRFCToken = core.net.headers.validateRFCToken;

/// Http header User-Agent, is header that lets servers and network peers identify the application,
/// operating system, vendor, and/or version of the requesting user agent.
pub const UserAgent = struct {
    pub const Product = struct {
        const max_name_len: usize = 32;
        const max_version_len: usize = 32;
        const comments_capacity: usize = 4;
        const max_comment_len: usize = 64;

        pub const max_value_len: usize = max_name_len + max_version_len + (comments_capacity * max_comment_len) + 4;

        name: []const u8,
        version: ?[]const u8,
        comments: ?[][]const u8,

        pub fn validate(self: Product) !void {
            try _validateName(self.name);
            try _validateVersion(self.version);
            try _validateComments(self.comments);
        }

        fn _validateName(name: []const u8) !void {
            if (name.len == 0)
                return error.NameTooShort;
            if (name.len > max_name_len)
                return error.NameTooLong;

            try validateRFCToken(name);
        }

        fn _validateVersion(version: ?[]const u8) !void {
            if (version == null)
                return;

            if (version.?.len == 0)
                return error.VersionTooShort;
            if (version.?.len > max_version_len)
                return error.VersionTooLong;

            try validateRFCToken(version.?);
        }

        fn _validateComments(comments: ?[][]const u8) !void {
            if (comments == null)
                return;

            if (comments.?.len == 0)
                return error.TooFewComments;
            if (comments.?.len > comments_capacity)
                return error.TooManyComments;

            for (comments.?) |comment| {
                try _validateComment(comment);
            }
        }

        fn _validateComment(comment: []const u8) !void {
            if (comment.len == 0)
                return error.CommentTooShort;
            if (comment.len > max_comment_len)
                return error.CommentTooLong;

            var bracket_counter: usize = 0;
            for (comment) |character| {
                if (character < ' ' or character > '~')
                    return error.InvalidCharacter;

                if (character == ')') {
                    if (bracket_counter == 0)
                        return error.UnopenedBracket;

                    bracket_counter -= 1;
                } else if (character == '(')
                    bracket_counter += 1;
            }

            if (bracket_counter != 0)
                return error.UnclosedBrackets;
        }

        pub fn format(self: Product, writer: *Writer) WriterError!void {
            assertValidate(_validateName(self.name));
            assertValidate(_validateVersion(self.version));
            assertValidate(_validateComments(self.comments));

            try writer.writeAll(self.name);
            if (self.version) |version|
                try writer.print("/{s}", .{version});
            if (self.comments) |comments| {
                for (comments) |comment| {
                    try writer.writeAll(" (");
                    for (comment) |character| {
                        if (character == '\\' or character == '(' or character == ')')
                            try writer.print("\\{c}", .{character})
                        else
                            try writer.writeByte(character);
                    }

                    try writer.writeByte(')');
                }
            }
        }

        pub fn parse(self: *Product, reader: *Reader, allocator: Allocator) !void {
            const buffer_till_slash = try reader.peekDelimiterExclusive('/');

            const buffer_till_space = try reader.peekDelimiterExclusive(' ');
            const buffer_till_tab = try reader.peekDelimiterExclusive('\t');
            const buffer_till_whitespace =
                if (buffer_till_space.len <= buffer_till_tab.len)
                    buffer_till_space
                else
                    buffer_till_tab;

            // Get name and version
            var name_value: []u8 = undefined;
            var version_value: ?[]u8 = undefined;

            if (buffer_till_slash.len < buffer_till_whitespace.len) {
                // `reader` contains both name and version for current product
                name_value = try reader.take(buffer_till_slash.len);
                reader.toss(1);
                version_value = try reader.take(buffer_till_whitespace.len - buffer_till_slash.len - 1);
            } else {
                // `reader` contains only name for current product
                name_value = try reader.take(buffer_till_whitespace.len);
                reader.toss(1);
                version_value = null;
            }

            try _validateName(name_value);
            try _validateVersion(version_value);

            // Assign name and version
            self.name = try allocator.dupe(u8, name_value);
            self.version =
                if (version_value != null)
                    try allocator.dupe(u8, version_value.?)
                else
                    null;
            if (reader.bufferedLen() == 0) {
                // `reader` is empty
                self.comments = null;
                return;
            }
            if (reader.bufferedLen() < 2)
                // `reader` doesn't have minimal nessesary bytes for other products or comments
                return error.ExcessHeaderTail;

            const product_comments_delimiter = try reader.peek(2);
            if (product_comments_delimiter[1] != '(') {
                self.comments = null;
                return;
            }

            // Get comments
            var comments: [comments_capacity][]const u8 = undefined;
            var index: usize = 0;

            while (index < comments_capacity) {
                // Validate comment head delimiter
                const comment_head_delimiter_value = try reader.take(2);
                if (!(comment_head_delimiter_value[0] == ' ' or comment_head_delimiter_value[0] == '\t'))
                    return error.InvalidCommentsDelimiter;
                if (comment_head_delimiter_value[1] != '(')
                    return error.UnopenedComment;

                var comment: [max_comment_len]u8 = undefined;

                var character_index_offset: usize = 0;
                var current_backslash_index: ?usize = null;
                var bracket_counter: usize = 0;
                var toss_len: ?usize = null;
                var comment_len: ?usize = null;

                // Iterate through `reader` up to max_comment_len + 1 to find `)` withou backslash before it
                for (0..max_comment_len + 1) |character_index| {
                    if (reader.bufferedLen() <= character_index)
                        break;
                    const character = reader.buffered()[character_index];

                    // Handle end of comment
                    if (character_index >= max_comment_len and character != ')') {
                        toss_len = character_index + 1;
                        break;
                    }
                    if (character == ')' and current_backslash_index == null) {
                        toss_len = character_index + 1;
                        comment_len = character_index - character_index_offset;
                        break;
                    }

                    // Decode backslahed character
                    if (current_backslash_index) |backslash_index| {
                        switch (character) {
                            '\\' => {},
                            ')' => {
                                if (bracket_counter == 0)
                                    return error.UnopenedBracket;

                                bracket_counter -= 1;
                            },
                            '(' => bracket_counter += 1,
                            else => return error.InvalidCharacter,
                        }
                        comment[backslash_index - character_index_offset] = character;

                        current_backslash_index = null;
                        character_index_offset += 1;

                        continue;
                    }

                    if (character == '\\') {
                        current_backslash_index = character_index;
                        continue;
                    }

                    if (character < ' ' or character > '~' or character == '(')
                        return error.InvalidCharacter;

                    comment[character_index - character_index_offset] = character;
                }

                // Validate comment length
                if (toss_len == null)
                    return error.UnclosedComment;
                if (comment_len == null)
                    return error.CommentTooLong;
                if (comment_len.? == 0)
                    return error.CommentTooShort;

                if (bracket_counter != 0)
                    return error.UnclosedBrackets;

                // Toss from `reader` last comment and its closing bracket
                reader.toss(toss_len.?);
                comments[index] = try allocator.dupe(u8, comment[0..comment_len.?]);

                if (reader.bufferedLen() == 0)
                    // `reader` is empty
                    break;
                if (reader.bufferedLen() < 2)
                    // `reader` doesn't have minimal nessesary bytes for other comments or products
                    return error.ExcessHeaderTail;

                index += 1;

                // Check if `reader` has more comments
                const comment_comment_delimiter = try reader.peek(2);
                if (comment_comment_delimiter[1] == '(' and index >= comments_capacity)
                    return error.TooManyComments;
                if (comment_comment_delimiter[1] != '(')
                    break;
            }

            self.comments = try allocator.dupe([]const u8, comments[0..index]);
        }
    };

    const products_capacity: usize = 16;

    pub const http_header_name: []const u8 = "user-agent";
    pub const http_header_type: HttpHeaderType = .request;
    pub const max_value_len: usize = products_capacity * (Product.max_value_len + 1);

    products: []Product,

    pub fn validate(self: UserAgent) anyerror!void {
        try _validateProducts(self.products);
    }

    fn _validateProducts(products: []Product) !void {
        if (products.len == 0)
            return error.TooFewProducts;
        if (products.len > products_capacity)
            return error.TooManyProducts;

        for (products) |product| {
            try product.validate();
        }
    }

    /// Formats the header value to `writer`
    pub fn format(self: UserAgent, writer: *Writer) WriterError!void {
        assertValidate(_validateProducts(self.products));

        for (self.products) |product| {
            try writer.print("{f} ", .{product});
        }

        writer.undo(1);
    }

    /// Parses the header value from `reader`
    ///
    /// `allocator` MUST BE arena allocator, this parse is leaky
    pub fn parse(self: *UserAgent, reader: *Reader, allocator: Allocator) anyerror!void {
        var products: [max_value_len]Product = undefined;
        var index: usize = 0;

        while (index < products_capacity) {
            try products[index].parse(reader, allocator);

            index += 1;

            if (reader.bufferedLen() == 0)
                // `reader` is empty
                break;
            if (reader.bufferedLen() < 2)
                // `reader` doesn't have minimal nessesary bytes for product
                return error.ExcessHeaderTail;

            // Products delimiter validation
            const products_delimiter_value = try reader.takeByte();
            if (!(products_delimiter_value == ' ' or products_delimiter_value == '\t'))
                return error.InvalidProductsDelimiter;
        }

        // Products validation reduced from `_validateProducts` to avoid duplicate checks
        if (products.len == 0)
            return error.TooFewProducts;
        if (reader.bufferedLen() != 0)
            return error.TooManyProducts;

        self.products = try allocator.dupe(Product, products[0..index]);
    }
};
