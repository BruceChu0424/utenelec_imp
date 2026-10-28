package com.uten.imp.features.org.employee.dto;

import jakarta.validation.constraints.AssertTrue;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.PositiveOrZero;
import jakarta.validation.constraints.Size;
import java.util.UUID;

public record ArchiveEmployeeDuplicateRequest(
        @NotNull UUID retainedEmployeeId,
        @NotNull @PositiveOrZero Integer sourceVersion,
        @NotNull @PositiveOrZero Integer retainedVersion,
        @NotBlank @Size(min=5,max=1000) String reason,
        @AssertTrue boolean identityVerified,
        boolean documentConflictVerified) { }
