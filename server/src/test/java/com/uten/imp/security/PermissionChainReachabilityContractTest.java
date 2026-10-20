package com.uten.imp.security;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;

import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * permissions-01：业务链路上每一步动作至少有一个岗位能办。
 *
 * <p>被非 GET 端点引用、动作类别属执行 / 审批 / 创建的码，必须至少有一个部门持有、或属全员基础包、
 * 或显式标为 SUPERADMIN_ONLY / INDIVIDUAL_ONLY(超管专属或只能逐人点名授予的高风险码)。
 * 明确要求由设置按需授权的新可选动作例外，逐项校验可配置目录与零默认授权，不能据此推导部门授权。
 * 否则就会出现「退回供应商任务 / IQC 不合格闭环 / 官网询盘只有超管能办、到货异常一直关不了」。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class PermissionChainReachabilityContractTest {

    private static final Set<String> CHAIN_ACTION_TYPES = Set.of("EXECUTE", "APPROVE", "CREATE");
    // V886 deliberately adds no department/user grant. Reusing the retired plan action would
    // hide the feature; assigning a department merely to satisfy this test would invent authority.
    private static final Map<String, String> EXPLICIT_CONFIGURATION_ACTIONS = Map.of(
            "production_material_analysis:forward_rd", "production.material-analysis");

    @Test
    void everyWriteEndpointActionCodeHasAHolder() throws Exception {
        JdbcTemplate db = PermissionCatalogTestSupport.database();
        Set<String> writeCodes = new LinkedHashSet<>();
        PermissionCatalogTestSupport.guards().stream()
                .filter(PermissionCatalogTestSupport.Guard::write)
                .forEach(guard -> writeCodes.addAll(guard.codes()));

        Map<String, String> unreachable = new TreeMap<>();
        Set<String> explicitConfigurationSeen = new LinkedHashSet<>();
        for (Map<String, Object> row : db.queryForList("""
                SELECT permission.code,
                       permission.action_type,
                       permission.baseline,
                       permission.grant_policy = ARRAY['NORMAL']::text[] AS configurable,
                       permission.grant_policy && ARRAY['SUPERADMIN_ONLY','INDIVIDUAL_ONLY']::text[] AS named_only,
                       EXISTS (SELECT 1 FROM department_permissions grant_row
                               WHERE grant_row.permission_id = permission.id) AS department_held
                FROM permissions permission
                """)) {
            String code = (String) row.get("code");
            if (!writeCodes.contains(code) || !CHAIN_ACTION_TYPES.contains((String) row.get("action_type"))) {
                continue;
            }
            boolean reachable = Boolean.TRUE.equals(row.get("baseline"))
                    || Boolean.TRUE.equals(row.get("named_only"))
                    || Boolean.TRUE.equals(row.get("department_held"));
            if (EXPLICIT_CONFIGURATION_ACTIONS.containsKey(code)) {
                explicitConfigurationSeen.add(code);
                assertThat(reachable).as(code + " must not acquire default authority").isFalse();
                assertThat(row.get("configurable")).as(code + " remains configurable in settings").isEqualTo(true);
                assertThat(db.queryForList("""
                        SELECT surface.surface_key FROM permission_surface_permissions link
                        JOIN permissions p ON p.id=link.permission_id
                        JOIN permission_surfaces surface ON surface.id=link.surface_id
                        WHERE p.code=? AND surface.enabled
                        """, String.class, code)).containsExactly(EXPLICIT_CONFIGURATION_ACTIONS.get(code));
                continue;
            }
            if (!reachable) {
                unreachable.put(code, (String) row.get("action_type"));
            }
        }
        assertThat(unreachable)
                .as("写端点上的执行/审批/创建码没有任何部门持有，也没标超管专属或个人专属")
                .isEmpty();
        assertThat(explicitConfigurationSeen).containsExactlyInAnyOrderElementsOf(EXPLICIT_CONFIGURATION_ACTIONS.keySet());
    }

    @Test
    void threeStuckChainsHaveTheirDefaultPosts() {
        JdbcTemplate db = PermissionCatalogTestSupport.database();
        List<String[]> expected = List.of(
                new String[]{"SUB_PURCHASE", "supplier_return_task:view"},
                new String[]{"SUB_PURCHASE", "supplier_return_task:complete"},
                new String[]{"DEPT_SALES", "supplier_return_task:view"},
                new String[]{"DEPT_SALES", "supplier_return_task:complete"},
                new String[]{"SUB_WH", "procurement_iqc_rejection:record_return"},
                new String[]{"DEPT_FIN", "procurement_iqc_rejection:view"},
                new String[]{"DEPT_FIN", "procurement_iqc_rejection:confirm_credit"},
                new String[]{"DEPT_FIN", "procurement_iqc_rejection:close_no_credit"},
                new String[]{"DEPT_FIN", "procurement_iqc_rejection:amount:view"},
                new String[]{"DEPT_SALES", "webinquiry:view"},
                new String[]{"DEPT_SALES", "webinquiry:claim"},
                new String[]{"DEPT_SALES", "webinquiry:close"},
                new String[]{"DEPT_SALES", "webinquiry:convert_client"},
                new String[]{"DEPT_FIN", "settlement_method:view"},
                new String[]{"DEPT_ENG", "mould_category:create"},
                new String[]{"DEPT_ENG", "mould_category:move"});
        for (String[] grant : expected) {
            Integer held = db.queryForObject("""
                    SELECT count(*) FROM department_permissions grant_row
                    JOIN departments department ON department.id = grant_row.department_id
                    JOIN permissions permission ON permission.id = grant_row.permission_id
                    WHERE department.code = ? AND permission.code = ?
                    """, Integer.class, grant[0], grant[1]);
            assertThat(held).as(grant[0] + " 应默认持有 " + grant[1]).isEqualTo(1);
        }
        // 批准后改量与提交财务同口径：凡能提交财务的部门都能改量。
        Integer missing = db.queryForObject("""
                SELECT count(*)
                FROM department_permissions submit_grant
                JOIN permissions submit ON submit.id = submit_grant.permission_id
                WHERE submit.code IN ('purchase_order:submit_finance', 'subcontract_order:submit_finance')
                  AND NOT EXISTS (
                      SELECT 1 FROM department_permissions change_grant
                      JOIN permissions change ON change.id = change_grant.permission_id
                      WHERE change_grant.department_id = submit_grant.department_id
                        AND change.code = replace(submit.code, 'submit_finance', 'change_qty'))
                """, Integer.class);
        assertThat(missing).isZero();
    }
}
