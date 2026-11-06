package com.uten.imp.security;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.core.io.ClassPathResource;
import java.nio.charset.StandardCharsets;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class BusinessApplicationPermissionContractTest {
    private static final List<String> FINANCIAL_ACTIONS=List.of(
        "application:receive","finance_application:review","finance_application:execute",
        "finance_application:confirm","finance_application:reverse");
    @Test void applicationCapabilitiesDefaultClosedAndArePresentOnTheirOwningSurfaces(){
        var db=PermissionCatalogTestSupport.database();
        assertThat(db.queryForObject("SELECT count(*) FROM permissions WHERE code LIKE 'application:%'",Integer.class)).isEqualTo(15);
        assertThat(db.queryForObject("SELECT count(*) FROM permissions WHERE code LIKE 'application:%' AND (baseline OR NOT explicit_grant_required)",Integer.class)).isZero();
        for(String grants:List.of("department_permissions","user_permission_overrides","manager_permission_delegations"))assertThat(db.queryForObject("SELECT count(*) FROM "+grants+" g JOIN permissions p ON p.id=g.permission_id WHERE p.code LIKE 'application:%'",Integer.class)).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM permission_surface_permissions m JOIN permission_surfaces s ON s.id=m.surface_id JOIN permissions p ON p.id=m.permission_id WHERE s.surface_key='common.applications' AND p.code LIKE 'application:apply%'",Integer.class)).isEqualTo(5);
        assertThat(db.queryForObject("SELECT count(*) FROM permission_surface_permissions m JOIN permission_surfaces s ON s.id=m.surface_id JOIN permissions p ON p.id=m.permission_id WHERE s.surface_key='applications.approval' AND p.code LIKE 'application:%'",Integer.class)).isEqualTo(10);
        assertThat(db.queryForObject("SELECT count(*) FROM permissions WHERE code LIKE 'application:%payroll%'",Integer.class)).isZero();
        assertThat(db.queryForList("SELECT code FROM permissions WHERE code IN (?,?,?,?,?) AND high_risk",String.class,FINANCIAL_ACTIONS.toArray()))
            .containsExactlyInAnyOrderElementsOf(FINANCIAL_ACTIONS);
    }
    @Test void financialHighRiskMigrationOnlyUpdatesExistingCatalogMetadata() throws Exception {
        var source=new ClassPathResource("db/migration/V1064__financial_application_high_risk_permissions.sql")
            .getContentAsString(StandardCharsets.UTF_8);
        var statement=source.replaceAll("(?m)--[^\\r\\n]*","").replaceAll("\\s+"," ").trim();
        var expected="UPDATE permissions SET high_risk=TRUE WHERE code IN ('"
            +String.join("','",FINANCIAL_ACTIONS)+"') AND NOT high_risk;";
        assertThat(statement.replaceAll("\\s*,\\s*",","))
            .as("the original forward migration changes only the five existing high-risk flags; it cannot grant access")
            .isEqualTo(expected);
    }
}
