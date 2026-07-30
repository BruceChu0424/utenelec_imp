package com.uten.imp.features.preference;

import com.fasterxml.jackson.databind.JsonNode;
import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/**
 * 用户偏好接口（当前登录用户，无需额外权限点；认证由 SecurityConfig 全局 authenticated 保证，
 * 访客在服务层被拒绝，取用户 id 的方式照抄 profilechange 域的 SecurityContextCurrentUser）。
 *
 * <pre>
 *   GET /api/user/preferences          当前用户全部偏好
 *   PUT /api/user/preferences/{key}    upsert 单个偏好（body 为任意 JSON value）
 * </pre>
 */
@RestController
@RequestMapping("/api/user/preferences")
@RequiredArgsConstructor
public class UserPreferenceController {

    private final UserPreferenceService service;

    @GetMapping
    public Map<String, Object> all() {
        return Map.of("preferences", service.all());
    }

    @PutMapping("/{key}")
    public void put(@PathVariable String key, @RequestBody JsonNode value) {
        service.put(key, value);
    }
}
