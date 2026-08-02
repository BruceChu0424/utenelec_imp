package com.uten.imp.features.org.department.staffpermission.dto;

/**
 * 单个员工单个权限点的覆盖设置。effect 为 null 时清除覆盖（回落到部门/角色基线）；
 * 否则必须是 "grant" 或 "revoke"（服务端校验，见 DepartmentStaffPermissionService）。
 */
public record SetStaffOverrideRequest(String effect) {}
