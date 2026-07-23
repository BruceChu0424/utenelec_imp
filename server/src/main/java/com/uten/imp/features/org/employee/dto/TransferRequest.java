package com.uten.imp.features.org.employee.dto;

import jakarta.validation.constraints.NotNull;

import java.time.LocalDate;
import java.util.UUID;

/** 调岗：写一条 transfer 任职记录并更新员工部门/岗位/上级。 */
public record TransferRequest(
        @NotNull UUID toDepartmentId,
        UUID toPositionId,
        UUID supervisorId,
        @NotNull LocalDate effectiveDate,
        String remark
) {}
