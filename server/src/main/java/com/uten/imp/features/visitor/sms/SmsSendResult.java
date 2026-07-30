package com.uten.imp.features.visitor.sms;

/**
 * 短信提交结果。
 *
 * <p>{@link #UNCERTAIN} 表示请求可能已被供应商接收（例如响应在网络中丢失），调用方不得
 * 自动重发或作废本地验证码，否则用户可能收到一条必然不可用的短信。
 */
public enum SmsSendResult {
    ACCEPTED,
    REJECTED,
    UNCERTAIN
}
