package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class MaterialAnalysisParticipatingWarehousesMigrationContractTest {

    private static String migration() throws Exception {
        Path direct = Path.of("src", "main", "resources", "db", "migration",
                "V471__material_analysis_participating_warehouses.sql");
        Path fallback = Path.of("server").resolve(direct);
        return Files.readString(Files.exists(direct) ? direct : fallback,
                StandardCharsets.UTF_8);
    }

    @Test
    void backfillsPrimaryAndKeepsParticipantSetReferenceOnly() throws Exception {
        String sql = migration();
        assertThat(sql)
                .contains("ADD COLUMN participating_warehouse_ids UUID[]")
                .contains("ARRAY[warehouse_id]::UUID[]")
                .contains("warehouse_id = ANY(participating_warehouse_ids)")
                .contains("fn_uuid_array_is_unique")
                .contains("trg_validate_material_analysis_warehouses")
                .contains("only warehouse_id can drive readiness, reservations or DRAW");
    }
}

