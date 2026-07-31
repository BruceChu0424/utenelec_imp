package com.uten.imp.features.production.execution;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.time.LocalDate;
import java.util.UUID;

public record SegmentAssignmentRequest(
        @NotNull Long expectedVersion,
        @NotBlank @Size(min = 8, max = 128) String idempotencyKey,
        UUID workshopDepartmentId,
        UUID teamDepartmentId,
        UUID responsibleEmployeeId,
        LocalDate planBeginDate,
        LocalDate planEndDate) {
}
