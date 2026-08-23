package com.uten.imp.features.org.department.staffpermission.dto;

import java.util.List;

public record BatchSetStaffPermissionsResultDto(
        String settingMode,
        List<ChangeResult> changes) {

    public record ChangeResult(
            String code,
            boolean enabled,
            long rowVersion,
            boolean effective) {
    }
}
