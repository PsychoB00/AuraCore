/// Aura
pub const utils = @This();

/// Gets pointer to a field of parent based on `Name`
pub fn fieldPtr(comptime ParentType: type, comptime Name: []const u8, parent: *const ParentType) *@FieldType(ParentType, Name) {
    return @as(
        *@FieldType(ParentType, Name),
        @ptrFromInt(@intFromPtr(parent) + @offsetOf(ParentType, Name)),
    );
}
