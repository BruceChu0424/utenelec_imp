package com.uten.imp.features.admin.systemsetting;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Sort;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.UUID;

/**
 * 系统设置读写服务。
 *
 * <p>读侧（{@link #readInt}/{@link #readLong}）被各安全组件（限流/锁定/密码/令牌/短信/导出上限）调用：
 * <b>不缓存</b>（每次 findById）——设置表仅 11 行 PK 查询亚毫秒，且管理员改设置后**立即生效**。
 *
 * <p>写侧（{@link #write}）多重防护：① 仅超管可达（Controller @PreAuthorize user:manage）+
 * ② <b>二次密码确认</b>（高危配置，即使 access token 被盗也需账号密码才能改）+ ③ 类型/非负校验 +
 * ④ 落库 + ⑤ 审计（记 谁/改了哪项/旧→新值）。
 */
@Service
@RequiredArgsConstructor
public class SystemSettingsService {

    private final SystemSettingRepository repo;
    private final AuditService audit;
    private final PasswordEncoder passwordEncoder;
    private final UserAccountRepository userRepo;

    public int readInt(String key, int def) {
        return repo.findById(key).map(s -> parseInt(s.getValue(), def)).orElse(def);
    }

    public long readLong(String key, long def) {
        return repo.findById(key).map(s -> parseLong(s.getValue(), def)).orElse(def);
    }

    public List<SystemSettingDto> list() {
        return repo.findAll(Sort.by("category", "sortOrder")).stream()
                .map(SystemSettingDto::of).toList();
    }

    @Transactional
    public SystemSettingDto write(String key, String value, String password, UUID actorId, String actorAccount) {
        // ① 二次密码确认：系统设置是安全/业务策略的高危配置，即使 access token 泄露，改设置还需账号密码。
        UserAccount user = userRepo.findById(actorId)
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED, "用户不存在"));
        if (password == null || !passwordEncoder.matches(password, user.getPasswordHash())) {
            throw new ApiException(ErrorCode.BAD_CREDENTIALS);
        }
        // ② 类型/非负校验
        SystemSetting s = repo.findById(key)
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "设置项不存在: " + key));
        String normalized = value == null ? "" : value.trim();
        validate(s.getValueType(), normalized, key, s.getLabel());
        // ③ 落库 + ④ 审计
        String old = s.getValue();
        s.setValue(normalized);
        s.setUpdatedBy(actorId);
        repo.save(s);
        repo.flush();
        audit.logExplicit(actorId, actorAccount, "update_system_setting", "system_settings",
                key + ": " + old + " → " + normalized, "success");
        return SystemSettingDto.of(repo.findById(key).orElse(s));
    }

    private void validate(String type, String value, String key, String label) {
        try {
            switch (type) {
                case "int" -> {
                    int v = Integer.parseInt(value);
                    if (v < 0) throw new ApiException(ErrorCode.VALIDATION_FAILED, label + " 不能为负数");
                }
                case "long" -> {
                    long v = Long.parseLong(value);
                    if (v < 0) throw new ApiException(ErrorCode.VALIDATION_FAILED, label + " 不能为负数");
                }
                case "bool" -> {
                    if (!"true".equalsIgnoreCase(value) && !"false".equalsIgnoreCase(value)) {
                        throw new ApiException(ErrorCode.VALIDATION_FAILED, label + " 需为 true/false");
                    }
                }
                default -> { /* string：不限 */ }
            }
        } catch (NumberFormatException e) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, label + "（" + key + "）需为 " + type + " 数值");
        }
    }

    private int parseInt(String v, int def) {
        try { return Integer.parseInt(v); } catch (Exception e) { return def; }
    }

    private long parseLong(String v, long def) {
        try { return Long.parseLong(v); } catch (Exception e) { return def; }
    }
}
