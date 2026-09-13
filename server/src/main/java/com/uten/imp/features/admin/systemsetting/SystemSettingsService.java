package com.uten.imp.features.admin.systemsetting;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Sort;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.UUID;
import java.util.Map;
import java.util.LinkedHashMap;
import java.util.Objects;

/**
 * 系统设置读写服务。
 *
 * <p>读侧（{@link #readInt}/{@link #readLong}）被各安全组件（限流/锁定/密码/令牌/短信/导出上限）调用：
 * Reads remain uncached so committed policy changes are visible across instances.
 *
 * <p>写侧（{@link #write}）多重防护：① 仅超管可达（authorization:manage + DB superAdmin）+
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
    private final TxSessionVars tx;

    public int readInt(String key, int def) {
        return repo.findById(key).map(s -> parseInt(s.getValue(), def)).orElse(def);
    }

    public long readLong(String key, long def) {
        return repo.findById(key).map(s -> parseLong(s.getValue(), def)).orElse(def);
    }

    public boolean readBool(String key, boolean def) {
        return repo.findById(key).map(s -> parseBoolean(s.getValue(), def)).orElse(def);
    }

    public String readString(String key, String def) {
        return repo.findById(key)
                .map(s -> s.getValue() == null || s.getValue().isBlank() ? def : s.getValue().trim())
                .orElse(def);
    }

    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public List<SystemSettingDto> list() {
        return repo.findAll(Sort.by("category", "sortOrder")).stream()
                .map(SystemSettingDto::of).toList();
    }

    @Transactional
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public SystemSettingDto write(String key, String value, String password, UUID actorId, String actorAccount) {
        tx.bindActor(actorId, actorAccount);
        // ① 二次密码确认：系统设置是安全/业务策略的高危配置，即使 access token 泄露，改设置还需账号密码。
        UserAccount user = userRepo.findById(actorId)
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED, "用户不存在"));
        if (!user.isSuperAdmin()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "仅超级管理员可修改系统设置");
        }
        if (password == null || password.length() > 256
                || !passwordEncoder.matches(password, user.getPasswordHash())) {
            throw new ApiException(ErrorCode.BAD_CREDENTIALS);
        }
        // ② 类型/非负校验
        SystemSetting s = repo.findAllForUpdate(List.of(key)).stream().findFirst()
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "设置项不存在: " + key));
        String normalized = value == null ? "" : value.trim();
        validate(s.getValueType(), normalized, key, s.getLabel());
        // ③ 落库 + ④ 审计
        String old = s.getValue();
        s.setValue(normalized);
        s.setUpdatedBy(actorId);
        repo.save(s);
        repo.flush();
        audit.logCommitted(actorId, actorAccount, "update_system_setting", "system_settings",
                key + ": " + old + " → " + normalized, "success");
        return SystemSettingDto.of(s);
    }

    /**
     * Validates the entire edit before the first mutation. Password hashing is
     * intentionally performed once, before row locks are acquired. The expected
     * values prevent a stale administrator page from overwriting a later edit.
     */
    @Transactional
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public List<SystemSettingDto> writeBatch(
            SystemSettingDto.BatchUpdate request, UUID actorId, String actorAccount) {
        if (request == null || request.changes() == null || request.changes().isEmpty()
                || request.changes().size() > 50) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "一次须修改 1 至 50 项设置");
        }
        UserAccount user = userRepo.findById(actorId)
                .orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED, "用户不存在"));
        if (!user.isSuperAdmin()) {
            throw new ApiException(ErrorCode.FORBIDDEN, "仅超级管理员可修改系统设置");
        }
        if (request.password() == null || request.password().length() > 256
                || !passwordEncoder.matches(request.password(), user.getPasswordHash())) {
            throw new ApiException(ErrorCode.BAD_CREDENTIALS);
        }
        Map<String, SystemSettingDto.Change> changes = new LinkedHashMap<>();
        for (SystemSettingDto.Change change : request.changes()) {
            if (change == null || change.key() == null || change.key().isBlank()
                    || change.key().length() > 128 || change.value() == null
                    || change.value().length() > 1024 || change.expectedValue() == null
                    || change.expectedValue().length() > 1024
                    || changes.putIfAbsent(change.key(), change) != null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "设置项不得重复且须包含原值与新值");
            }
        }
        List<SystemSetting> settings = repo.findAllForUpdate(changes.keySet());
        if (settings.size() != changes.size()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "设置项不存在，请刷新后重试");
        }
        for (SystemSetting setting : settings) {
            SystemSettingDto.Change change = changes.get(setting.getKey());
            if (!Objects.equals(setting.getValue(), change.expectedValue())) {
                throw new ApiException(ErrorCode.CONFLICT,
                        setting.getLabel() + " 已被修改，请刷新设置后重新确认");
            }
            validate(setting.getValueType(), change.value().trim(), setting.getKey(), setting.getLabel());
        }
        tx.bindActor(actorId, actorAccount);
        for (SystemSetting setting : settings) {
            String old = setting.getValue();
            String value = changes.get(setting.getKey()).value().trim();
            if (Objects.equals(old, value)) continue;
            setting.setValue(value);
            setting.setUpdatedBy(actorId);
            repo.save(setting);
            audit.logCommitted(actorId, actorAccount, "update_system_setting", "system_settings",
                    setting.getKey() + ": " + old + " → " + value, "success");
        }
        repo.flush();
        return settings.stream().map(SystemSettingDto::of).toList();
    }

    /** Explicit capacity limits for every numeric runtime policy. Existing values
     * are never rewritten; the bound applies when an administrator edits a key. */
    private static final Map<String, NumericBounds> NUMERIC_BOUNDS = Map.ofEntries(
            bound("login_rate_limit_per_minute", 1, 100_000),
            bound("login_ip_rate_limit_per_minute", 1, 1_000_000),
            bound("lockout_threshold", 1, 1_000),
            bound("lockout_minutes", 1, 525_600),
            bound("password_history_size", 0, 100),
            bound("export_rate_limit_per_minute", 1, 10_000),
            bound("jwt_access_ttl_minutes", 5, 43_200),
            bound("jwt_refresh_ttl_days", 1, 3_650),
            bound("sms_code_ttl_minutes", 1, 1_440),
            bound("sms_send_interval_seconds", 1, 86_400),
            bound("sms_daily_limit", 1, 10_000),
            bound("export_max_rows", 1, 100_000),
            bound("session_idle_timeout_minutes", 1, 525_600),
            bound("audit_hot_retention_months", 1, 120),
            bound("audit_archive_retention_months", 0, 240));

    private record NumericBounds(long minimum, long maximum) {}

    private static Map.Entry<String, NumericBounds> bound(String key, long minimum, long maximum) {
        return Map.entry(key, new NumericBounds(minimum, maximum));
    }

    private void validate(String type, String value, String key, String label) {
        try {
            switch (type) {
                case "int", "long" -> {
                    long numeric = "int".equals(type) ? Integer.parseInt(value) : Long.parseLong(value);
                    NumericBounds bounds = NUMERIC_BOUNDS.get(key);
                    if (bounds != null && (numeric < bounds.minimum() || numeric > bounds.maximum())) {
                        throw new ApiException(ErrorCode.VALIDATION_FAILED,
                                label + " 必须在 " + bounds.minimum() + " 至 " + bounds.maximum() + " 之间");
                    }
                    if (numeric < 0) throw new ApiException(ErrorCode.VALIDATION_FAILED, label + " 不能为负数");
                }
                case "bool" -> {
                    if (!"true".equalsIgnoreCase(value) && !"false".equalsIgnoreCase(value)) {
                        throw new ApiException(ErrorCode.VALIDATION_FAILED, label + " 需为 true/false");
                    }
                }
                default -> {
                    if (value.length() > 1024) {
                        throw new ApiException(ErrorCode.VALIDATION_FAILED, label + " 不能超过 1024 个字符");
                    }
                    if ("celebration.auto_types".equals(key)) {
                        for (String part : value.split(",", -1)) {
                            if (!"birthday".equals(part.trim()) && !"anniversary".equals(part.trim())) {
                                throw new ApiException(ErrorCode.VALIDATION_FAILED,
                                        label + " 仅支持 birthday、anniversary，以英文逗号分隔；停发请关闭自动发布");
                            }
                        }
                    }
                    if ("celebration.publisher_name".equals(key) && (value.isBlank() || value.length() > 100)) {
                        throw new ApiException(ErrorCode.VALIDATION_FAILED, label + " 须为 1 至 100 个字符");
                    }
                }
            }
        } catch (NumberFormatException error) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, label + " 需为有效的 " + type + " 数值");
        }
    }

    private int parseInt(String v, int def) {
        try { return Integer.parseInt(v); } catch (Exception e) { return def; }
    }

    private long parseLong(String v, long def) {
        try { return Long.parseLong(v); } catch (Exception e) { return def; }
    }

    private boolean parseBoolean(String v, boolean def) {
        if (v == null) return def;
        return "true".equalsIgnoreCase(v.trim());
    }
}
