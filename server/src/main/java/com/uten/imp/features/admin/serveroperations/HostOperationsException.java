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
        super("Server operations request could not be confirmed");
        this.code = KNOWN_CODES.contains(code == null ? "" : code) ? code : "UNAVAILABLE";
        this.uncertain = uncertain || "OUTCOME_UNCERTAIN".equals(this.code);
    }

    public String code() { return code; }
    public boolean uncertain() { return uncertain; }

    public ApiException toApiException() {
        if (uncertain) {
            return new ApiException(ErrorCode.SERVER_OPERATION_OUTCOME_UNCERTAIN,
                    "本次服务器操作结果尚未确认，请刷新任务或配置状态，不要再次提交");
        }
        return switch (code) {
            case "INVALID_RUNTIME_BINDING" -> new ApiException(ErrorCode.VALIDATION_FAILED,
                    "无法确认当前数据库与附件存储身份，未启动更新；请联系管理员核对本机部署");
            case "BACKUP_BINDING_MISMATCH" -> new ApiException(ErrorCode.CONFLICT,
                    "当前数据库、附件目录与备份或迁移配置不一致，未启动更新；请联系管理员核对");
            case "AMBIGUOUS_SCHEDULE" -> new ApiException(ErrorCode.VALIDATION_FAILED,
                    "该服务器当地时段受夏令时影响，请更换凌晨 2 点或 3 点时段");
            case "UNSAFE_HOST_CONFIG", "INVALID_HOST_CONFIG" -> new ApiException(ErrorCode.SERVER_OPERATIONS_UNAVAILABLE,
                    "服务器运维配置未通过安全校验，请联系管理员核对配置与文件权限");
            case "BUSY" -> new ApiException(ErrorCode.CONFLICT, "服务器正在执行运维任务，请等待任务完成");
            case "STALE_PREVIEW", "PROTECTED" -> new ApiException(ErrorCode.CONFLICT,
                    "清理预览已变化或包含受保护资源，请重新核对预览");
            case "AUTOMATIC_UPDATES_ENABLED" -> new ApiException(ErrorCode.CONFLICT,
                    "自动更新尚未停用，请联系管理员完成手动更新组件安装");
            case "CONFLICT", "REVISION_CONFLICT", "STALE_CONFIG", "REQUEST_CONFLICT", "RUNTIME_MISMATCH", "STALE_RELEASE", "INVALID_JOB_STATE", "NOT_DUE" -> new ApiException(ErrorCode.CONFLICT,
                    "服务器配置或当前版本已变化，请刷新后重新确认");
            case "VALIDATION_FAILED", "INVALID_REQUEST", "SOURCE_NOT_CONFIGURED", "INVALID_ENDPOINT", "INVALID_BUCKET",
                    "INVALID_PREFIX", "INVALID_CREDENTIALS", "INVALID_PUBLIC_KEY", "INVALID_SCHEDULE" -> new ApiException(ErrorCode.VALIDATION_FAILED,
                    "服务器运维参数或发布源尚未准备好，请核对配置");
            case "FORBIDDEN" -> new ApiException(ErrorCode.FORBIDDEN);
            case "NOT_FOUND" -> new ApiException(ErrorCode.NOT_FOUND);
            case "RECOVERY_REQUIRED" -> new ApiException(ErrorCode.CONFLICT,
                    "服务器运维需要先完成恢复核对，请联系维护人员");
            default -> new ApiException(ErrorCode.SERVER_OPERATIONS_UNAVAILABLE,
                    "服务器运维助手暂不可用；本机环境可能尚未安装，请稍后核对服务器部署");
        };
    }
}
