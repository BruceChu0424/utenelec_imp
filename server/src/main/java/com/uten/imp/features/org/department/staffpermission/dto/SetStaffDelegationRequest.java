package com.uten.imp.features.org.department.staffpermission.dto;

import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotNull;

public record SetStaffDelegationRequest(
        @NotNull Boolean enabled,
        @NotNull @Min(0) Long expectedVersion) {
}
