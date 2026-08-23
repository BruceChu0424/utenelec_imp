package com.uten.imp.features.org.department.staffpermission.dto;

import java.util.UUID;

public record ManagedDepartmentDto(
        UUID departmentId,
        String code,
        String departmentName,
        String level,
        UUID parentId,
        Integer sortOrder,
        boolean selectable) {
}
