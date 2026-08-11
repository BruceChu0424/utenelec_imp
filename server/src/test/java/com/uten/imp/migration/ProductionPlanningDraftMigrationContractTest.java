package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionPlanningDraftMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V191__production_planning_drafts.sql");

    @Test
    void draftLedgerIsVersionedAuditedAndHasOneActiveRowPerPlan()
            throws Exception {
        String sql = compact(Files.readString(MIGRATION,
                StandardCharsets.UTF_8));

        assertThat(sql)
                .contains("create table production_planning_drafts")
                .contains("payload_version smallint not null default 1")
                .contains("check (payload_version = 1)")
                .contains("planned_by uuid not null references users(id) on delete restrict")
                .contains("resolved_by uuid references users(id) on delete restrict")
                .contains("create unique index uq_production_planning_draft_active_plan on production_planning_drafts(plan_id) where status = 'active'")
                .contains("before update or delete on production_planning_drafts")
                .contains("after insert or update or delete on production_planning_drafts for each row execute function fn_audit()")
                .contains("old.status <> 'active'")
                .contains("new.status not in ('applied', 'superseded')");
    }

    @Test
    void migrationDoesNotBackfillOrRewriteHistoricalPlans() throws Exception {
        String sql = compact(Files.readString(MIGRATION,
                StandardCharsets.UTF_8));

        assertThat(sql)
                .doesNotContain("insert into production_planning_drafts")
                .doesNotContain("update production_plans")
                .doesNotContain("update production_plan_items");
    }

    private static String compact(String value) {
        return value.toLowerCase().replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ").trim();
    }
}
