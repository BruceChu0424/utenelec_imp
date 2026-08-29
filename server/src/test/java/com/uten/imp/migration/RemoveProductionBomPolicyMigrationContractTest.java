package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * V423 契约：货品「生产 BOM 策略」与计划级 BOM 例外放行整体下线。
 * 无 BOM 货品进入物料分析后按「直接自制」投产（ZERO_MATERIAL/DIRECT_MAKE，
 * 证据 = 物料分析事实）；历史 PLAN_BOM_OVERRIDE 执行段的证据列与约束保持不动。
 */
class RemoveProductionBomPolicyMigrationContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V423__remove_production_bom_policy.sql");

    @Test
    void rewritesZeroMaterialEvidenceGuardWithoutPolicyColumns() throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("create or replace function fn_guard_execution_segment_requirement_shape()")
                // DIRECT_MAKE 的证据只保留「计划挂有与段一致的物料分析事实」。
                .contains("new.zero_material_reason = 'direct_make' and exists (")
                .contains("plan.material_analysis_id = new.zero_material_analysis_id")
                // 证据守卫不得再引用被删除的策略/例外列（ALTER DROP 语句本身除外）。
                .doesNotContain("product.production_bom_policy")
                .doesNotContain("plan.bom_override_reason")
                .doesNotContain("plan.bom_override_by")
                // 不可变守卫与 READY 守卫保留。
                .contains("execution segment material requirement shape is immutable")
                .contains("zero-material execution segment must start ready");
    }

    @Test
    void dropsPolicyAndOverrideColumns() throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("drop constraint if exists production_plan_bom_override_shape_chk")
                .contains("drop column if exists bom_override_reason")
                .contains("drop column if exists bom_override_by")
                .contains("drop constraint if exists goods_production_bom_policy_chk")
                .contains("drop column if exists production_bom_policy");
    }

    @Test
    void retiresBomOverrideAndForwardRdPermissions() throws Exception {
        String sql = compact();

        assertThat(sql)
                .contains("'production_material_analysis:bom_override'")
                .contains("'production_plan:forward_rd'")
                .contains("delete from permission_surface_permissions")
                .contains("delete from user_permission_overrides")
                .contains("delete from manager_permission_delegations")
                .contains("delete from role_permissions")
                .contains("delete from department_permissions")
                .contains("delete from permissions");
    }

    private static String compact() throws Exception {
        return Files.readString(MIGRATION, StandardCharsets.UTF_8)
                .replaceAll("--[^\\r\\n]*", " ")
                .replaceAll("\\s+", " ")
                .trim()
                .toLowerCase();
    }
}
