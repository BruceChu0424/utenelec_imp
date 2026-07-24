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
}
