/// STD
const std = @import("std");

const Stat = std.fs.File.Stat;
const Writer = std.Io.Writer;

const comptimePrint = std.fmt.comptimePrint;
const assert = std.debug.assert;

/// Third Party
const zeit = @import("zeit");

const Nanoseconds = zeit.Nanoseconds;

/// Content-Disposition header describes if browsers should display or download the resource
pub const ContentDisposition = union(ContentDispositionTag) {
    @"inline": void,
    attachment: ?[]const u8,

    pub fn toString(comptime Header: ContentDisposition) []const u8 {
        switch (Header) {
            .@"inline" => return "inline",
            .attachment => {
                if (Header.attachment == null)
                    return "attachment"
                else
                    return "attachment; filename=\"" ++ Header.attachment.? ++ "\"";
            },
        }
    }
};

const ContentDispositionTag = enum {
    @"inline",
    attachment,
};

/// Cache-Control header describes if or how, to cache a resource
pub const CacheControl = union(CacheControlTag) {
    no_store: void,
    no_cache: void,
    private: CacheSetting,
    public: CacheSetting,

    pub fn toString(comptime Header: CacheControl) []const u8 {
        switch (Header) {
            .no_store => return "no-store",
            .no_cache => return "no-cache",
            .private => |cache_setting| {
                const cache_setting_string = CacheSetting.toString(cache_setting);
                return if (cache_setting_string.len == 0)
                    "private"
                else
                    "private, " ++ cache_setting_string;
            },
            .public => |cache_setting| {
                const cache_setting_string = comptime CacheSetting.toString(cache_setting);
                return if (cache_setting_string.len == 0)
                    "public"
                else
                    "public, " ++ cache_setting_string;
            },
        }
    }
};

const MaxStale = union(enum) {
    use: bool,
    Setting: u32,
};

pub const CacheSetting = struct {
    max_age: ?u32 = null,
    s_maxage: ?u32 = null,
    max_stale: MaxStale = .{ .use = false },
    min_fresh: ?u32 = null,

    must_revalidate: bool = false,
    proxy_revalidate: bool = false,
    stale_while_revalidate: ?u32 = null,
    stale_if_error: ?u32 = null,

    imutable: bool = false,
    only_if_cached: bool = false,

    pub fn toString(comptime Setting: CacheSetting) []const u8 {
        var res: []const u8 = "";

        if (Setting.max_age != null)
            res = res ++ comptimePrint("max-age={}, ", .{Setting.max_age.?});
        if (Setting.s_maxage != null)
            res = res ++ comptimePrint("s-maxage={}, ", .{Setting.s_maxage.?});
        if (Setting.max_stale == .use and Setting.max_stale.use)
            res = res ++ "max-stale, "
        else if (Setting.max_stale == .Setting)
            res = res ++ comptimePrint("max-stale={}, ", .{Setting.max_stale.Setting});
        if (Setting.min_fresh != null)
            res = res ++ comptimePrint("min-fresh={}, ", .{Setting.min_fresh.?});

        if (Setting.must_revalidate)
            res = res ++ "must-revalidate, ";
        if (Setting.proxy_revalidate)
            res = res ++ "proxy-revalidate, ";
        if (Setting.stale_while_revalidate != null)
            res = res ++ comptimePrint("stale-while-revalidate={}, ", .{Setting.stale_while_revalidate.?});
        if (Setting.stale_if_error != null)
            res = res ++ comptimePrint("stale-if-error={}, ", .{Setting.stale_if_error.?});

        if (Setting.imutable)
            res = res ++ "imutable, ";
        if (Setting.only_if_cached)
            res = res ++ "only-if-cached, ";

        return if (res.len >= 2)
            res[0..(res.len - 2)]
        else
            "";
    }
};

const CacheControlTag = enum {
    no_store,
    no_cache,
    private,
    public,
};

pub const LastModified = struct {
    /// Length of `dest` must be 29 bytes or longer
    pub fn toString(stat: Stat, dest: []u8) !void {
        assert(dest.len >= 29);

        const instant = try zeit.instant(.{ .source = .{ .unix_nano = stat.mtime } });
        var writer = Writer.fixed(dest);

        try instant.time().strftime(&writer, "%a, %d %b %Y %T %Z");

        try writer.flush();
    }
};
