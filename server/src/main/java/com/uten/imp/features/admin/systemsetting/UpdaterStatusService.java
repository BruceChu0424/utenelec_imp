package com.uten.imp.features.admin.systemsetting;

import java.time.OffsetDateTime;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/** Compatibility projection only. A historical scheduler receipt is never current host authority. */
@Service
public class UpdaterStatusService {
    private final SystemSettingRepository repository;

    @Autowired
    public UpdaterStatusService(SystemSettingRepository repository) {
        this.repository = repository;
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public Status read() {
        SystemSetting row = repository.findById(SystemSettingKey.UPDATER_CHECK_INTERVAL_DAYS.key()).orElse(null);
        int requested = (int) SystemSettingsService.effectiveNumber(
                SystemSettingKey.UPDATER_CHECK_INTERVAL_DAYS, row == null ? null : row.getValue());
        return new Status(requested, row == null ? null : row.getUpdatedAt(), null, null, null,
                null, null, null, "自动更新间隔已退役；实际手动模式及定时器状态请查看服务器运维页", false, true);
    }

    public record Status(int requestedIntervalDays, OffsetDateTime requestedUpdatedAt,
            Integer appliedIntervalDays, OffsetDateTime configUpdatedAt, OffsetDateTime checkedAt,
            OffsetDateTime nextCheckAt, OffsetDateTime lastAttemptAt, String lastResult,
            String error, boolean available, boolean stale) {}
}
