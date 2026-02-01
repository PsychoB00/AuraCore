/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;

const assert = std.debug.assert;
const comptimePrint = std.fmt.comptimePrint;
const isAscii = std.ascii.isAscii;
const utf8ValidateSlice = std.unicode.utf8ValidateSlice;

/// Aura
const core = @import("../core.zig");

const ResultType = core.routing.ResultType;
const MediaType = core.net.headers.MediaType;
const TextSubtype = MediaType.TextSubtype;
const Charset = core.net.headers.Charset;
const ApplicationSubtype = MediaType.ApplicationSubtype;
const JsonInterpreter = core.json.DefaultJsonInterpreter;

const isResourceResult = core.routing.isResourceResult;
const formatLeaky = JsonInterpreter.formatLeaky;

/// Result for larger and more complex data
///
/// - `Structure` is a type representing content of the body, can be optional type
/// - `Structure` can be an optional type only if ResultRedirect is defined in endpoint
/// - `ResultMediaType` is a MediaType which specify parsing
/// - `ResultMediaType` mustn't be a wildcard
/// - `Structure` must be valid parsing type for `ResultMediaType'
pub fn ResultBody(comptime Structure: type, comptime ResultMediaType: MediaType) type {
    const is_structure_optional = @typeInfo(Structure) == .optional;
    const structure_type =
        if (is_structure_optional)
            @typeInfo(Structure).optional.child
        else
            Structure;

    // `Structure` correctness assertion
    ResultMediaType.validateType(structure_type) catch |err|
        @compileError(comptimePrint(
            "`Structure` is not a valid type for `ResultMediaType`, cause {s}",
            .{@errorName(err)},
        ));

    if (ResultMediaType.isWildcard())
        @compileError("`ResultMediaType` mustn't be a wildcard");

    return struct {
        const ResultBodyType = @This();
        pub const result_type: ResultType = .body;
        pub const structure = Structure;
        pub const result_media_type = ResultMediaType;

        data: Structure,

        pub fn format(
            self: *const ResultBodyType,
            dest: *[]u8,
            allocator: Allocator,
        ) !void {
            if (comptime is_structure_optional)
                assert(self.data != null);

            switch (ResultMediaType) {
                inline .application => |application| {
                    switch (application) {
                        inline .json => try formatLeaky(Structure, &self.data, dest, allocator),
                        inline .xml, .xhtml_xml => {
                            const text_data: []const u8 =
                                if (comptime is_structure_optional)
                                    self.data.?
                                else
                                    self.data;

                            try ApplicationSubtype.validateText(text_data);

                            dest.* = try allocator.dupe(u8, text_data);
                        },
                        inline .wildcard => unreachable,
                    }
                },
                inline .text => |text| {
                    var charset: ?Charset = null;

                    switch (text) {
                        inline .plain => |plain| charset = plain,
                        inline .html => |html| charset = html,
                        inline .wildcard => unreachable,
                    }

                    const text_data: []const u8 =
                        if (comptime is_structure_optional)
                            self.data.?
                        else
                            self.data;

                    try TextSubtype.validateText(text_data, charset);

                    dest.* = try allocator.dupe(u8, text_data);
                },
                inline .wildcard => unreachable,
            }
        }
    };
}

/// Trait check for ResultBody
///
/// - `Type` must fulfill the isResourceResult trait check
/// - Declaration `result_type` from ResourceResult must have value ResultType.body
/// - `Type` must have decleration of resulting media type, named "result_media_type"
///     - `result_media_type` must be declaretion of MediaType
/// - `Type` must be able to generate `Type` using its declarations and function ResultBody
pub fn isResultBody(comptime Type: type) bool {
    if (!isResourceResult(Type))
        return false;

    const is_body_result_type =
        Type.result_type == .body;

    const has_result_media_type =
        @hasDecl(Type, "result_media_type") and
        @TypeOf(Type.result_media_type) == MediaType;

    const can_generate_self =
        is_body_result_type and has_result_media_type and
        ResultBody(Type.structure, Type.result_media_type) == Type;

    return is_body_result_type and can_generate_self;
}
