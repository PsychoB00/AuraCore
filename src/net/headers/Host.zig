/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;

const Writer = std.Io.Writer;
const WriterError = Writer.Error;
const Reader = std.Io.Reader;

const Ip4Address = std.net.Ip4Address;
const Ip6Address = std.net.Ip6Address;

const assert = std.debug.assert;
const parseInt = std.fmt.parseInt;
const isHostnameValid = std.net.isValidHostName;

/// Aura
const core = @import("../../core.zig");

const HttpHeaderType = core.net.headers.HttpHeaderType;

const assertValidate = core.utils.assertValidate;

/// Http header Host, specifies the host and port number of the server to which the request is being sent
pub const Host = struct {
    const HostnameTag = enum {
        ip4,
        ip6,
        dns,
    };

    pub const Hostname = union(HostnameTag) {
        pub const IP4 = struct {
            pub const max_value_len: usize = 21;

            address: [4]u8,
            port: ?u16 = null,

            pub fn format(self: IP4, writer: *Writer) WriterError!void {
                const port =
                    if (self.port) |port|
                        port
                    else
                        0;
                const ip4_address = Ip4Address.init(self.address, port);

                try writer.print("{f}", .{ip4_address});

                // If port is not specified remove ":0" from the end
                if (self.port == null)
                    writer.undo(2);
            }

            // Only takes from `reader` if it starts with valid ip4 address else it returns error.InvalidAddress
            pub fn parse(self: *IP4, reader: *Reader) !void {
                // Get hostname
                const address_value = reader.peekDelimiterExclusive(':') catch return error.InvalidAddress;
                const address = Ip4Address.parse(address_value, 0) catch return error.InvalidAddress;
                self.address[0] = @truncate(address.sa.addr >> 3 * 8);
                self.address[1] = @truncate(address.sa.addr >> 2 * 8);
                self.address[2] = @truncate(address.sa.addr >> 1 * 8);
                self.address[3] = @truncate(address.sa.addr);
                reader.toss(address_value.len);

                // Port check
                if (reader.bufferedLen() == 0) {
                    self.port = null;
                    return;
                }

                // Validate address port delimiter
                const address_port_delimiter_value = try reader.take(1);
                if (address_port_delimiter_value[0] != ':')
                    return error.InvalidAddressPortDelimiter;

                // Get port
                const port_value = try reader.take(reader.bufferedLen());
                self.port = try parseInt(u16, port_value, 10);
            }
        };

        pub const IP6 = struct {
            pub const max_value_len: usize = 47;

            address: [16]u8,
            port: ?u16 = null,

            pub fn format(self: IP6, writer: *Writer) WriterError!void {
                const port =
                    if (self.port) |port|
                        port
                    else
                        0;
                const ip6_address = Ip6Address.init(self.address, port, 0, 0);

                try writer.print("{f}", .{ip6_address});

                // If port is not specified remove ":0" from the end
                if (self.port == null)
                    writer.undo(2);
            }

            // Only takes from `reader` if it starts with valid ip6 address else it returns error.InvalidAddress
            pub fn parse(self: *IP6, reader: *Reader) !void {
                // Get hostname
                const address_value = reader.peekDelimiterInclusive(']') catch return error.InvalidAddress;
                if (address_value[0] != '[')
                    return error.InvalidAddress;

                const address = Ip6Address.resolve(address_value[1 .. address_value.len - 2], 0) catch return error.InvalidAddress;
                @memcpy(&self.address, &address.sa.addr);
                reader.toss(address_value.len);

                // Port check
                if (reader.bufferedLen() == 0) {
                    self.port = null;
                    return;
                }

                // Validate address port delimiter
                const address_port_delimiter_value = try reader.take(1);
                if (address_port_delimiter_value[0] != ':')
                    return error.InvalidAddressPortDelimiter;

                // Get port
                const port_value = try reader.take(reader.bufferedLen());
                self.port = try parseInt(u16, port_value, 10);
            }
        };

        pub const DNS = struct {
            const max_hostname_len: usize = 253;

            pub const max_value_len: usize = max_hostname_len + 6;

            hostname: []const u8,
            port: ?u16 = null,

            fn _validateHostname(hostname: []const u8) !void {
                if (hostname.len == 0)
                    return error.HostnameTooShort;
                if (!isHostnameValid(hostname))
                    return error.InvalidHostname;
            }

            pub fn format(self: DNS, writer: *Writer) WriterError!void {
                assertValidate(_validateHostname(self.hostname));

                try writer.writeAll(self.hostname);

                if (self.port) |port|
                    try writer.print(":{d}", .{port});
            }

            pub fn parse(self: *DNS, reader: *Reader, allocator: Allocator) !void {
                // Get hostname
                const hostname_value = try reader.takeDelimiterExclusive(':');
                try _validateHostname(hostname_value);

                self.hostname = try allocator.dupe(u8, hostname_value);

                // Port check
                if (reader.bufferedLen() == 0) {
                    self.port = null;
                    return;
                }

                // Validate hostname port delimiter
                const hostname_port_delimiter_value = try reader.take(1);
                if (hostname_port_delimiter_value[0] != ':')
                    return error.InvalidHostnamePortDelimiter;

                // Get port
                const port_value = try reader.take(reader.bufferedLen());
                self.port = try parseInt(u16, port_value, 10);
            }
        };

        pub const max_value_len: usize = DNS.max_value_len;

        ip4: IP4,
        ip6: IP6,
        dns: DNS,

        pub fn format(self: Hostname, writer: *Writer) WriterError!void {
            try switch (self) {
                .ip4 => |ip4| ip4.format(writer),
                .ip6 => |ip6| ip6.format(writer),
                .dns => |dns| dns.format(writer),
            };
        }

        pub fn parse(self: *Hostname, reader: *Reader, allocator: Allocator) !void {
            self.* = @unionInit(Hostname, "ip4", undefined);
            // Try ip4
            self.ip4.parse(reader) catch |ip4_err| switch (ip4_err) {
                error.InvalidAddress => {
                    // Try ip6
                    self.* = @unionInit(Hostname, "ip6", undefined);
                    self.ip6.parse(reader) catch |ip6_err| switch (ip6_err) {
                        error.InvalidAddress => {
                            self.* = @unionInit(Hostname, "dns", undefined);
                            // Try dns
                            try self.dns.parse(reader, allocator);
                        },
                        else => return ip6_err,
                    };
                },
                else => return ip4_err,
            };
        }
    };

    pub const http_header_name: []const u8 = "host";
    pub const http_header_type: HttpHeaderType = .request;
    pub const max_value_len: usize = Hostname.max_value_len;

    hostname: Hostname,

    /// Formats the header value to `writer`
    pub fn format(self: Host, writer: *Writer) WriterError!void {
        try self.hostname.format(writer);
    }

    /// Parses the header value from `reader`
    ///
    /// `allocator` MUST BE arena allocator, this parse is leaky
    pub fn parse(self: *Host, reader: *Reader, allocator: Allocator) !void {
        try self.hostname.parse(reader, allocator);
    }
};
