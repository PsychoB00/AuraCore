/// Third party
const zeit = @import("zeit");

pub const Time = zeit.Time;

const Month = zeit.Month;

pub fn validateOffset(offset: i32) !void {
    if (offset < -43_200)
        return error.OffsetTooLow;
    if (offset > 50_400)
        return error.OffsetTooHigh;
}

pub fn validateDate(year: i32, month: Month, day: u5) !void {
    if (year < 0)
        return error.InvalidYear;
    if (day > month.lastDay(year))
        return error.InvalidDay;
}

pub fn validateHour(hour: u5) !void {
    if (hour > 23)
        return error.InvalidHour;
}

pub fn validateMinute(minute: u6) !void {
    if (minute > 59)
        return error.InvalidMinute;
}

pub fn validateSecond(second: u6) !void {
    if (second > 59)
        return error.InvalidSecond;
}

pub fn validate(self: Time) !void {
    try validateOffset(self.offset);
    try validateDate(self.year, self.month, self.day);
    try validateHour(self.hour);
    try validateMinute(self.minute);
    try validateMinute(self.second);
}
