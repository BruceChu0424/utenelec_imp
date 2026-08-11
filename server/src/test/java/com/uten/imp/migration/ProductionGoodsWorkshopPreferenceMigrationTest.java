package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionGoodsWorkshopPreferenceMigrationTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V192__production_goods_workshop_preferences.sql");

    @Test
    void preferenceTableHasIdentityReferencesCountersAndTimestamps()
            throws Exception {
        String sql = compact(Files.readString(MIGRATION, StandardCharsets.UTF_8));

        assertThat(sql)
                .contains("create table production_goods_workshop_preferences")
                .contains("goods_id uuid not null references goods(id) on delete restrict")
                .contains("workshop_department_id uuid not null references departments(id) on delete restrict")
                .contains("last_selected_by uuid not null references employees(id) on delete restrict")
                .contains("selection_count bigint not null default 1")
                .contains("check (selection_count > 0)")
                .contains("last_selected_at timestamptz not null default now()")
                .contains("created_at timestamptz not null default now()")
                .contains("updated_at timestamptz not null default now()")
                .contains("unique (goods_id)");
    }

    @Test
    void preferenceTableMaintainsUpdatedAtAndFullRowAudit() throws Exception {
        String sql = compact(Files.readString(MIGRATION, StandardCharsets.UTF_8));

        assertThat(sql)
                .contains("before update on production_goods_workshop_preferences for each row execute function fn_set_updated_at()")
                .contains("after insert or update or delete on production_goods_workshop_preferences for each row execute function fn_audit()");
    }

    @Test
    void migrationDoesNotBackfillHistoricalProductionData() throws Exception {
        String sql = compact(Files.readString(MIGRATION, StandardCharsets.UTF_8));

        assertThat(sql)
                .doesNotContain("insert into production_goods_workshop_preferences")
                .doesNotContain("update production_plans")
                .doesNotContain("update production_plan_items")
                .doesNotContain("update production_execution_segments");
    }

    private static String compact(String value) {
        return value.toLowerCase().replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ").trim();
    }
}
