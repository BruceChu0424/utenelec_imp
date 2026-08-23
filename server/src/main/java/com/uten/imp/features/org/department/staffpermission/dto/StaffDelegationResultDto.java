package com.uten.imp.features.org.department.staffpermission.dto;

public record StaffDelegationResultDto(
        String code,
        boolean enabled,
        long rowVersion,
        boolean effective) {
}
