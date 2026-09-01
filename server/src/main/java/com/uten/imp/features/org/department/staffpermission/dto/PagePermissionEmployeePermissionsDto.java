package com.uten.imp.features.org.department.staffpermission.dto;

import java.util.List;
import java.util.UUID;

/** Permission state for one selected employee and one stable page surface. */
public record PagePermissionEmployeePermissionsDto(
        String surfaceKey,
        UUID departmentId,
        String departmentName,
        PagePermissionStaffPageDto.StaffSummary employee,
        String settingMode,
        List<PermissionState> permissions) {

    public record PermissionState(
            String code,
            String name,
            String actionType,
            String description,
            boolean assignable,
            boolean bulkAssignable,
            String sensitivity,
            boolean actorEffective,
            boolean targetBaseEffective,
            boolean effective,
            String configuredEffect,
            long rowVersion,
            boolean editable,
            String reason) {
    }
}
