package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionFqcReleaseFunctionRepairContractTest {

    @Test
    void repairUsesPrefixedVariablesAndQualifiedColumns()
            throws Exception {
        String sql = Files.readString(Path.of(
                "src/main/resources/db/migration/"
                        + "V413__fix_production_fqc_release_total_variable_ambiguity.sql"));

        assertThat(sql)
                .contains("v_decision_pass_qty")
                .contains("decision.pass_qty")
                .contains("command.id = v_command_id")
                .contains("allocation.decision_event_id = v_decision_id")
                .doesNotContain("INTO pass_qty")
                .doesNotContain("WHERE id = decision_id");
    }
}
