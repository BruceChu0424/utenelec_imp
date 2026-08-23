package com.uten.imp.features.org.department.staffpermission.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.List;

public record BatchSetStaffPermissionsRequest(
        @NotEmpty
        @Size(max = 100)
        List<@Valid Change> changes) {

    public record Change(
            @NotBlank @Size(max = 160) String code,
            @NotNull Boolean enabled,
            @NotNull @Min(0) Long expectedVersion) {
    }
}
