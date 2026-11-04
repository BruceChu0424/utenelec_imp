package com.uten.imp.security;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class BusinessApplicationPermissionContractTest {
    @Test void applicationCapabilitiesDefaultClosedAndArePresentOnTheirOwningSurfaces(){
        var db=PermissionCatalogTestSupport.database();
        assertThat(db.queryForObject("SELECT count(*) FROM permissions WHERE code LIKE 'application:%'",Integer.class)).isEqualTo(15);
        assertThat(db.queryForObject("SELECT count(*) FROM permissions WHERE code LIKE 'application:%' AND (baseline OR NOT explicit_grant_required)",Integer.class)).isZero();
        for(String grants:List.of("department_permissions","user_permission_overrides","manager_permission_delegations"))assertThat(db.queryForObject("SELECT count(*) FROM "+grants+" g JOIN permissions p ON p.id=g.permission_id WHERE p.code LIKE 'application:%'",Integer.class)).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM permission_surface_permissions m JOIN permission_surfaces s ON s.id=m.surface_id JOIN permissions p ON p.id=m.permission_id WHERE s.surface_key='common.applications' AND p.code LIKE 'application:apply%'",Integer.class)).isEqualTo(5);
        assertThat(db.queryForObject("SELECT count(*) FROM permission_surface_permissions m JOIN permission_surfaces s ON s.id=m.surface_id JOIN permissions p ON p.id=m.permission_id WHERE s.surface_key='applications.approval' AND p.code LIKE 'application:%'",Integer.class)).isEqualTo(10);
        assertThat(db.queryForObject("SELECT count(*) FROM permissions WHERE code LIKE 'application:%payroll%'",Integer.class)).isZero();
    }
}
