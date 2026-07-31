package com.uten.imp.architecture;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

class BusinessChainScenarioMatrixTest {

    private static final Path MATRIX =
            Path.of("src/test/resources/business-chain-scenario-matrix.md");

    @Test
    void matrixKeepsEveryRequiredEndToEndScenarioUnique() throws IOException {
        String matrix = Files.readString(MATRIX);

        for (int number = 1; number <= 32; number++) {
            String id = "SC-%02d".formatted(number);
            assertEquals(1, occurrences(matrix, "| " + id + " |"),
                    id + " must appear exactly once as a scenario row");
        }
    }

    @Test
    void matrixCoversAuthoritiesLocksReversalsPermissionsAndReleaseGates()
            throws IOException {
        String matrix = Files.readString(MATRIX);

        for (String required : List.of(
                "stock_reservations",
                "production_material_demands",
                "production_material_supply_pegs",
                "business_outbox",
                "PESSIMISTIC_WRITE",
                "advisory lock",
                "before/delta/after",
                "幂等",
                "红冲",
                "对象范围",
                "历史迁移",
                "余料退库",
                "采购请求卡片",
                "委外发料卡片",
                "仓库生产领料卡片",
                "[GREEN]",
                "[PARTIAL]",
                "[RED]",
                "[BLOCKED]",
                "[MANUAL]",
                "PLANNING_WRITE_READY",
                "UTEN_RUN_DB_TESTS")) {
            assertTrue(matrix.contains(required),
                    () -> "business-chain matrix is missing required contract: " + required);
        }
    }

    private static int occurrences(String source, String needle) {
        int count = 0;
        int offset = 0;
        while ((offset = source.indexOf(needle, offset)) >= 0) {
            count++;
            offset += needle.length();
        }
        return count;
    }
}
