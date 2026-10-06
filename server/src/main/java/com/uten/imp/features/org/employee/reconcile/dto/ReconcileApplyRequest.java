package com.uten.imp.features.org.employee.reconcile.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.List;

/**
 * 执行一轮核对更正的请求体（V810/ADR-160）：带计划版本与请求标识，服务端先在锁定事务里
 * 整体校验全部行/项（行号/项号存在、候选序号不越界、手输值过校验），任何一处不合法都不执行写。
 */
public record ReconcileApplyRequest(
        @NotNull Integer planVersion,
        @NotBlank @Size(max = 64) String requestId,
        @NotEmpty @Size(max = 300) List<@Valid @NotNull RowSelection> rows) {

    /** 选中要执行的一行（rowNo 为计划内序号）。 */
    public record RowSelection(
            @NotNull Integer rowNo,
            @NotEmpty @Size(max = 24) List<@Valid @NotNull ItemSelection> items) {
    }

    /** 一项的确认结果：手输值优先，其次候选序号，都缺省时用建议值。 */
    public record ItemSelection(
            @NotNull Integer itemNo,
            @Min(0) @Max(2) Integer candidateIndex,
            @Size(max = 64) String value) {
    }
}
