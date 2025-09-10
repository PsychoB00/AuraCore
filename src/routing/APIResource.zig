pub const ParametersType = enum {
    path,
    query,
    body,
};

pub const ResourceParametersError = error{
    NotFound,
    BadRequest,
};

pub fn isResourceParameters(comptime Type: type) bool {
    return @hasDecl(Type, "parameters_type") and @TypeOf(Type.parameters_type) == ParametersType and
        @hasDecl(Type, "structure") and @TypeOf(Type.structure) == type and
        @hasField(Type, "data") and @FieldType(Type, "data") == Type.structure;
}
