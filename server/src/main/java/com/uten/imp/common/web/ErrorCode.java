package com.uten.imp.common.web;

import lombok.Getter;

/** 业务错误码（统一返回 {code, message, fieldErrors?}，避免泄露后端细节/堆栈）。 */
@Getter
public enum ErrorCode {

    BAD_CREDENTIALS(401, "账号或密码错误，多次失败将临时锁定"),
    ACCOUNT_LOCKED(401, "账号已锁定，请稍后再试"),
    ACCOUNT_DISABLED(401, "账号已停用"),
    UNAUTHORIZED(401, "未登录或会话已过期"),
    // 单设备顶号：会话被新的一次登录撤销。与普通过期区分，客户端据此弹「当前设备已下线」。
    SESSION_REPLACED(401, "账号已在其他设备登录，本设备已自动下线"),
    FORBIDDEN(403, "当前账号无权执行此操作，请联系管理员核对操作权限和数据范围"),
    READ_SCOPE_CHANGED(403, "数据访问范围已变化，请重新打开页面后核对"),
    PASSWORD_CHANGE_REQUIRED(403, "首次登录必须修改密码后才能继续"),
    REMOTE_ACCESS_DENIED(403, "该账号未授权外网(云端)访问"),
    MFA_REQUIRED(403, "外网访问需要验证动态验证码，请验证后自行继续原操作"),
    MFA_ENROLLMENT_REQUIRED(403, "请先回公司内网绑定动态验证码，再使用外网访问"),
    MFA_INVALID(422, "动态验证码错误、过期或已经使用，请使用新的验证码"),
    MFA_LOCKED(429, "动态验证码错误次数过多，请十五分钟后再试"),
    MFA_ENROLLMENT_EXPIRED(409, "本次绑定已过期或不属于当前会话，请重新开始绑定"),
    MFA_UNAVAILABLE(503, "动态验证码服务暂不可用，请联系管理员"),
    /** 敏感操作需要先重新输入登录密码 (再认证凭证缺失、过期、已用过或不属于本会话)。 */
    REAUTH_REQUIRED(403, "这一步需要先重新输入登录密码确认"),
    /** 再认证 (或改密时的原密码) 输错; 不用 401, 避免前端当成登录过期去刷新重放。 */
    REAUTH_FAILED(422, "密码不正确"),
    /** 再认证连续输错达到上限，暂时不能再验证密码。 */
    REAUTH_LOCKED(429, "密码输错次数过多，请稍后再试"),
    NOT_FOUND(404, "资源不存在"),
    /** 路径存在但不支持这种请求方式 (如已删除的写接口只剩查询)。 */
    METHOD_NOT_ALLOWED(405, "不支持这种请求方式"),
    CONFLICT(409, "数据或操作条件已变化，请刷新后重新核对"),
    DAILY_REPORT_REVIEW_VERSION_CONFLICT(409, "这张日报已经变化，请刷新并重新核对后审核"),
    DAILY_REPORT_MATERIAL_REVIEW_CONFLICT(409, "材料余额或可退来源已变化，请刷新余料明细并重新核对后审核"),
    DAILY_REPORT_LEGACY_APPROVAL_RECEIPT(409, "原审核按旧规则登记，请先核对原回执；所见版本未被验证"),
    ARRIVAL_EXCEPTION_PENDING(409, "到货数量超出已批准范围，请在业务审核中心完成超量到货审批"),
    SUBCONTRACT_SHORT_DELIVERY_UNACKNOWLEDGED(409, "到货数量明显少于订货量，需仓库确认后登记并通知委外判定"),
    VALIDATION_FAILED(422, "填写内容未通过校验，请按字段提示修正后提交"),
    PASSWORD_TOO_WEAK(422, "密码强度不足"),
    PASSWORD_REUSE(422, "不能与最近用过的密码相同"),
    RATE_LIMITED(429, "请求过于频繁，请稍后再试"),
    REMOTE_CAPACITY_REJECTED(429, "当前外网操作较多，请稍后再试；未开始本次业务处理"),
    BUSINESS(400, "业务处理失败"),
    IS_EMPLOYEE(422, "该手机号为员工账号，请走员工通道登录"),
    SMS_CODE_INVALID(400, "验证码错误"),
    SMS_CODE_EXPIRED(400, "验证码已过期，请重新获取"),
    SMS_RATE_LIMITED(429, "验证码发送过于频繁，请稍后再试"),
    MALFORMED_REQUEST(400, "请求体格式错误"),
    UNSUPPORTED_MEDIA_TYPE(415, "请求内容格式不受支持"),
    PAYLOAD_TOO_LARGE(413, "请求体过大"),
    VISITOR_NOT_FOUND(404, "访客申请不存在"),
    VISITOR_BLOCKED(403, "访客账号已被限制"),
    IMPERSONATION_READ_ONLY(403, "模拟身份为只读模式，不允许写 / 审 / 删 / 导出操作"),
    PRIMARY_UNAVAILABLE(503, "暂时无法连接公司业务服务器；已发送操作请先核对结果"),
    /** 同时校验密码的人太多 (密码哈希并发闸门已满), 稍后重试即可。 */
    AUTH_BUSY(503, "登录验证的人较多，请稍后几秒再试"),
    SERVER_OPERATIONS_UNAVAILABLE(503, "服务器运维助手暂不可用"),
    SERVER_OPERATION_OUTCOME_UNCERTAIN(503, "服务器操作结果待确认，请刷新状态后核对，不要重复提交"),
    INTERNAL(500, "服务器内部错误");

    private final int httpStatus;
    private final String defaultMessage;

    ErrorCode(int httpStatus, String defaultMessage) {
        this.httpStatus = httpStatus;
        this.defaultMessage = defaultMessage;
    }
}
