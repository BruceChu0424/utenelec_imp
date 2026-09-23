package com.uten.imp.common.web;

import lombok.Getter;

import java.util.List;

/** 业务异常，由 GlobalExceptionHandler 翻译为 ApiError。 */
@Getter
public class ApiException extends RuntimeException {

    private final ErrorCode code;
    private final List<ApiError.FieldError> fieldErrors;

    public ApiException(ErrorCode code) {
        super(code.getDefaultMessage());
        this.code = code;
        this.fieldErrors = null;
    }

    public ApiException(ErrorCode code, String message) {
        super(message);
        this.code = code;
        this.fieldErrors = null;
    }

    /**
     * 同一请求稍后原样重发可能成功(瞬时冲突、等锁超时等), 本次什么都没生效。
     * 响应带 {@code Retry-After} 提示; 默认否。
     */
    public boolean retryable() {
        return false;
    }

    /** 带逐项说明的业务异常(如到货登记逐行短交明细), fieldErrors 原样进 ApiError。 */
    public ApiException(ErrorCode code, String message, List<ApiError.FieldError> fieldErrors) {
        super(message);
        this.code = code;
        this.fieldErrors = fieldErrors == null || fieldErrors.isEmpty() ? null : List.copyOf(fieldErrors);
    }
}
