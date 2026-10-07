package com.uten.imp.features.org.department.staffpermission.dto;

import java.util.List;
import java.util.UUID;

/**
 * Permission state for one selected employee and one stable page surface.
 *
 * <p>V812 hub drawers receive the whole surface tree: the root group keeps
 * only codes no child surface claims, and child groups follow catalog sort
 * order. Flat surfaces still get a single root group.</p>
 */
public record PagePermissionEmployeePermissionsDto(
        String surfaceKey,
        String surfaceTitle,
        UUID departmentId,
        String departmentName,
        PagePermissionStaffPageDto.StaffSummary employee,
        String settingMode,
        List<SurfaceGroupDto> groups) {

    public record SurfaceGroupDto(
            String surfaceKey,
            String title,
            boolean root,
            List<PermissionState> permissions) {
    }

    public record PermissionState(
            String code,
            String name,
            String actionType,
            String description,
            List<String> grantPolicy,
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
