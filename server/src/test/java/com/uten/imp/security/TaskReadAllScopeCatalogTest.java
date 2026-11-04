package com.uten.imp.security;

import com.uten.imp.features.rbac.GrantPolicy;
import com.uten.imp.features.rbac.PermissionBusinessDescriptions;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class TaskReadAllScopeCatalogTest {
    private static final List<String> CODES=List.of(
            "warehouse_task:view:all","production_workshop_task:view:all","supplier_return_task:view:all");

    @Test void rangeCodesAreOptInReadsWithExplicitDepartmentButNoBulkOrDelegationGrant() {
        var db=PermissionCatalogTestSupport.database();
        // 551 = 525 + 财务复原批次新增权限点(V999_11 finance_application:* 6 项、
        // V1000 报销四级审批 4 项、V1001 业务申请工作流 15 项、V1002 审批代班配置 1 项)。
        assertThat(PermissionCatalogTestSupport.catalogCodes()).hasSize(551).containsAll(CODES);
        for(String code:CODES) {
            var row=db.queryForMap("SELECT action_type,grant_policy::text,baseline,baseline_pinned,explicit_grant_required FROM permissions WHERE code=?",code);
            assertThat(row.get("action_type")).isEqualTo("VIEW");
            assertThat(row.get("grant_policy")).isEqualTo("{BULK_EXCLUDED,NON_DELEGABLE}");
            assertThat(row.get("baseline")).isEqualTo(false);
            assertThat(row.get("baseline_pinned")).isEqualTo(false);
            assertThat(row.get("explicit_grant_required")).isEqualTo(true);
            var policy=GrantPolicy.parse(new String[]{"BULK_EXCLUDED","NON_DELEGABLE"});
            assertThat(GrantPolicy.departmentGrantable(policy)).isTrue();
            assertThat(GrantPolicy.individuallyGrantable(policy)).isTrue();
            assertThat(GrantPolicy.bulkEligible(policy)).isFalse();
            assertThat(GrantPolicy.baselineEligible(policy)).isFalse();
            assertThat(GrantPolicy.delegable(policy)).isFalse();
            assertThat(db.queryForObject("SELECT count(*) FROM department_permissions mapping JOIN permissions p ON p.id=mapping.permission_id WHERE p.code=?",Integer.class,code)).isZero();
            assertThat(db.queryForObject("SELECT count(*) FROM user_permission_overrides mapping JOIN permissions p ON p.id=mapping.permission_id WHERE p.code=?",Integer.class,code)).isZero();
            assertThat(PermissionBusinessDescriptions.catalog().get(code).description())
                    .contains("对应业务查看权限","不改变","提醒和待办：","例如：");
        }
        UUID department=db.queryForObject("SELECT id FROM departments WHERE NOT is_deleted ORDER BY id LIMIT 1",UUID.class);
        assertThatThrownBy(()->db.update("INSERT INTO department_permissions(department_id,permission_id) SELECT ?,id FROM permissions WHERE code=?",department,CODES.getFirst()))
                .hasMessageContaining("cannot be automatically granted");
        new TransactionTemplate(new DataSourceTransactionManager(db.getDataSource())).executeWithoutResult(status->{
            UUID actor=UUID.randomUUID(),employee=UUID.randomUUID();
            db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,'范围授权测试人员','其他',?,current_date,'active','regular')",
                    employee,"TASK-RANGE-"+employee,department);
            db.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,is_super_admin,status) VALUES(?,?,?,'test-only-not-a-login-hash',false,true,'active')",
                    actor,employee,"task-range-"+actor);
            db.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,actor.toString());
            for(String code:CODES) {
                assertThat(db.update("INSERT INTO department_permissions(department_id,permission_id) SELECT ?,id FROM permissions WHERE code=?",department,code)).isOne();
            }
            assertThat(db.queryForObject("SELECT count(*) FROM department_permissions mapping JOIN permissions p ON p.id=mapping.permission_id WHERE mapping.department_id=? AND p.code IN (?,?,?)",Integer.class,department,CODES.get(0),CODES.get(1),CODES.get(2))).isEqualTo(3);
            status.setRollbackOnly();
        });
    }
}
