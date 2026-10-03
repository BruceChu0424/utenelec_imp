package com.uten.imp.audit;

import org.junit.jupiter.api.Test;
import org.springframework.dao.DataAccessResourceFailureException;
import org.springframework.jdbc.BadSqlGrammarException;
import org.springframework.jdbc.core.JdbcTemplate;

import java.sql.SQLException;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class AuditRetentionModeReaderTest {
    private final JdbcTemplate jdbc = mock(JdbcTemplate.class);
    private final AuditRetentionModeReader reader = new AuditRetentionModeReader(jdbc);

    @Test
    void installedCapabilityReportsPreservationAndExplicitLegacyModeOnly() {
        when(jdbc.queryForObject(AuditRetentionModeReader.READ_MODE_SQL, String.class))
                .thenReturn("PERMANENT_RETAIN", "PRESERVE_UNCLASSIFIED", "LEGACY_PURGE");
        assertThat(reader.currentMode()).isEqualTo(AuditRetentionModeReader.PurgeMode.PERMANENT_RETAIN);
        assertThat(reader.currentMode()).isEqualTo(AuditRetentionModeReader.PurgeMode.PRESERVE_UNCLASSIFIED);
        assertThat(reader.currentMode()).isEqualTo(AuditRetentionModeReader.PurgeMode.LEGACY_PURGE);
    }

    @Test
    void missingFunctionAndDatabaseFailureNeverClaimPreservationOrLegacyDestruction() {
        when(jdbc.queryForObject(AuditRetentionModeReader.READ_MODE_SQL, String.class))
                .thenThrow(new BadSqlGrammarException("mode", AuditRetentionModeReader.READ_MODE_SQL,
                        new SQLException("function is absent", "42883")))
                .thenThrow(new DataAccessResourceFailureException("unavailable"));
        assertThat(reader.currentMode()).isEqualTo(AuditRetentionModeReader.PurgeMode.UNKNOWN);
        assertThat(reader.currentMode()).isEqualTo(AuditRetentionModeReader.PurgeMode.UNKNOWN);
    }

    @Test
    void nullAndUnrecognizedCapabilityValuesAreUnknown() {
        when(jdbc.queryForObject(AuditRetentionModeReader.READ_MODE_SQL, String.class))
                .thenReturn(null, "future-policy");
        assertThat(reader.currentMode()).isEqualTo(AuditRetentionModeReader.PurgeMode.UNKNOWN);
        assertThat(reader.currentMode()).isEqualTo(AuditRetentionModeReader.PurgeMode.UNKNOWN);
    }
}
