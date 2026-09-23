package com.uten.imp.features.org.department.staffpermission;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.rbac.GrantPolicy;
import com.uten.imp.features.rbac.PermissionGrantPolicyCatalog;
import com.uten.imp.security.PermissionDelegationPolicy;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.util.Map;
import java.util.Set;
import static org.junit.jupiter.api.Assertions.assertEquals;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class PermissionDelegationPolicyTest {

    private final PermissionDelegationPolicy policy = new PermissionDelegationPolicy(
            PermissionGrantPolicyCatalog.fixed(Map.of(
                    "audit_log:view", Set.of(GrantPolicy.INDIVIDUAL_ONLY),
                    "authorization:manage", Set.of(GrantPolicy.SUPERADMIN_ONLY),
                    "account:support", Set.of(GrantPolicy.NON_DELEGABLE, GrantPolicy.BULK_EXCLUDED),
                    "stock:balance:adjust", Set.of(GrantPolicy.INDIVIDUAL_ONLY),
                    "finance:view:all", Set.of(GrantPolicy.NON_DELEGABLE, GrantPolicy.BULK_EXCLUDED),
                    "payroll:export", Set.of(GrantPolicy.NON_DELEGABLE),
                    "goods:price:view", Set.of(GrantPolicy.BULK_EXCLUDED),
                    "sales_order:view", Set.of(GrantPolicy.NORMAL))));
    private final PermissionSurfaceRegistry surfaces =
            PermissionSurfaceRegistryTestFixture.registry(Map.ofEntries(
                    Map.entry("sales.order", Set.of("sales_order:view")),
                    Map.entry("basic.goods", Set.of("goods:edit")),
                    Map.entry("basic.client", Set.of("client_address:delete")),
                    Map.entry("org.employee", Set.of("department:view")),
                    Map.entry(
                            "sales.progress",
                            Set.of("production_material_analysis:view")),
                    Map.entry(
                            "warehouse.inbound",
                            Set.of("procurement_inspection:handle")),
                    Map.entry("warehouse.stock-balance", Set.of("stock:view")),
                    Map.entry(
                            "warehouse.stock-movement",
                            Set.of("stock:view")),
                    Map.entry(
                            "warehouse.instant-inventory",
                            Set.of("stock_report:export")),
                    Map.entry(
                            "warehouse.hub",
                            Set.of("procurement_inspection:view")),
                    Map.entry("basic.hub", Set.of("client:view")),
                    Map.entry("purchase.hub", Set.of("purchase_order:view")),
                    Map.entry("sales.hub", Set.of("sales_report:view")),
                    Map.entry(
                            "subcontract.hub",
                            Set.of("subcontract_waste:view")),
                    Map.entry("hr.task", Set.of("employee:edit")),
                    Map.entry(
                            "finance.hub",
                            Set.of("account:view", "finance_receipt:view")),
                    Map.entry(
                            "production.hub",
                            Set.of(
                                    "production_plan:view",
                                    "production_plan:edit",
                                    "production_plan:approve")),
                    Map.entry(
                            "production.plan",
                            Set.of(
                                    "production_material_analysis:view",
                                    "production_daily_report:edit")),
                    Map.entry(
                            "hr.visitor-approval",
                            Set.of("visitor:approve")),
                    Map.entry(
                            "hr.visitor-security",
                            Set.of("visitor:check_in")),
                    Map.entry("operations.purchase", Set.of())));

    @ParameterizedTest
    @ValueSource(strings = {
            "audit_log:view",
            "authorization:manage",
            "account:support",
            "stock:balance:adjust",
            "finance:view:all",
            "payroll:export"
    })
    void grantPolicyFlagsDecideDelegationWithoutAnyHardCodedList(String code) {
        assertFalse(policy.isDelegable(code));
        assertTrue(policy.nonDelegableReason(code).contains("不能") || policy.nonDelegableReason(code).contains("只"));
    }

    @Test
    void bulkExcludedOnlyCodeStaysDelegable() {
        // 不随「全部授权」批量发放 ≠ 负责人不能在页面上逐项转授。
        assertTrue(policy.isDelegable("goods:price:view"));
    }

    @Test
    void unknownCodeFailsClosed() {
        assertFalse(policy.isDelegable("retired:code"));
        assertEquals("这项权限已不在权限目录里，不能转授", policy.nonDelegableReason("retired:code"));
    }

    @Test
    void reasonsFollowTheStrongestPolicyFlag() {
        assertEquals("这项权限只随超级管理员身份生效，不能转授",
                policy.nonDelegableReason("authorization:manage"));
        assertEquals("这项高风险权限只能由超级管理员在全局权限页逐人授予",
                policy.nonDelegableReason("stock:balance:adjust"));
        assertEquals("这项权限不能由负责人转授，请联系超级管理员在全局权限页配置",
                policy.nonDelegableReason("payroll:export"));
    }

    @Test
    void ordinaryBusinessPermissionRemainsDelegable() {
        assertTrue(policy.isDelegable("sales_order:view"));
    }

    @Test
    void surfaceRegistryAcceptsOnlyItsOwnCodesAndKnownHubKeys() {
        assertTrue(surfaces.contains("sales.order", "sales_order:view"));
        assertTrue(surfaces.contains("basic.goods", "goods:edit"));
        assertTrue(surfaces.contains("basic.client", "client_address:delete"));
        assertTrue(surfaces.contains("org.employee", "department:view"));
        assertTrue(surfaces.contains("sales.progress", "production_material_analysis:view"));
        assertTrue(surfaces.contains("warehouse.inbound", "procurement_inspection:handle"));
        assertTrue(surfaces.contains("warehouse.stock-balance", "stock:view"));
        assertFalse(surfaces.contains("warehouse.stock-movement", "stock:balance:adjust"));
        assertTrue(surfaces.contains("warehouse.instant-inventory", "stock_report:export"));
        assertTrue(surfaces.contains("warehouse.hub", "procurement_inspection:view"));
        assertFalse(surfaces.contains("warehouse.hub", "procurement_inspection:handle"));
        assertTrue(surfaces.contains("basic.hub", "client:view"));
        assertFalse(surfaces.contains("basic.hub", "client:edit"));
        assertTrue(surfaces.contains("purchase.hub", "purchase_order:view"));
        assertFalse(surfaces.contains("purchase.hub", "purchase_order:edit"));
        assertTrue(surfaces.contains("sales.hub", "sales_report:view"));
        assertFalse(surfaces.contains("sales.hub", "sales_report:export"));
        assertTrue(surfaces.contains("subcontract.hub", "subcontract_waste:view"));
        assertFalse(surfaces.contains("subcontract.hub", "subcontract_waste:edit"));
        assertFalse(surfaces.isKnown("warehouse.inventory"));
        assertTrue(surfaces.contains("hr.task", "employee:edit"));
        assertTrue(surfaces.contains("finance.hub", "account:view"));
        assertTrue(surfaces.contains("production.hub", "production_plan:view"));
        assertTrue(surfaces.contains("production.hub", "production_plan:edit"));
        assertTrue(surfaces.contains(
                "production.hub", "production_plan:approve"));
        assertFalse(surfaces.contains("production.hub", "production_plan:view:all"));
        assertTrue(surfaces.contains("finance.hub", "finance_receipt:view"));
        assertFalse(surfaces.contains("finance.hub", "finance_receipt:edit"));
        assertTrue(surfaces.contains(
                "production.plan", "production_material_analysis:view"));
        assertTrue(surfaces.contains("production.plan", "production_daily_report:edit"));
        assertTrue(surfaces.knownKeys().contains("hr.visitor-approval"));
        assertTrue(surfaces.knownKeys().contains("hr.visitor-security"));
        assertTrue(surfaces.contains("hr.visitor-approval", "visitor:approve"));
        assertFalse(surfaces.contains("hr.visitor-approval", "visitor:check_in"));
        assertTrue(surfaces.contains("hr.visitor-security", "visitor:check_in"));
        assertFalse(surfaces.contains("hr.visitor-security", "visitor:approve"));
        assertDoesNotThrow(() -> surfaces.requireKnown("operations.purchase"));
        assertThrows(
                ApiException.class,
                () -> surfaces.requireContains("sales.order", "purchase_order:view"));
        assertThrows(
                ApiException.class,
                () -> surfaces.requireKnown("unknown.route"));
    }
}
