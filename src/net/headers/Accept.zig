/// STD
const std = @import("std");

const Writer = std.Io.Writer;
const WriterError = Writer.Error;

const Reader = std.Io.Reader;

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const isWhitespace = std.ascii.isWhitespace;
const eql = std.mem.eql;
const partitionPoint = std.sort.partitionPoint;

/// Aura
const core = @import("../../core.zig");

const HttpHeaderType = core.net.headers.HttpHeaderType;
const MediaType = core.net.headers.MediaType;

const assertValidate = core.utils.assertValidate;
const parseFloat = core.fmt.parseFloat;

pub const Accept = struct {
    pub const MediaRange = struct {
        pub const max_value_len: usize = MediaType.max_value_len + 8;

        media_type: MediaType,
        quality: ?f16 = null,

        fn _validateQuality(quality: f16) !void {
            if (quality < 0)
                return error.QualityTooLow;
            if (quality > 1)
                return error.QualityTooHigh;
        }

        pub fn validate(self: MediaRange) !void {
            if (self.quality) |quality|
                try _validateQuality(quality);
        }

        pub fn format(self: MediaRange, writer: *Writer) WriterError!void {
            try self.media_type.format(writer);

            if (self.quality) |quality| {
                try writer.print("; q={d:.3}", .{quality});
            }
        }

        fn _sortPredicate(context: MediaRange, item: MediaRange) bool {
            return item.quality orelse 1 > context.quality orelse 1;
        }

        pub fn parse(self: *MediaRange, reader: *Reader) anyerror!void {
            try self.media_type.parse(reader);

            self.quality = null;
            if (reader.bufferedLen() == 0)
                return;

            const delimiter_value = try reader.peekByte();

            if (delimiter_value == ',')
                return;
            if (delimiter_value != ';')
                return error.InvalidDelimiter;
            if (reader.bufferedLen() <= 3)
                return error.ExcessHeaderTail;

            reader.toss(1);

            const whitespace_value = try reader.peekByte();
            if (isWhitespace(whitespace_value))
                reader.toss(1);

            const quality_name_value = try reader.take(2);

            if (!eql(u8, quality_name_value, "q="))
                return error.InvalidQualityName;

            const quality_value = try reader.takeDelimiterExclusive(',');
            if (quality_value.len > 5)
                return error.QualityTooFine;

            self.quality = try parseFloat(f16, quality_value);

            try _validateQuality(self.quality.?);
        }
    };

    const media_ranges_capacity: usize = 16;

    pub const http_header_name: []const u8 = "accept";
    pub const http_header_type: HttpHeaderType = .request;
    pub const max_value_len: usize = media_ranges_capacity * (MediaRange.max_value_len + 2);

    media_ranges: []const MediaRange,

    fn _validateMediaRanges(media_ranges: []const MediaRange) !void {
        if (media_ranges.len == 0)
            return error.TooFewMediaRanges;
        if (media_ranges.len > media_ranges_capacity)
            return error.TooManyMediaRanges;

        var max_quality: f16 = media_ranges[0].quality orelse 1;

        for (media_ranges) |media_range| {
            try media_range.validate();

            if (max_quality < media_range.quality orelse 1)
                return error.MediaRangeNotInOrder;

            max_quality = media_range.quality orelse 1;
        }
    }

    pub fn validate(self: Accept) anyerror!void {
        try _validateMediaRanges(self.media_ranges);
    }

    /// Formats the header value to `writer`
    pub fn format(self: Accept, writer: *Writer) WriterError!void {
        assertValidate(self.validate());

        for (self.media_ranges) |media_range| {
            try writer.print("{f}, ", .{media_range});
        }
        writer.undo(2);
    }

    /// Parses the header value from `reader`
    ///
    /// `allocator` MUST BE arena allocator, this parse is leaky
    pub fn parse(self: *Accept, reader: *Reader, allocator: Allocator) anyerror!void {
        var media_ranges = try ArrayList(MediaRange).initCapacity(allocator, media_ranges_capacity);
        defer media_ranges.deinit(allocator);
        var index: usize = 0;

        while (index < media_ranges_capacity) {
            var media_range: MediaRange = undefined;
            try media_range.parse(reader);

            const insert_index = partitionPoint(MediaRange, media_ranges.items, media_range, MediaRange._sortPredicate);
            try media_ranges.insert(allocator, insert_index, media_range);

            if (reader.bufferedLen() == 0)
                break;

            const media_range_delimiter_value = try reader.takeByte();

            if (media_range_delimiter_value != ',')
                return error.InvalidMediaRangeDelimiter;

            const whitespace_value = try reader.peekByte();

            if (isWhitespace(whitespace_value))
                reader.toss(1);

            index += 1;
        }

        try _validateMediaRanges(media_ranges.items);

        self.media_ranges = try media_ranges.toOwnedSlice(allocator);

        if (reader.bufferedLen() != 0)
            return error.ExcessHeaderTail;
    }
};
