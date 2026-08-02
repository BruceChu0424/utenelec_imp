package com.uten.imp.features.org.department.staffpermission.dto;

import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 部门主管的"本部门员工权限"面板数据（问题 #20）。
 *
 * <p>{@code permissionCodes} 是本部门负责人可转授的权限点上限——负责人本人有效权限扣除全员基础权限后的集合
 * （只转授自己持有的、且非人人皆有的权限）。其中 baseline=true 表示属于部门配置基线（部门里人人默认有），
 * baseline=false 表示负责人个人加授的额外权限。既可对基线权限做开/关，也可把额外权限授予成员；不能凭空升级。
 */
public record DepartmentStaffPermissionsDto(
        UUID departmentId,
        String departmentName,
        List<PermissionItem> permissionCodes,
        List<StaffRow> staff) {

    /** @param baseline 是否属于部门配置基线（部门里人人默认有）；false=负责人个人加授的额外权限。 */
    public record PermissionItem(String code, String name, boolean baseline) {}

    /**
     * @param overrides code → effect（"grant"/"revoke"），未出现的 code 表示未覆盖、按部门/角色基线生效。
     * @param hasAccount 员工未开通登录账号时不可授权（没有 user_id 可挂载覆盖）。
     */
    public record StaffRow(
            UUID employeeId,
            String code,
            String fullName,
            String positionName,
            boolean departmentManager,
            boolean hasAccount,
            Map<String, String> overrides) {}
}
