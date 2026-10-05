package com.uten.imp.features.master.warehouse.dto;

import java.util.UUID;

/**
 * 仓库负责人(仓管员)一行(ADR-115)。
 *
 * @param hasAccount      员工有启用中的登录账号(没有账号 = 不算有效负责人: 看不到任务、收不到通知)
 * @param warehouseMember 员工属于仓库部门(主部门或兼职部门在 SUB_WH 子树内); 部门外的负责人
 *                        也按登记的仓收通知与看任务(ADR-149), 这里只做提示
 * @param duplicateName   还有同名的在职员工(候选列表标出编号, 防止登记到没账号的那份档案上)
 */
public record WarehouseKeeper(
        UUID employeeId,
        String name,
        String code,
        String departmentName,
        boolean hasAccount,
        boolean warehouseMember,
        boolean duplicateName) {
}
