/// STD
const std = @import("std");

const Writer = std.Io.Writer;
const WriterError = Writer.Error;

const assert = std.debug.assert;
const isAscii = std.ascii.isAscii;
const utf8ValidateSlice = std.unicode.utf8ValidateSlice;

/// Aura
const core = @import("../core.zig");

const ResultType = core.routing.ResultType;
const MediaType = core.net.headers.MediaType;
const TextSubtype = MediaType.TextSubtype;
const Charset = TextSubtype.Charset;

const assertValidate = core.utils.assertValidate;
const isResourceResult = core.routing.isResourceResult;

/// Result for larger and more complex data
///
/// - `Structure` is a type representing content of the body, can be optional type.
/// - `ResultMediaType` is either a MediaType which specify strict parsing or null
///   in which case the parsing is derived from Accept header
/// - `ResultMediaType` with value, mustn't be a wildcard
/// - `Structure` must be valid parsing type for MediaType in `ResultMediaType' if it has a value
pub fn ResultBody(comptime Structure: type, comptime ResultMediaType: ?MediaType) type {
    const is_structure_optional = @typeInfo(Structure) == .optional;
    const structure_type =
        if (is_structure_optional)
            @typeInfo(Structure).optional.child
        else
            Structure;

    // `Structure` correctness assertion
    if (ResultMediaType) |StrictResultMediaType|
        StrictResultMediaType.validateType(structure_type) catch
            @compileError("`Structure` is not a valid type for `ResultMediaType`");

    if (ResultMediaType == null)
        @compileError("UNSUPPORTED");

    if (ResultMediaType.?.isWildcard())
        @compileError("`ResultMediaType` mustn't be a wildcard");

    return struct {
        const ResultBodyType = @This();
        pub const result_type: ResultType = .body;
        pub const structure = Structure;
        pub const result_media_type = ResultMediaType;

        data: Structure,

        pub fn format(self: ResultBodyType, writer: *Writer) WriterError!void {
            if (comptime is_structure_optional)
                if (self.data == null)
                    return;

            switch (ResultMediaType.?) {
                inline .application => |application| {
                    switch (application) {
                        inline .json => {},
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

                    assertValidate(TextSubtype.validateText(text_data, charset));

                    try writer.writeAll(text_data);
                },
                inline .wildcard => unreachable,
            }
        }
    };
}

/// Trait check for ResultBody
///
/// - `Type` must fullfil the isResourceResult trait check
/// - Declaration `result_type` from ResourceResult must have value ResultType.body
/// - `Type` must have decleration of resulting media type, named "result_media_type"
///     - `result_media_type` must be declaretion of ?MediaType
/// - `Type` must be able to generate `Type` using its declarations and function ResultBody
pub fn isResultBody(comptime Type: type) bool {
    if (!isResourceResult(Type))
        return false;

    const is_body_result_type =
        Type.result_type == .body;

    const has_result_media_type =
        @hasDecl(Type, "result_media_type") and
        @TypeOf(Type.result_media_type) == ?MediaType;

    const can_generate_self =
        is_body_result_type and has_result_media_type and
        ResultBody(Type.structure, Type.result_media_type) == Type;

    return is_body_result_type and can_generate_self;
}
