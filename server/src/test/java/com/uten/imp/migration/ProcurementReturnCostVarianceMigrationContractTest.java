package com.uten.imp.migration;

import org.junit.jupiter.api.Test;
import java.nio.file.Files;
import java.nio.file.Path;
import static org.assertj.core.api.Assertions.*;

class ProcurementReturnCostVarianceMigrationContractTest {
    @Test void stableRoleIsForwardOnlyAndInheritsAuditedPreservedConfigurationWithoutRewritingMoney() throws Exception {
        String sql;
        try(var input=getClass().getResourceAsStream("/db/migration/V845__procurement_return_actual_cost_variance_role.sql")){
            assertThat(input).isNotNull();sql=new String(input.readAllBytes(),java.nio.charset.StandardCharsets.UTF_8);
        }
        assertThat(sql).contains("INSERT INTO system_posting_style_roles","'PROCUREMENT_RETURN_VARIANCE','EXPENSE'");
        assertThat(sql.toUpperCase()).doesNotContain("UPDATE ","DELETE ","TRUNCATE ","ALTER TABLE", "CREATE TABLE");
        String reset=Files.readString(Path.of("src/main/resources/db/migration/V462__system_test_business_data_reset.sql"));
        assertThat(reset).contains("('system_posting_style_roles', 'PRESERVE')");
        String audit=Files.readString(Path.of("src/main/resources/db/migration/V278__system_posting_style_uuid_roles.sql"));
        assertThat(audit).contains("AFTER INSERT OR UPDATE OR DELETE ON system_posting_style_roles");
    }
}
