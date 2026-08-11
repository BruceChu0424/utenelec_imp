package com.uten.imp.common.web;

import lombok.Getter;

/** 业务错误码（统一返回 {code, message, fieldErrors?}，避免泄露后端细节/堆栈）。 */
@Getter
public enum ErrorCode {

    BAD_CREDENTIALS(401, "账号或密码错误"),
    ACCOUNT_LOCKED(401, "账号已锁定，请稍后再试"),
    ACCOUNT_DISABLED(401, "账号已停用"),
    UNAUTHORIZED(401, "未登录或会话已过期"),
    FORBIDDEN(403, "无权限访问"),
    PASSWORD_CHANGE_REQUIRED(403, "首次登录必须修改密码后才能继续"),
    REMOTE_ACCESS_DENIED(403, "该账号未授权外网（云端）访问"),
    NOT_FOUND(404, "资源不存在"),
    CONFLICT(409, "数据冲突"),
    ARRIVAL_EXCEPTION_PENDING(409, "到货数量异常，等待指定财务负责人审核"),
    VALIDATION_FAILED(422, "参数校验失败"),
    PASSWORD_TOO_WEAK(422, "密码强度不足"),
    PASSWORD_REUSE(422, "不能与最近用过的密码相同"),
    RATE_LIMITED(429, "请求过于频繁，请稍后再试"),
    BUSINESS(400, "业务处理失败"),
    IS_EMPLOYEE(422, "该手机号为优腾员工账号，请走员工通道登录"),
    SMS_CODE_INVALID(400, "验证码错误"),
    SMS_CODE_EXPIRED(400, "验证码已过期，请重新获取"),
    SMS_RATE_LIMITED(429, "验证码发送过于频繁，请稍后再试"),
    MALFORMED_REQUEST(400, "请求体格式错误"),
    PAYLOAD_TOO_LARGE(413, "请求体过大"),
    VISITOR_NOT_FOUND(404, "访客申请不存在"),
    VISITOR_BLOCKED(403, "访客账号已被限制"),
    IMPERSONATION_READ_ONLY(403, "模拟身份为只读模式，不允许写 / 审 / 删 / 导出操作"),
    PRIMARY_UNAVAILABLE(503, "云端暂不可写：本地主库不可达，恢复网络后重试"),
    INTERNAL(500, "服务器内部错误");

    private final int httpStatus;
    private final String defaultMessage;

    ErrorCode(int httpStatus, String defaultMessage) {
        this.httpStatus = httpStatus;
        this.defaultMessage = defaultMessage;
    }
}
