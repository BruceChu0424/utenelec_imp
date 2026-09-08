package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * 2026-09-05 委外收敛：委外准备中心页面与 HTTP 入口退役——前置生产由系统自动
 * 「发单给计划」（草稿期分析 + MAKE_THEN 行自动启动 + 补偿器兜底）。本契约锁：
 * 1）准备中心 Controller 不再存在；2）V486 已把 subcontract_preparation:view/start
 * 停用（不可分配、surface 下线），并登记了采购/委外改量权限码。
 */
class SubcontractPreparationPermissionContractTest {

    private static final Path MIGRATION = Path.of(
            "src/main/resources/db/migration/"
                    + "V486__procurement_qty_change_and_preparation_retirement.sql");
    private static final Path ANALYSIS_PACKAGE = Path.of(
            "src/main/java/com/uten/imp/features/production/analysis");

    @Test
    void preparationControllerIsRetired() {
        assertFalse(Files.exists(
                ANALYSIS_PACKAGE.resolve("SubcontractPreparationController.java")),
                "委外准备中心 Controller 必须保持退役（前置生产由系统自动发起）");
    }

    @Test
    void v486RetiresPreparationPermissionsAndAddsChangeQty() throws IOException {
        String sql = Files.readString(MIGRATION, StandardCharsets.UTF_8);

        assertTrue(sql.contains("subcontract_preparation:view"));
        assertTrue(sql.contains("subcontract_preparation:start"));
        assertTrue(sql.contains("subcontract.preparation"));
        assertTrue(sql.contains("active = FALSE"));
        assertTrue(sql.contains("assignable = FALSE"));
        assertTrue(sql.contains("enabled = FALSE"));
        assertTrue(sql.contains("purchase_order:change_qty"));
        assertTrue(sql.contains("subcontract_order:change_qty"));
        assertTrue(sql.contains("procurement_order_qty_change_logs"));
        assertTrue(sql.contains("business_data_reset"));
        // 不允许退役时改动历史授权（V441 同口径）。
        assertTrue(sql.contains("V486 changed historical preparation grants"));
        assertFalse(sql.contains("INSERT INTO department_permissions"));
        assertFalse(sql.contains("INSERT INTO role_permissions"));
        assertFalse(sql.contains("INSERT INTO user_permission_overrides"));
    }
}
