package com.uten.imp.features.preference;

import com.fasterxml.jackson.databind.JsonNode;
import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;


/**
 * 用户偏好接口（当前登录用户，无需额外权限点；认证由 SecurityConfig 全局 authenticated 保证，
 * 访客在服务层被拒绝，取用户 id 的方式照抄 profilechange 域的 SecurityContextCurrentUser）。
 *
 * <pre>
 *   PUT /api/user/preferences/{key}    upsert 单个偏好（body 为任意 JSON value）
 * </pre>
 *
 * <p>读取整表随会话快照 {@code GET /api/auth/me} 一次带回(ADR-108)，不再单独提供 GET：
 * 此前 9 个页面偏好各自拉整张表，同一会话 2 秒内重复拉取上百次。
 */
@RestController
@RequestMapping("/api/user/preferences")
@RequiredArgsConstructor
public class UserPreferenceController {

    private final UserPreferenceService service;

    @PutMapping("/{key}")
    public void put(@PathVariable String key, @RequestBody JsonNode value) {
        service.put(key, value);
    }
}
