package com.uten.imp.features.admin.systemsetting;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.Arrays;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;
import java.util.function.Function;
import java.util.stream.Collectors;

/**
 * 系统设置读写服务: 只按 {@link SystemSettingKey} 读写 (ADR-110)。
 *
 * <p>读侧每次直查数据库 (不缓存), 多实例改完即对下一次读取生效。库里值缺失、解析失败或越出
 * 登记范围时一律按登记的默认值处理 (直接改库写坏了也不会让安全阈值失效)。</p>
 *
 * <p>写侧只有两条路: 管理页的批量保存 {@link #writeBatch} (超管 + 控制器 {@code @RequiresStepUp}
 * 再认证) 与业务模块代写单个开关的 {@link #writeDelegated} (权限由调用方校验)。两条路共享同一套
 * 校验、行锁与审计。</p>
 */
@Slf4j
@Service
@RequiredArgsConstructor
public class SystemSettingsService {

    private final SystemSettingRepository repo;
    private final AuditService audit;
    private final TxSessionVars tx;

    public int readInt(SystemSettingKey key) {
        requireType(key, SystemSettingKey.Type.INT);
        return (int) readNumber(key);
    }

    public long readLong(SystemSettingKey key) {
        if (!key.numeric()) {
            throw new IllegalArgumentException(key.key() + " is not numeric");
        }
        return readNumber(key);
    }

    public boolean readBool(SystemSettingKey key) {
        requireType(key, SystemSettingKey.Type.BOOL);
        String raw = rawValue(key);
        if ("true".equalsIgnoreCase(raw)) return true;
        if ("false".equalsIgnoreCase(raw)) return false;
        return Boolean.parseBoolean(key.defaultValue());
    }

