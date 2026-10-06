package com.uten.imp.features.org.employee.reconcile.dto;

import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.List;
import java.util.UUID;

/** 证件核对页多选员工后生成核对计划的请求体（V810/ADR-160）。 */
public record CreateIdRepairPlanRequest(
        @NotEmpty @Size(max = 200) List<@NotNull UUID> employeeIds) {
}
