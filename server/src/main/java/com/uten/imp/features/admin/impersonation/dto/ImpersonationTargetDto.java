package com.uten.imp.features.admin.impersonation.dto;

import java.util.UUID;

/** 模拟目标候选（picker 用）：员工档案 id + 姓名 + 部门 + 岗位。仅活跃员工。 */
public record ImpersonationTargetDto(
        UUID employeeId,
        String name,
        String departmentName,
        String positionName) {
}
