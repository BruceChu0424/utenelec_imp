package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;

import static org.assertj.core.api.Assertions.assertThat;

class NoticePopupAcknowledgementMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V406__notice_popup_acknowledgement.sql");

    @Test
    void v406AddsRecipientScopedPopupAcknowledgementWithoutRewritingReadState()
            throws IOException {
        String sql = compact(Files.readString(MIGRATION));

        assertThat(sql)
                .contains("alter table notice_user_states")
                .contains("add column if not exists popup_acknowledged_at timestamptz")
                .contains("idx_notice_user_states_popup_pending")
                .contains("where read_at is null")
                .contains("and popup_acknowledged_at is null")
                .contains("and deleted_at is null")
                .doesNotContain("update notice_user_states")
                .doesNotContain("alter column read_at");
    }

    private static String compact(String value) {
        return value.toLowerCase(Locale.ROOT).replaceAll("\\s+", " ").trim();
    }
}
