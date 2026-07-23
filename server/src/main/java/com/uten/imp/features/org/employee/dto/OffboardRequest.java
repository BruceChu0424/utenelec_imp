package com.uten.imp.features.org.employee.dto;

import jakarta.validation.constraints.NotNull;

import java.time.LocalDate;

/** 离职：置员工状态 resigned 并写一条 resign 任职记录。 */
public record OffboardRequest(
        String resignType,        // 主动/辞退/合同到期/退休
        @NotNull LocalDate effectiveDate,
        String reason
) {}
