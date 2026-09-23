package com.uten.imp.application.port;

import com.fasterxml.jackson.databind.JsonNode;

import java.util.Map;

/**
 * 当前登录用户的偏好整表(只读)。会话快照(/api/auth/me, ADR-108)经本端口一次带回,
 * 前端各页面偏好改读快照, 不再各自 GET 整张偏好表。
 */
public interface UserPreferenceReadPort {

    /** 当前用户全部偏好: key → 任意 JSON value; 访客/未登录抛业务异常。 */
    Map<String, JsonNode> currentUserPreferences();
}
