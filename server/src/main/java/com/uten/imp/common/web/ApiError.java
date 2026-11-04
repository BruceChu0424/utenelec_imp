package com.uten.imp.common.web;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.time.OffsetDateTime;
import java.util.List;

/** 统一错误响应体。 */
@Getter
@AllArgsConstructor
public class ApiError {

    private final OffsetDateTime timestamp;
    private final int status;
    private final String code;
    private final String message;
    private final List<FieldError> fieldErrors;
    private final java.util.Map<String,Object> details;

    public ApiError(OffsetDateTime timestamp,int status,String code,String message,List<FieldError> fields){this(timestamp,status,code,message,fields,null);}
    public ApiError withDetails(java.util.Map<String,Object> value){return new ApiError(timestamp,status,code,message,fieldErrors,value);}

    public record FieldError(String field, String message) {}

    public static ApiError of(ErrorCode code, String message) {
        return new ApiError(OffsetDateTime.now(), code.getHttpStatus(), code.name(),
                message != null ? message : code.getDefaultMessage(), null);
    }

    public static ApiError of(ErrorCode code, String message, List<FieldError> fieldErrors) {
        return new ApiError(OffsetDateTime.now(), code.getHttpStatus(), code.name(),
                message != null ? message : code.getDefaultMessage(), fieldErrors);
    }
}
