package com.uten.imp.migration;

import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.org.department.DepartmentRepository;
import com.uten.imp.features.org.department.staffpermission.PagePermissionDelegationFeatureGate;
import com.uten.imp.features.org.department.staffpermission.PermissionSurfaceCatalogRepository;
import com.uten.imp.features.org.department.staffpermission.PermissionSurfaceRegistry;
import com.uten.imp.features.org.employee.EmployeeRepository;
import com.uten.imp.features.org.employee.EmployeeSecondaryDepartmentRepository;
import com.uten.imp.features.rbac.*;
import com.uten.imp.security.PermissionDelegationPolicy;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** A nonempty upgrade must preserve actual effective permissions, explicit denials and stale history. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
class PermissionCatalogPlainNamesPostgresTest {
    private static final String CONFIRM="sales_quote_finance:confirm";
    private static final List<String> SPLIT=List.of("sales_quote_finance:reject","sales_quote_finance:reverse");
    private static final String ASSET_POST="finance_asset:post";
    private static final String ASSET_REVERSE="finance_asset:reverse";

    @Test
    void namesAndSplitPreserveEffectiveAuthorizationAndDoNotReviveStaleDelegations() {
        try(var database=new PostgreSQLContainer("postgres:16-alpine")) {
            database.start();
            var source=new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword());
            com.uten.imp.testsupport.TestFlyway.configure().dataSource(source).target("895").load().migrate();
            var db=new JdbcTemplate(source);
            UUID department=db.queryForObject("SELECT id FROM departments WHERE code='DEPT_FIN'",UUID.class);
            UUID otherDepartment=db.queryForObject("SELECT id FROM departments WHERE code='DEPT_SALES'",UUID.class);
            UUID manager=account(db,department,true);
            UUID delegated=account(db,department,false);
            UUID staleEpoch=account(db,department,false);
            UUID staleVersion=account(db,department,false);
            UUID staleGeneration=account(db,department,false);
            UUID disabled=account(db,department,false);
            UUID personal=account(db,department,false);
            UUID denied=account(db,department,false);
            UUID tombstone=account(db,department,false);
            db.update("DELETE FROM department_permissions WHERE permission_id IN (SELECT id FROM permissions WHERE code IN (?, 'goods:view'))",CONFIRM);
            db.update("UPDATE permissions SET baseline=false WHERE code IN (?, 'goods:view')",CONFIRM);
            decision(db,manager,"goods:view","grant",true);
            decision(db,manager,CONFIRM,"grant",true);
            decision(db,delegated,CONFIRM,"grant",false);
            decision(db,personal,CONFIRM,"grant",true);
            decision(db,denied,CONFIRM,"revoke",true);
            decision(db,tombstone,CONFIRM,"grant",false);
            decision(db,personal,ASSET_POST,"grant",true);
            decision(db,denied,ASSET_POST,"revoke",true);
            decision(db,tombstone,ASSET_POST,"grant",false);
            db.update("INSERT INTO department_permissions(department_id,permission_id) SELECT ?,id FROM permissions WHERE code=?",otherDepartment,CONFIRM);
            // All sources are captured after fixture authority writes, as in a running installation.
            delegation(db,delegated,manager,CONFIRM,true,0,0);
            delegation(db,delegated,manager,"goods:view",true,0,0);
            delegation(db,staleEpoch,manager,CONFIRM,true,-1,0);
            delegation(db,staleVersion,manager,CONFIRM,true,0,-1);
            delegation(db,staleGeneration,manager,CONFIRM,true,0,0);
            db.update("UPDATE manager_permission_delegations SET grantor_user_generation=grantor_user_generation-1 WHERE user_id=?",staleGeneration);
            delegation(db,disabled,manager,CONFIRM,false,0,0);
            delegation(db,denied,manager,CONFIRM,true,0,0);
            UUID template=UUID.randomUUID();
            UUID deletedTemplate=UUID.randomUUID();
            UUID assetTemplate=UUID.randomUUID();
            for(UUID id:List.of(template,deletedTemplate)) {
                db.update("""
                    INSERT INTO permission_templates(id,name,permission_codes,created_by,updated_by,is_deleted)
                    VALUES(?,?,?::jsonb,?,?,?)
                    """,id,"quote-"+id,"[\"sales_quote_finance:confirm\",\"goods:view\"]",manager,manager,id.equals(deletedTemplate));
            }
            db.update("""
                INSERT INTO permission_templates(id,name,permission_codes,created_by,updated_by)
                VALUES(?,?,?::jsonb,?,?)
                """,assetTemplate,"asset-"+assetTemplate,"[\"finance_asset:post\",\"goods:view\"]",manager,manager);
            var users=List.of(delegated,staleEpoch,staleVersion,staleGeneration,disabled,personal,denied,tombstone);
            var beforeCodes=new LinkedHashSet<>(db.queryForList("SELECT code FROM permissions",String.class));
            var before=resolver(db).grantedPermissionsFor(users,beforeCodes);
            assertThat(before.get(delegated)).contains(CONFIRM,"goods:view");
            assertThat(before.get(personal)).contains(CONFIRM);
            for(UUID id:List.of(staleEpoch,staleVersion,staleGeneration,disabled,denied,tombstone))
                assertThat(before.get(id)).doesNotContain(CONFIRM);
            String originalId=db.queryForObject("SELECT id::text FROM permissions WHERE code='stock_doc:reverse'",String.class);
            String originalAuthority=authorityMetadata(db);
            long epoch=epoch(db);
            var result=com.uten.imp.testsupport.TestFlyway.configure().dataSource(source).load().migrate();
            assertThat(result.migrationsExecuted).isEqualTo(2);
            assertThat(epoch(db)).isGreaterThan(epoch);
            var afterCodes=new LinkedHashSet<>(db.queryForList("SELECT code FROM permissions",String.class));
            assertThat(afterCodes).containsExactlyInAnyOrderElementsOf(union(beforeCodes,union(Set.copyOf(SPLIT),Set.of(ASSET_REVERSE))));
            var after=resolver(db).grantedPermissionsFor(users,afterCodes);
            for(UUID id:users) {
                var expected=new LinkedHashSet<>(before.get(id));
                if(expected.contains(CONFIRM)) expected.addAll(SPLIT);
                if(expected.contains(ASSET_POST)) expected.add(ASSET_REVERSE);
                assertThat(after.get(id)).as("effective authority for %s",id).containsExactlyInAnyOrderElementsOf(expected);
            }
            assertThat(db.queryForObject("SELECT id::text FROM permissions WHERE code='stock_doc:reverse'",String.class)).isEqualTo(originalId);
            assertThat(authorityMetadata(db)).isEqualTo(originalAuthority);
            assertThat(db.queryForList("SELECT name FROM permissions WHERE name LIKE '%红冲%'",String.class)).isEmpty();
            assertThat(db.queryForList("SELECT code FROM permissions WHERE name IS NULL OR length(btrim(name))=0 OR description IS NULL OR length(btrim(description))=0",String.class)).isEmpty();
            for(String code:SPLIT) {
                assertThat(db.queryForObject("SELECT count(*) FROM department_permissions d JOIN permissions p ON p.id=d.permission_id WHERE d.department_id=? AND p.code=?",Long.class,otherDepartment,code)).isEqualTo(1);
                assertThat(db.queryForObject("SELECT effect||':'||active FROM user_permission_overrides o JOIN permissions p ON p.id=o.permission_id WHERE o.user_id=? AND p.code=?",String.class,denied,code)).isEqualTo("revoke:true");
                assertThat(db.queryForObject("SELECT effect||':'||active FROM user_permission_overrides o JOIN permissions p ON p.id=o.permission_id WHERE o.user_id=? AND p.code=?",String.class,tombstone,code)).isEqualTo("grant:false");
                assertThat(db.queryForObject("SELECT count(*) FROM permission_surface_permissions m JOIN permissions p ON p.id=m.permission_id WHERE p.code=?",Long.class,code)).isGreaterThan(0);
            }
            assertThat(db.queryForObject("SELECT permission_codes::text FROM permission_templates WHERE id=?",String.class,template)).contains(SPLIT);
            assertThat(db.queryForObject("SELECT permission_codes::text FROM permission_templates WHERE id=?",String.class,template)).doesNotContain(ASSET_REVERSE);
            assertThat(db.queryForObject("SELECT permission_codes::text FROM permission_templates WHERE id=?",String.class,assetTemplate)).contains(ASSET_REVERSE).doesNotContain(SPLIT);
            assertThat(db.queryForObject("SELECT row_version FROM permission_templates WHERE id=?",Long.class,assetTemplate)).isEqualTo(1);
            assertThat(db.queryForObject("SELECT grant_policy::text||':'||high_risk FROM permissions WHERE code=?",String.class,ASSET_REVERSE)).isEqualTo("{INDIVIDUAL_ONLY}:true");
            assertThat(db.queryForObject("SELECT effect||':'||active FROM user_permission_overrides o JOIN permissions p ON p.id=o.permission_id WHERE o.user_id=? AND p.code=?",String.class,denied,ASSET_REVERSE)).isEqualTo("revoke:true");
            assertThat(db.queryForObject("SELECT effect||':'||active FROM user_permission_overrides o JOIN permissions p ON p.id=o.permission_id WHERE o.user_id=? AND p.code=?",String.class,tombstone,ASSET_REVERSE)).isEqualTo("grant:false");
            assertThat(db.queryForObject("SELECT row_version FROM permission_templates WHERE id=?",Long.class,template)).isEqualTo(1);
            assertThat(db.queryForObject("SELECT row_version FROM permission_templates WHERE id=?",Long.class,deletedTemplate)).isZero();
            assertThat(db.queryForObject("SELECT count(*) FROM pg_trigger WHERE tgname='trg_manager_permission_delegations_auth_version' AND tgenabled='O'",Long.class)).isEqualTo(1);
            // Later copy edits are harmless; changing actual authority still expires delegated snapshots.
            long afterEpoch=epoch(db);
            db.update("UPDATE permissions SET name=name||'测试',description=description||'测试' WHERE code='goods:view'");
            assertThat(epoch(db)).isEqualTo(afterEpoch);
            assertThat(resolver(db).grantedPermissionsFor(List.of(delegated),afterCodes).get(delegated)).contains("goods:view");
            db.update("UPDATE permissions SET high_risk=NOT high_risk WHERE code='goods:view'");
            assertThat(epoch(db)).isGreaterThan(afterEpoch);
            assertThat(resolver(db).grantedPermissionsFor(List.of(delegated),afterCodes).get(delegated)).doesNotContain("goods:view");
        }
    }

    private static Set<String> union(Set<String> first,Set<String> second) {
        var result=new LinkedHashSet<>(first);result.addAll(second);return result;
    }
    private static UUID account(JdbcTemplate db,UUID department,boolean admin) {
        UUID id=UUID.randomUUID();
        db.update("""
            INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
            VALUES(?,?,?,'其他',?,current_date,'active','regular')
            """,id,"P896-"+id,"权限升级验证",department);
        db.update("""
            INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status,is_super_admin)
            VALUES(?,?,?,'fixture-only',false,'active',?)
            """,id,id,"p896-"+id,admin);return id;
    }
    private static void decision(JdbcTemplate db,UUID user,String code,String effect,boolean active) {
        db.update("""
            INSERT INTO user_permission_overrides(user_id,permission_id,effect,authority_source,active,row_version)
            SELECT ?,id,?,'SUPER_ADMIN_CONFIRMED',?,4 FROM permissions WHERE code=?
            """,user,effect,active,code);
    }
    private static void delegation(JdbcTemplate db,UUID user,UUID manager,String code,boolean enabled,int epochOffset,int versionOffset) {
        db.update("""
            INSERT INTO manager_permission_delegations(user_id,permission_id,department_id,enabled,surface_key,granted_by_user_id,
                target_user_generation,target_employee_generation,target_department_generation,grantor_user_generation,
                grantor_employee_generation,grantor_auth_version,grantor_authorization_epoch,scope_source)
            SELECT target.id,p.id,d.id,?,surface.surface_key,grantor.id,target.permission_delegation_generation,
                employee.permission_delegation_generation,d.permission_delegation_generation,grantor.permission_delegation_generation,
                NULL,grantor.auth_version+?,state.epoch+?,'SUPER_ADMIN'
            FROM users target JOIN employees employee ON employee.id=target.employee_id
            JOIN departments d ON d.id=employee.department_id CROSS JOIN users grantor CROSS JOIN permissions p
            CROSS JOIN authorization_state state JOIN permission_surface_permissions link ON link.permission_id=p.id
            JOIN permission_surfaces surface ON surface.id=link.surface_id
            WHERE target.id=? AND grantor.id=? AND p.code=? AND state.singleton_id=1
              AND surface.surface_key=CASE WHEN p.code='goods:view' THEN 'basic.goods' ELSE 'finance.sales-quote-review' END
            """,enabled,versionOffset,epochOffset,user,manager,code);
        assertThat(db.queryForObject("SELECT count(*) FROM manager_permission_delegations m JOIN permissions p ON p.id=m.permission_id WHERE m.user_id=? AND p.code=?",Long.class,user,code)).isEqualTo(1);
    }
    private static long epoch(JdbcTemplate db) { return db.queryForObject("SELECT epoch FROM authorization_state WHERE singleton_id=1",Long.class); }
    private static String authorityMetadata(JdbcTemplate db) {
        return db.queryForObject("""
            SELECT jsonb_agg(to_jsonb(p)-ARRAY['name','description','module','category','sort_order','updated_at','updated_by'] ORDER BY code)::text
            FROM permissions p WHERE code NOT IN ('sales_quote_finance:reject','sales_quote_finance:reverse','finance_asset:reverse')
            """,String.class);
    }
    private static PermissionResolver resolver(JdbcTemplate jdbc) {
        var catalog=mock(PermissionRepository.class);
        when(catalog.findAll()).thenReturn(jdbc.query("SELECT code,action_type FROM permissions",(rs,index)->{
            var p=new Permission();p.setCode(rs.getString("code"));p.setActionType(rs.getString("action_type"));return p;
        }));
        var resolver=new PermissionResolver(catalog,mock(DepartmentPermissionRepository.class),mock(UserPermissionOverrideRepository.class),
            mock(EmployeeRepository.class),mock(EmployeeSecondaryDepartmentRepository.class),mock(UserAccountRepository.class),
            mock(DepartmentRepository.class),mock(ManagerPermissionDelegationRepository.class),
            new PermissionDelegationPolicy(new PermissionGrantPolicyCatalog(jdbc)),
            new PermissionSurfaceRegistry(new PermissionSurfaceCatalogRepository(jdbc)),new PagePermissionDelegationFeatureGate(true),jdbc);
        resolver.initializeDependencyCatalog();return resolver;
    }
}
