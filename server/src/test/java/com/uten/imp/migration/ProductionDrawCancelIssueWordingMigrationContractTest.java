package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionDrawCancelIssueWordingMigrationContractTest {

    @Test
    void forwardMigrationRenamesOnlyTheExistingCancellationPermission() throws Exception {
        String sql = Files.readString(Path.of(
                "src/main/resources/db/migration/"
                        + "V473__production_draw_cancel_issue_wording.sql"),
                StandardCharsets.UTF_8).toLowerCase();

        assertThat(sql)
                .contains("update permissions")
                .contains("where code = 'stock_doc:reverse_issue'")
                .contains("取消生产领料出库")
                .contains("保留原出库和取消流水")
                .doesNotContain("delete from permissions")
                .doesNotContain("insert into department_permissions")
                .doesNotContain("insert into user_permission_overrides");
    }
}
