package com.uten.imp.support;

import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.jdbc.core.JdbcTemplate;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HexFormat;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;

class MigratedProjectionOriginalTablesTest {
    @Test void originalFractionalMigrationTableBytesKeepTheirConstraints() throws Exception {
        var target = mock(JdbcTemplate.class);
        MigratedProjectionSchema.createOriginalTables(target,
                "V999_11__financial_application_original_six_workflows.sql", "finance_applications");
        var statement = ArgumentCaptor.forClass(String.class);
        verify(target).execute(statement.capture());
        String digest = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                .digest(statement.getValue().getBytes(StandardCharsets.UTF_8)));
        assertThat(digest).isEqualTo("aaacf2b9fa8bb3375daadf7adc4c4f3609d3080dad563395a231dfe62c2c5e74");
    }

    @Test void aMissingOriginalTableCannotFallBackToAnInventedProjection() {
        var target = mock(JdbcTemplate.class);
        assertThatThrownBy(() -> MigratedProjectionSchema.createOriginalTables(target,
                "V999_1__finance_chart_code_imports.sql", "missing_original"))
                .isInstanceOf(IllegalArgumentException.class).hasMessageContaining("Original table missing");
        verifyNoInteractions(target);
    }

    @Test void onlyExplicitMigrationResourcesAndSimpleTableIdentifiersAreAllowed() {
        var target = mock(JdbcTemplate.class);
        assertThatThrownBy(() -> MigratedProjectionSchema.createOriginalTables(target,
                "../unreviewed.sql", "finance_applications"))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> MigratedProjectionSchema.createOriginalTables(target,
                "V999_1__finance_chart_code_imports.sql", "finance_chart_codes; DROP TABLE users"))
                .isInstanceOf(IllegalArgumentException.class);
        verifyNoInteractions(target);
    }
}
