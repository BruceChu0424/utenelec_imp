package com.uten.imp.security;

import org.springframework.stereotype.Component;

import java.util.Map;
import java.util.Set;

/**
 * Single server-side policy for permissions that an organization leader must
 * never delegate.  Super administrators use the same contextual restriction;
 * high-risk grants remain available only through the global authorization page.
 */
@Component
public class PermissionDelegationPolicy {

    private static final Set<String> NON_DELEGABLE = Set.of(
            "authorization:manage",
            "user:manage",
            "account:support",
            "stock:balance:adjust",
            "finance_asset:approve",
            "finance_asset:post",
            "finance_asset:dispose",
            "finance_asset:export",
            "finance_asset_period:manage",
            "production_material_analysis:view",
            "production_material_analysis:bom_override",
            "production_material_analysis:cross_reallocate",
            "sales_order:priority",
            "sales_order:reallocate",
            "supplier_return_task:view",
            "supplier_return_task:complete",
            "attachment:reconcile",
            "attachment:reconcile:view",
            "attachment:reconcile:approve_delete",
            "payroll:export",
            "viewcontext:scoped",
            "dashboard:finance-sensitive:view");

    private static final Map<String, String> REASONS = Map.ofEntries(
            Map.entry("authorization:manage", "授权策略只能在全局权限页由超级管理员维护"),
            Map.entry("user:manage", "历史账号管理权限不可由组织负责人转授"),
            Map.entry("account:support", "账号支持能力不可由组织负责人转授"),
            Map.entry("stock:balance:adjust", "库存余额调整属于高风险个人授权"),
            Map.entry("production_material_analysis:view",
                    "物料分析读取仍覆盖全局链路健康数据，只能由超级管理员点名授权"),
            Map.entry("production_material_analysis:bom_override", "无 BOM 例外须由超级管理员逐人授权"),
            Map.entry("production_material_analysis:cross_reallocate", "跨分析让料须由超级管理员逐人授权"),
            Map.entry("sales_order:priority", "急单优先级属于高风险个人授权"),
            Map.entry("sales_order:reallocate", "稀缺库存让单属于高风险个人授权"),
            Map.entry("supplier_return_task:view", "供应商退回任务仅允许全局点名授权"),
            Map.entry("supplier_return_task:complete", "完成供应商退回任务不可向下转授"),
            Map.entry("attachment:reconcile", "仅保留历史点名授权，当前不可新增或由负责人转授"),
            Map.entry("attachment:reconcile:view", "仅保留历史点名授权，当前不可新增或由负责人转授"),
            Map.entry("attachment:reconcile:approve_delete", "仅保留历史点名授权，当前不可新增或由负责人转授"));

    public boolean isDelegable(String permissionCode) {
        return permissionCode != null
                && !permissionCode.startsWith("audit_log:")
                && !permissionCode.endsWith(":view:all")
                && !NON_DELEGABLE.contains(permissionCode);
    }

    public String nonDelegableReason(String permissionCode) {
        if (permissionCode != null && permissionCode.startsWith("audit_log:")) {
            return "审计证据权限只能在全局权限页由超级管理员逐人授权";
        }
        if (permissionCode != null && permissionCode.endsWith(":view:all")) {
            return "公司全量对象范围只能在全局权限页由超级管理员配置";
        }
        if (permissionCode != null && permissionCode.startsWith("finance_asset:")) {
            if (Set.of(
                    "finance_asset:approve",
                    "finance_asset:post",
                    "finance_asset:dispose",
                    "finance_asset:export").contains(permissionCode)) {
                return "资产审批、过账、处置和导出须由超级管理员逐人授权";
            }
        }
        if ("finance_asset_period:manage".equals(permissionCode)) {
            return "财务期间管理须由超级管理员逐人授权";
        }
        return REASONS.getOrDefault(permissionCode, "该高风险权限不可由组织负责人转授");
    }
}
