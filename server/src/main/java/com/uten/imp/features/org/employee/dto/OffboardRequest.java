package com.uten.imp.features.org.employee.dto;

import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

import java.time.LocalDate;
import java.util.Set;
import java.util.UUID;

/** 离职：置员工状态 resigned 并写一条 resign 任职记录。 */
public record OffboardRequest(
        @NotBlank String resignType,        // VOLUNTARY/DISMISSED/CONTRACT_END/RETIRE
        @NotNull LocalDate effectiveDate,
        @NotBlank @Size(max = 2000) String reason,
        UUID successorEmployeeId,
        @NotNull UUID requestId,
        @Size(max = 2000) String handoverReason,
        @NotNull @Size(min = 4, max = 4)
        Set<@NotBlank String> confirmedChecklistCodes
) {}
