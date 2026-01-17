/// STD
const std = @import("std");

const Writer = std.Io.Writer;
const WriterError = Writer.Error;
const Reader = std.Io.Reader;

const eql = std.mem.eql;
const eqlIgnoreCase = std.ascii.eqlIgnoreCase;

/// Aura
const core = @import("../../core.zig");

const HttpHeaderType = core.net.headers.HttpHeaderType;

const assertValidate = core.utils.assertValidate;
const validateDate = core.time.validateDate;
const validateHour = core.time.validateHour;
const validateMinute = core.time.validateMinute;
const validateSecond = core.time.validateSecond;
const validateTime = core.time.validate;
const parseInt = core.fmt.parseInt;

/// Third party
const zeit = @import("zeit");

const Time = zeit.Time;
const Month = zeit.Month;

const weekdayFromDays = zeit.weekdayFromDays;
const daysSinceEpoch = zeit.daysSinceEpoch;
const instant = zeit.instant;
const time = zeit.Instant.time;

pub const Date = struct {
    pub const http_header_name: []const u8 = "date";
    pub const http_header_type: HttpHeaderType = .response;
    pub const max_value_len: usize = 29;

    time: Time,

    pub fn validate(self: Date) anyerror!void {
        try validateTime(self.time);

        if (self.time.offset != 0)
            return error.InvalidTimezone;
    }

    /// Formats the header value to `writer`
    pub fn format(self: Date, writer: *Writer) WriterError!void {
        assertValidate(self.validate());

        self.time.strftime(writer, "%a, %d %b %Y %T GMT") catch
            return WriterError.WriteFailed;
    }

    /// Parses the header value from `reader`
    pub fn parse(self: *Date, reader: *Reader) anyerror!void {
        self.time = .{};

        if (reader.bufferedLen() < 29)
            return error.DateTooShort;
        if (reader.bufferedLen() > 29)
            return error.DateTooLong;

        const weekday_value = try reader.take(3);

        if (!eql(u8, try reader.take(2), ", "))
            return error.InvalidWeekdayDayDelimiter;

        const day_value = try reader.take(2);

        self.time.day = try parseInt(u5, day_value);

        if (try reader.takeByte() != ' ')
            return error.InvalidDayMonthDelimiter;

        const month_value = try reader.take(3);
        var month_valid = false;

        inline for (@typeInfo(Month).@"enum".fields) |field| {
            if (eqlIgnoreCase(comptime field.name, month_value)) {
                month_valid = true;
                self.time.month = comptime @enumFromInt(field.value);
                break;
            }
        }

        if (!month_valid)
            return error.InvalidMonth;

        if (try reader.takeByte() != ' ')
            return error.InvalidMonthYearDelimiter;

        const year_value = try reader.take(4);

        self.time.year = try parseInt(i32, year_value);
        try validateDate(self.time.year, self.time.month, self.time.day);

        if (try reader.takeByte() != ' ')
            return error.InvalidYearHourDelimiter;

        const hour_value = try reader.take(2);

        self.time.hour = try parseInt(u5, hour_value);
        try validateHour(self.time.hour);

        if (try reader.takeByte() != ':')
            return error.InvalidHourMinuteDelimiter;

        const minute_value = try reader.take(2);

        self.time.minute = try parseInt(u6, minute_value);
        try validateMinute(self.time.minute);

        if (try reader.takeByte() != ':')
            return error.InvalidMinuteSecondDelimiter;

        const second_value = try reader.take(2);

        self.time.second = try parseInt(u6, second_value);
        try validateSecond(self.time.second);

        const gmt_value = try reader.take(4);

        if (!eqlIgnoreCase(" gmt", gmt_value))
            return error.InvalidTimezone;

        const derived_weekday = weekdayFromDays(daysSinceEpoch(self.time.instant().unixTimestamp()));
        if (!eqlIgnoreCase(derived_weekday.shortName(), weekday_value))
            return error.NonmatchingWeekday;
    }
};
