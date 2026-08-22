package com.uten.imp.features.org.department.staffpermission.dto;

import java.util.List;
import java.util.UUID;

/** One bounded page of employees eligible for the page-permission workspace. */
public record PagePermissionStaffPageDto(
        String surfaceKey,
        UUID departmentId,
        String departmentName,
        int page,
        int size,
        long total,
        int totalPages,
        List<StaffSummary> staff) {

    public record StaffSummary(
            UUID employeeId,
            String code,
            String fullName,
            UUID departmentId,
            String departmentName,
            String positionName,
            boolean departmentManager,
            boolean hasAccount,
            boolean accountActive) {
    }
}
