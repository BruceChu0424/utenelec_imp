package com.uten.imp.audit;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

/** Reads installed retention capability without executing the retention job or consulting saved month values. */
@Slf4j
@Component
@RequiredArgsConstructor
public class AuditRetentionModeReader {
    static final String READ_MODE_SQL = "SELECT public.fn_audit_retention_purge_mode()";
    private final JdbcTemplate jdbc;

    public enum PurgeMode {
        PERMANENT_RETAIN,
        PRESERVE_UNCLASSIFIED,
        LEGACY_PURGE,
        UNKNOWN
    }

    public PurgeMode currentMode() {
        try {
            String mode = jdbc.queryForObject(READ_MODE_SQL, String.class);
            return switch (mode == null ? "" : mode.trim()) {
                case "PERMANENT_RETAIN" -> PurgeMode.PERMANENT_RETAIN;
                case "PRESERVE_UNCLASSIFIED" -> PurgeMode.PRESERVE_UNCLASSIFIED;
                case "LEGACY_PURGE" -> PurgeMode.LEGACY_PURGE;
                default -> PurgeMode.UNKNOWN;
            };
        } catch (DataAccessException unavailable) {
            // Older databases have no capability function. Neither that absence
            // nor an unavailable database proves that preservation is enabled.
            log.debug("Audit retention capability unavailable: {}", unavailable.getClass().getSimpleName());
            return PurgeMode.UNKNOWN;
        }
    }
}
