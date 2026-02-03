/// STD
const std = @import("std");

const Allocator = std.mem.Allocator;
const Method = std.http.Method;
const StackTrace = std.builtin.StackTrace;

const hasMethod = std.meta.hasMethod;

const buildin = @import("builtin");

const IsDebug = buildin.mode == .Debug;

/// Aura
const core = @import("../core.zig");

const ParametersType = core.routing.ParametersType;
const ResultType = core.routing.ResultType;

/// Third Party
const zap = @import("zap");

const Request = zap.Request;
const StatusCode = zap.http.StatusCode;

/// Trait check for OnRequestProcessor
///
/// - `Type` must be struct
/// - `Type` must have declaration of what context type it is using, named "context_t"
///     - `context_t` must be decleration of type
/// - `Type` must have declaration of method for initializing, named "init"
///     - `init` must be decleration of method with signature fn (*Type, comptime type, comptime Method, Allocator, *Type.context_t, *const Request) void
/// - `Type` must have declaration of method for initializing in unhandledRequest, named "initUnhandledRequest"
///     - `initUnhandledRequest` must be decleration of method with signature fn (*Type, comptime Method, Allocator, *Type.context_t, *const Request) void
/// - `Type` must have declaration of method for deinitializing, named "deinit"
///     - `deinit` must be decleration of method with signature fn (*Type) void
/// - `Type` may have declaration of method for processing invalid request, named "invalidRequest"
///     - If `Type` has `invalidRequest`, it must be decleration of method with signature fn (*Type, comptime StatusCode, anyerror) void
/// - `Type` may have declaration of method for processing invalid method, named "invalidMethod"
///     - If `Type` has `invalidMethod`, it must be decleration of method with signature fn (*Type, comptime StatusCode) void
/// - `Type` may have declaration of method for processing invalid ResourceParameters, named "invalidParameters"
///     - If `Type` has `invalidParameters`, it must be decleration of method with signature fn (*Type, comptime ParametersType, comptime StatusCode, anyerror) void
/// - `Type` may have declaration of method for processing invalid authorization, named "invalidAuthorization"
///     - If `Type` has `invalidAuthorization`, it must be decleration of method with signature fn (*Type, comptime StatusCode) void
/// - `Type` may have declaration of method for processing controller error, named "controllerError"
///     - If `Type` has `controllerError`, it must be decleration of method with signature fn (*Type, comptime StatusCode, anyerror, if (IsDebug) StackTrace else void) void
/// - `Type` may have declaration of method for processing error for setting http headers, named "setHeadersError"
///     - If `Type` has `setHeadersError`, it must be decleration of method with signature fn (*Type, comptime StatusCode, anyerror, if (IsDebug) StackTrace else void) void
/// - `Type` may have declaration of method for processing error for sending body, named "sendBodyError"
///     - If `Type` has `sendBodyError`, it must be decleration of method with signature fn (*Type, comptime StatusCode, anyerror, if (IsDebug) StackTrace else void) void
/// - `Type` may have declaration of method for processing error for redirect, named "redirectError"
///     - If `Type` has `redirectError`, it must be decleration of method with signature fn (*Type, comptime StatusCode, anyerror, if (IsDebug) StackTrace else void) void
/// - `Type` may have declaration of method for processing crash state after missmatch of status code and ResourceResult, named "matchStatusCodeToResultCrash"
///     - If `Type` has `matchStatusCodeToResultCrash`, it must be decleration of method with signature fn (*Type, comptime ResultType, anyerror) void
/// - `Type` may have declaration of method for processing crash state after ResourceResult is composed incorrectly by controller, named "resultCompositionCrash"
///     - If `Type` has `resultCompositionCrash`, it must be decleration of method with signature fn (*Type, anyerror) void
/// - `Type` may have declaration of method for processing crash state after ResourceResult fails to format, named "formatResultCrash"
///     - If `Type` has `formatResultCrash`, it must be decleration of method with signature fn (*Type, comptime ResultType, anyerror) void
/// - `Type` may have declaration of method for processing crash state after failing to read a file, named "readFileCrash"
///     - If `Type` has `readFileCrash`, it must be decleration of method with signature fn (*Type, anyerror) void
/// - `Type` may have declaration of method for processing status code 2xx, named "success"
///     - If `Type` has `success`, it must be decleration of method with signature fn (*Type, StatusCode) void
/// - `Type` may have declaration of method for processing status code 3xx, named "redirect"
///     - If `Type` has `redirect`, it must be decleration of method with signature fn (*Type, StatusCode) void
pub fn isOnRequestProcessor(comptime Type: type) bool {
    if (@typeInfo(Type) != .@"struct")
        return false;

    const has_context_type =
        @hasDecl(Type, "context_t") and
        @TypeOf(Type.context_t) == type;

    const has_init =
        has_context_type and
        hasMethod(Type, "init") and
        @TypeOf(Type.init) == fn (*Type, comptime type, comptime Method, Allocator, *Type.context_t, *const Request) void;

    const has_init_unhandled_request =
        has_context_type and
        hasMethod(Type, "initUnhandledRequest") and
        @TypeOf(Type.initUnhandledRequest) == fn (*Type, comptime Method, Allocator, *Type.context_t, *const Request) void;

    const has_deinit =
        hasMethod(Type, "deinit") and
        @TypeOf(Type.deinit) == fn (*Type) void;

    const has_valid_invalid_request =
        !hasMethod(Type, "invalidRequest") or
        (hasMethod(Type, "invalidRequest") and
            @TypeOf(Type.invalidRequest) == fn (*Type, comptime StatusCode, anyerror) void);

    const has_valid_invalid_method =
        !hasMethod(Type, "invalidMethod") or
        (hasMethod(Type, "invalidMethod") and
            @TypeOf(Type.invalidMethod) == fn (*Type, comptime StatusCode) void);

    const has_valid_invalid_parameters =
        !hasMethod(Type, "invalidParameters") or
        (hasMethod(Type, "invalidParameters") and
            @TypeOf(Type.invalidParameters) == fn (*Type, comptime ParametersType, comptime StatusCode, anyerror) void);

    const has_valid_invalid_authorization =
        !hasMethod(Type, "invalidAuthorization") or
        (hasMethod(Type, "invalidAuthorization") and
            @TypeOf(Type.invalidAuthorization) == fn (*Type, comptime StatusCode) void);

    const has_valid_controller_error =
        !hasMethod(Type, "controllerError") or
        (hasMethod(Type, "controllerError") and
            @TypeOf(Type.controllerError) == fn (*Type, comptime StatusCode, anyerror, if (IsDebug) StackTrace else void) void);

    const has_valid_set_headers_error =
        !hasMethod(Type, "setHeadersError") or
        (hasMethod(Type, "setHeadersError") and
            @TypeOf(Type.setHeadersError) == fn (*Type, comptime StatusCode, anyerror, if (IsDebug) StackTrace else void) void);

    const has_valid_send_body_error =
        !hasMethod(Type, "sendBodyError") or
        (hasMethod(Type, "sendBodyError") and
            @TypeOf(Type.sendBodyError) == fn (*Type, comptime StatusCode, anyerror, if (IsDebug) StackTrace else void) void);

    const has_valid_redirect_error =
        !hasMethod(Type, "redirectError") or
        (hasMethod(Type, "redirectError") and
            @TypeOf(Type.redirectError) == fn (*Type, comptime StatusCode, anyerror, if (IsDebug) StackTrace else void) void);

    const has_valid_match_status_code_to_result_crash =
        !hasMethod(Type, "matchStatusCodeToResultCrash") or
        (hasMethod(Type, "matchStatusCodeToResultCrash") and
            @TypeOf(Type.matchStatusCodeToResultCrash) == fn (*Type, comptime ResultType, anyerror) void);

    const has_valid_result_composition_crash =
        !hasMethod(Type, "resultCompositionCrash") or
        (hasMethod(Type, "resultCompositionCrash") and
            @TypeOf(Type.resultCompositionCrash) == fn (*Type, anyerror) void);

    const has_valid_format_result_crash =
        !hasMethod(Type, "formatResultCrash") or
        (hasMethod(Type, "formatResultCrash") and
            @TypeOf(Type.formatResultCrash) == fn (*Type, comptime ResultType, anyerror) void);

    const has_valid_read_file_crash =
        !hasMethod(Type, "readFileCrash") or
        (hasMethod(Type, "readFileCrash") and
            @TypeOf(Type.readFileCrash) == fn (*Type, anyerror) void);

    const has_valid_success =
        !hasMethod(Type, "success") or
        (hasMethod(Type, "success") and
            @TypeOf(Type.success) == fn (*Type, StatusCode) void);

    const has_valid_redirect =
        !hasMethod(Type, "redirect") or
        (hasMethod(Type, "redirect") and
            @TypeOf(Type.redirect) == fn (*Type, StatusCode) void);

    return has_init and has_init_unhandled_request and has_deinit and
        has_valid_invalid_request and has_valid_invalid_method and has_valid_invalid_parameters and has_valid_invalid_authorization and
        has_valid_controller_error and has_valid_set_headers_error and has_valid_send_body_error and has_valid_redirect_error and
        has_valid_match_status_code_to_result_crash and has_valid_result_composition_crash and has_valid_format_result_crash and has_valid_read_file_crash and
        has_valid_success and has_valid_redirect;
}
