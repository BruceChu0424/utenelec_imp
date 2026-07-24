package com.uten.imp.features.preference;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;

/**
 * 用户偏好读写。仅员工账号可用（访客账号无偏好语义）。
 * key 长度 ≤100（与表结构一致），value 序列化后 ≤16KB（防止单一偏好撑爆行/网络）。
 */
@Service
@RequiredArgsConstructor
public class UserPreferenceService {

    /** 与 user_preferences.pref_key VARCHAR(100) 一致。 */
    static final int MAX_KEY_LENGTH = 100;
    /** 偏好值序列化后的大小上限（16KB）。 */
    static final int MAX_VALUE_BYTES = 16 * 1024;

    private final UserPreferenceRepository repo;
    private final SecurityContextCurrentUser currentUser;
    private final ObjectMapper objectMapper;

    /** 当前用户全部偏好：key → 任意 JSON value。 */
    @Transactional(readOnly = true)
    public Map<String, JsonNode> all() {
        UUID userId = requireStaffId();
        Map<String, JsonNode> result = new LinkedHashMap<>();
        for (UserPreference pref : repo.findByIdUserId(userId)) {
            result.put(pref.getId().getPrefKey(), parse(pref.getPrefValue()));
        }
        return result;
    }

    /** upsert 单个偏好（body 为任意 JSON value，含 null 字面量）。 */
    @Transactional
    public void put(String key, JsonNode value) {
        UUID userId = requireStaffId();
        if (key == null || key.isBlank() || key.length() > MAX_KEY_LENGTH) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "偏好键长度须为 1-" + MAX_KEY_LENGTH + " 字符");
        }
        if (value == null) {
            // @RequestBody 缺失时 Spring 传 null；JSON null 字面量是 NullNode，不在此分支
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请求体不能为空");
        }
        String json;
        try {
            json = objectMapper.writeValueAsString(value);
        } catch (Exception e) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "偏好值不是合法 JSON");
        }
        if (json.getBytes(StandardCharsets.UTF_8).length > MAX_VALUE_BYTES) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "偏好值大小不能超过 16KB");
        }
        UserPreference pref = repo.findById(new UserPreferenceId(userId, key)).orElseGet(() -> {
            UserPreference p = new UserPreference();
            p.setId(new UserPreferenceId(userId, key));
            return p;
        });
        pref.setPrefValue(json);
        pref.setUpdatedAt(Instant.now());
        repo.save(pref);
    }

    /** 必须已登录且为员工账号（与 profilechange 域 ProfileChangeAccess 一致拒绝访客）。 */
    private UUID requireStaffId() {
        AuthUser u = currentUser.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (u.isVisitor()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "仅员工可访问");
        }
        return u.getId();
    }

    /** 解析存储的 JSON 字符串；历史脏数据兜底为 NullNode，不让单条坏数据拖垮整个读取。 */
    private JsonNode parse(String json) {
        try {
            return objectMapper.readTree(json);
        } catch (Exception e) {
            return objectMapper.nullNode();
        }
    }
}
