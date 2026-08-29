package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertTrue;

class ProductionPlanDrawActiveUniquenessMigrationContractTest {

    @Test
    void migrationFailsClosedAndAddsBothActiveUniqueIndexes()
            throws Exception {
        String sql = Files.readString(Path.of(
                "src/main/resources/db/migration/"
                        + "V411__production_plan_draw_active_uniqueness.sql"));

        assertTrue(sql.contains(
                "GROUP BY plan_id, draw_id"));
        assertTrue(sql.contains(
                "GROUP BY draw_id"));
        assertTrue(sql.contains(
                "CREATE UNIQUE INDEX IF NOT EXISTS "
                        + "uq_pdl_active_plan_draw"));
        assertTrue(sql.contains(
                "CREATE UNIQUE INDEX IF NOT EXISTS "
                        + "uq_pdl_active_draw"));
        assertTrue(sql.contains(
                "WHERE is_deleted = FALSE"));
        assertTrue(sql.contains(
                "RAISE EXCEPTION"));
    }
}