    public String readString(SystemSettingKey key) {
        requireType(key, SystemSettingKey.Type.STRING);
        String raw = rawValue(key);
        if (raw == null || raw.isBlank()) {
            return key.defaultValue();
        }
        String trimmed = raw.trim();
        return validationError(key, trimmed) == null ? trimmed : key.defaultValue();
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public List<SystemSettingDto> list() {
        Map<String, SystemSetting> rows = repo.findAll().stream()
                .collect(Collectors.toMap(SystemSetting::getKey, Function.identity()));
        return Arrays.stream(SystemSettingKey.values())
                .sorted(Comparator.comparing((SystemSettingKey k) -> k.category().ordinal())
                        .thenComparingInt(SystemSettingKey::sortOrder))
                .filter(k -> rows.containsKey(k.key()))
                .map(k -> SystemSettingDto.of(k, rows.get(k.key())))
                .toList();
    }

    /**
     * 管理页一次保存的全部修改: 先整体校验 (登记范围 + 期望旧值防覆盖), 再按键序加行锁逐项写入,
     * 每个实际变化的项写一条 update_system_setting 审计。任何一项不合法整批不生效。
     */
    @Transactional
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public List<SystemSettingDto> writeBatch(
            SystemSettingDto.BatchUpdate request, UUID actorId, String actorAccount) {
        if (request == null || request.changes() == null || request.changes().isEmpty()
                || request.changes().size() > 50) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "一次须修改 1 至 50 项设置");
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
            if (SystemSettingKey.of(change.key()).isEmpty()) {
                throw new ApiException(ErrorCode.NOT_FOUND, "设置项不存在，请刷新后重试");
            }
        }
        List<SystemSetting> rows = repo.findAllForUpdate(changes.keySet());
        if (rows.size() != changes.size()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "设置项不存在，请刷新后重试");
        }
        for (SystemSetting row : rows) {
            SystemSettingKey key = SystemSettingKey.of(row.getKey()).orElseThrow();
            SystemSettingDto.Change change = changes.get(row.getKey());
            if (!Objects.equals(row.getValue(), change.expectedValue())) {
                throw new ApiException(ErrorCode.CONFLICT,
                        key.label() + " 已被修改，请刷新设置后重新确认");
            }
            requireValid(key, change.value().trim());
        }
        tx.bindActor(actorId, actorAccount);
        for (SystemSetting row : rows) {
            SystemSettingKey key = SystemSettingKey.of(row.getKey()).orElseThrow();
            apply(key, row, changes.get(row.getKey()).value().trim(),
                    actorId, actorAccount, "update_system_setting");
        }
        repo.flush();
        return rows.stream()
                .map(row -> SystemSettingDto.of(SystemSettingKey.of(row.getKey()).orElseThrow(), row))
                .toList();
    }

    /**
     * 业务模块代写单个设置 (如 HR 任务中心的「庆典自动发送」开关)。与批量保存同一套校验、行锁与
     * 审计, 但不要求超管与再认证: 调用方负责校验自己的权限点, 并给出独立的审计动作名。
     */
    @Transactional
    public void writeDelegated(SystemSettingKey key, String value,
                               UUID actorId, String actorAccount, String auditAction) {
        String normalized = value == null ? "" : value.trim();
        requireValid(key, normalized);
        SystemSetting row = repo.findAllForUpdate(List.of(key.key())).stream().findFirst()
                .orElseThrow(() -> new ApiException(ErrorCode.NOT_FOUND, "设置项不存在：" + key.label()));
        tx.bindActor(actorId, actorAccount);
        apply(key, row, normalized, actorId, actorAccount, auditAction);
        repo.flush();
    }

    private void apply(SystemSettingKey key, SystemSetting row, String value,
                       UUID actorId, String actorAccount, String auditAction) {
        String old = row.getValue();
        if (Objects.equals(old, value)) {
            return;
        }
        row.setValue(value);
        row.setUpdatedBy(actorId);
        repo.save(row);
        audit.logCommitted(actorId, actorAccount, auditAction, "system_settings",
                key.key() + ": " + old + " → " + value, "success");
    }

    private void requireValid(SystemSettingKey key, String value) {
        String error = validationError(key, value);
        if (error != null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, error);
        }
    }

    /** 按登记的类型与范围校验; 合法返回 null, 否则返回给人看的原因。 */
    static String validationError(SystemSettingKey key, String value) {
        String label = key.label();
        switch (key.type()) {
            case INT, LONG -> {
                long numeric;
                try {
                    numeric = key.type() == SystemSettingKey.Type.INT
                            ? Integer.parseInt(value) : Long.parseLong(value);
                } catch (NumberFormatException error) {
                    return label + " 需填写整数";
                }
                if (numeric < key.min() || numeric > key.max()) {
                    return label + " 必须在 " + key.min() + " 至 " + key.max() + " 之间";
                }
                return null;
            }
            case BOOL -> {
                return "true".equalsIgnoreCase(value) || "false".equalsIgnoreCase(value)
                        ? null : label + " 只能是开启或关闭";
            }
            default -> {
                if (value.length() > 1024) {
                    return label + " 不能超过 1024 个字符";
                }
                if (key == SystemSettingKey.CELEBRATION_AUTO_TYPES) {
                    for (String part : value.split(",", -1)) {
                        if (!"birthday".equals(part.trim()) && !"anniversary".equals(part.trim())) {
                            return label + " 仅支持 birthday、anniversary，以英文逗号分隔；停发请关闭自动发布";
                        }
                    }
                }
                if (key == SystemSettingKey.CELEBRATION_PUBLISHER_NAME
                        && (value.isBlank() || value.length() > 100)) {
                    return label + " 须为 1 至 100 个字符";
                }
                return null;
            }
        }
    }

    private long readNumber(SystemSettingKey key) {
        String raw = rawValue(key);
        if (raw != null && validationError(key, raw.trim()) != null) {
            log.warn("系统设置 {} 的库值不合法，按默认值 {} 处理", key.key(), key.defaultValue());
        }
        return effectiveNumber(key, raw);
    }

    /**
     * 把库里读出的原值按登记类型与范围解析; 缺失、解析失败或越界一律返回登记默认值。
     * 供需要在同一条 SQL 里顺带读取设置原值的调用方 (如会话过滤器) 复用同一口径。
     */
    public static long effectiveNumber(SystemSettingKey key, String raw) {
        if (!key.numeric()) {
            throw new IllegalArgumentException(key.key() + " is not numeric");
        }
        if (raw != null && validationError(key, raw.trim()) == null) {
            return Long.parseLong(raw.trim());
        }
        return Long.parseLong(key.defaultValue());
    }

    private String rawValue(SystemSettingKey key) {
        return repo.findById(key.key()).map(SystemSetting::getValue).orElse(null);
    }

    private static void requireType(SystemSettingKey key, SystemSettingKey.Type type) {
        if (key.type() != type) {
            throw new IllegalArgumentException(key.key() + " is " + key.type() + ", not " + type);
        }
    }
}
