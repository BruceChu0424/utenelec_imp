package com.uten.imp.application.port;

import com.fasterxml.jackson.databind.JsonNode;

/**
 * 当前登录用户的「功能自管」偏好写入(ADR-152)。这类偏好的键以 {@link #RESERVED_PREFIX} 开头, 值由所属功能
 * 按自己的枚举白名单校验后才写入; 通用偏好接口 {@code PUT /api/user/preferences/{key}} 拒绝写这些键,
 * 防止绕过校验写进任意值。读取仍随会话快照一次带回。
 */
public interface UserPreferenceWritePort {

    /** 功能自管偏好键的前缀(如 {@code ai.chat.settings})。 */
    String RESERVED_PREFIX = "ai.";

    /**
     * upsert 当前用户的一个自管偏好; 调用方必须已按白名单校验并规范化 {@code value}。
     * 访客/未登录抛业务异常; 键不是自管键或值超过 16KB 时拒绝。
     */
    void putOwnedPreference(String key, JsonNode value);
}
