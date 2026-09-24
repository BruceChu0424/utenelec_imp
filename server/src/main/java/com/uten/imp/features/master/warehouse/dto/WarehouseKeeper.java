package com.uten.imp.features.master.warehouse.dto;

import java.util.UUID;

/**
 * 仓库负责人(仓管员)一行(ADR-115)。
 *
 * @param hasAccount      员工有启用中的登录账号(没有账号收不到任何通知)
 * @param warehouseMember 员工属于仓库部门(主部门或兼职部门在 SUB_WH 子树内); 仓库类通知只在
 *                        仓库部门里分发, 不在仓库部门的负责人收不到通知
 */
public record WarehouseKeeper(
        UUID employeeId,
        String name,
        String code,
        String departmentName,
        boolean hasAccount,
        boolean warehouseMember) {
}
