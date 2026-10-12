package com.uten.imp.features.admin.systemsetting;

import com.uten.imp.audit.AuditService;
import com.uten.imp.security.TxSessionVars;
import org.springframework.jdbc.core.JdbcTemplate;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;
import static org.mockito.Mockito.mock;

/** Test-only bridge: exercise the real registered reader against persisted JDBC rows; reject writes. */
public final class SystemSettingsUpgradeReadProbe {
    private SystemSettingsUpgradeReadProbe() {}

    public static boolean isValidStoredChoice(SystemSettingKey key, String value) {
        return SystemSettingsService.validationError(key, value) == null;
    }

    public static SystemSettingsService freshReader(JdbcTemplate jdbc, AuditService audit, TxSessionVars tx) {
        SystemSettingRepository repository = mock(SystemSettingRepository.class, invocation -> {
            return switch (invocation.getMethod().getName()) {
                case "findById" -> jdbc.query("SELECT * FROM system_settings WHERE key=?",
                        (rs, index) -> row(rs), invocation.getArgument(0, String.class)).stream().findFirst();
                case "findAll" -> jdbc.query("SELECT * FROM system_settings ORDER BY key", (rs, index) -> row(rs));
                default -> throw new AssertionError("An application restart/setting read must not mutate settings: "
                        + invocation.getMethod().getName());
            };
        });
        return new SystemSettingsService(repository, audit, tx);
    }

    private static SystemSetting row(ResultSet rs) throws SQLException {
        var setting = new SystemSetting();
        setting.setKey(rs.getString("key")); setting.setValue(rs.getString("value"));
        setting.setUpdatedAt(rs.getObject("updated_at", OffsetDateTime.class));
        setting.setUpdatedBy(rs.getObject("updated_by", UUID.class));
        return setting;
    }
}
