package com.uten.imp.features.org.department.staffpermission.dto;

public record PermissionDelegationCapabilityDto(
        String surfaceKey,
        boolean superAdmin,
        boolean canManage) {
}
