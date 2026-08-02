package com.uten.imp.features.admin.workflow;

import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.time.OffsetDateTime;
import java.util.UUID;

public final class WorkflowResponsibilityContracts {

    private WorkflowResponsibilityContracts() {
    }

    public record Responsibility(
            String behaviorCode,
            UUID assigneeUserId,
            UUID assigneeEmployeeId,
            String assigneeName,
            long version,
            OffsetDateTime updatedAt) {
    }

    public record Reviewer(
            UUID userId,
            UUID employeeId,
            String employeeName,
            UUID departmentId,
            String departmentName) {
    }

    public record UpdateRequest(
            @NotNull UUID assigneeUserId,
            @NotNull @Min(0) Long expectedVersion,
            @NotBlank @Size(max = 128) String password) {
    }
}
