package com.uten.imp.features.admin.serveroperations;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.util.Set;

/** Contains a bounded error code only, never credentials, local paths or helper exception text. */
public final class HostOperationsException extends RuntimeException {
    private static final Set<String> KNOWN_CODES = Set.of(
            "UNAVAILABLE", "TIMEOUT", "INVALID_RESPONSE", "BUSY", "CONFLICT", "REVISION_CONFLICT",
            "VALIDATION_FAILED", "INVALID_REQUEST", "SOURCE_NOT_CONFIGURED", "FORBIDDEN", "NOT_FOUND",
            "RECOVERY_REQUIRED", "UNSAFE_HOST_CONFIG", "INVALID_STATE", "SCAN_LIMIT", "STALE_PREVIEW", "PROTECTED",
            "STALE_CONFIG", "REQUEST_CONFLICT", "RUNTIME_MISMATCH", "AUTOMATIC_UPDATES_ENABLED",
            "INVALID_HOST_CONFIG", "INVALID_ENDPOINT", "INVALID_BUCKET", "INVALID_PREFIX", "INVALID_CREDENTIALS",
            "INVALID_PUBLIC_KEY", "INVALID_SCHEDULE", "AMBIGUOUS_SCHEDULE", "STALE_RELEASE", "INVALID_JOB_STATE", "NOT_DUE", "OUTCOME_UNCERTAIN",
            "INVALID_RUNTIME_BINDING", "BACKUP_BINDING_MISMATCH");
    private final String code;
    private final boolean uncertain;

    public HostOperationsException(String code) { this(code, false); }

    public HostOperationsException(String code, boolean uncertain) {
        this(code, uncertain, false);
    }

    private HostOperationsException(String code, boolean uncertain, boolean localPlatformUnsupported) {
        super("Server operations request could not be confirmed");
        this.code = localPlatformUnsupported ? ServerOperationFailures.HOST_PLATFORM_UNSUPPORTED
                : KNOWN_CODES.contains(code == null ? "" : code) || ServerOperationFailures.known(code)
                ? code : "UNAVAILABLE";
        this.uncertain = uncertain || "OUTCOME_UNCERTAIN".equals(this.code);
    }

    /** Reserved local fact: helper frames and stored receipts cannot claim platform support. */
    static HostOperationsException platformUnsupported() {
        return new HostOperationsException(null, false, true);
    }

    boolean isPlatformUnsupported() { return ServerOperationFailures.HOST_PLATFORM_UNSUPPORTED.equals(code); }

    public String code() { return code; }
    public boolean uncertain() { return uncertain; }

    /** Safe availability projection shared by update and storage status. */
    public ServerOperationsDto.Failure availabilityFailure() {
        return isPlatformUnsupported() ? ServerOperationFailures.platformUnsupported()
                : ServerOperationFailures.unavailable(code);
    }

    public ApiException toApiException() {
        if (uncertain) {
            return new ApiException(ErrorCode.SERVER_OPERATION_OUTCOME_UNCERTAIN,
                    ServerOperationFailures.guidance("OUTCOME_UNCERTAIN"));
        }
        return switch (code) {
            case "INVALID_RUNTIME_BINDING" -> new ApiException(ErrorCode.VALIDATION_FAILED,
                    guidance());
            case "BACKUP_BINDING_MISMATCH" -> new ApiException(ErrorCode.CONFLICT,
                    guidance());
            case "AMBIGUOUS_SCHEDULE" -> new ApiException(ErrorCode.VALIDATION_FAILED,
                    "该服务器当地时段受夏令时影响，请更换凌晨 2 点或 3 点时段。" + guidance());
            case "UNSAFE_HOST_CONFIG", "INVALID_HOST_CONFIG" -> new ApiException(ErrorCode.SERVER_OPERATIONS_UNAVAILABLE,
                    "服务器运维配置未通过安全校验。" + guidance());
            case "BUSY" -> new ApiException(ErrorCode.CONFLICT, guidance());
            case "STALE_PREVIEW", "PROTECTED" -> new ApiException(ErrorCode.CONFLICT,
                    "清理预览已变化或包含受保护资源，请重新核对预览");
            case "AUTOMATIC_UPDATES_ENABLED" -> new ApiException(ErrorCode.CONFLICT,
                    guidance());
            case "CONFLICT", "REVISION_CONFLICT", "STALE_CONFIG", "REQUEST_CONFLICT", "RUNTIME_MISMATCH", "STALE_RELEASE", "INVALID_JOB_STATE", "NOT_DUE" -> new ApiException(ErrorCode.CONFLICT,
                    guidance());
            case "VALIDATION_FAILED", "INVALID_REQUEST", "SOURCE_NOT_CONFIGURED", "INVALID_ENDPOINT", "INVALID_BUCKET",
                    "INVALID_PREFIX", "INVALID_CREDENTIALS", "INVALID_PUBLIC_KEY", "INVALID_SCHEDULE" -> new ApiException(ErrorCode.VALIDATION_FAILED,
                    guidance());
            case "FORBIDDEN" -> new ApiException(ErrorCode.FORBIDDEN, guidance());
            case "NOT_FOUND" -> new ApiException(ErrorCode.NOT_FOUND);
            case "RECOVERY_REQUIRED" -> new ApiException(ErrorCode.CONFLICT,
                    guidance());
            default -> new ApiException(ErrorCode.SERVER_OPERATIONS_UNAVAILABLE,
                    guidance());
        };
    }

    private String guidance() {
        if (isPlatformUnsupported()) return ServerOperationFailures.message(ServerOperationFailures.platformUnsupported());
        return ServerOperationFailures.guidance(ServerOperationFailures.rpcCode(code));
    }
}
