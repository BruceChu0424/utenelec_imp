package com.uten.imp.features.finance.report.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 钱流单据汇总行（F/H/N/P 报表，按 party/月/部门/项目分组）。
 *
 * <p>groupKey 由查询参数决定（如 by=party → partyId+partyName；by=month → ym；by=dept → deptId+deptName）。
 */
@Getter
@AllArgsConstructor
public class FinanceDocSummaryRow {
    private LocalDate ym;                 // 按月汇总时填
    private UUID partyId;                 // by=party（客户/供应商）
    private String partyName;
    private UUID departmentId;            // by=dept（费用/收入分摊）
    private String departmentName;
    private UUID styleId;                 // by=style（费用项目/收入项目）
    private String styleName;
    private Long cnt;
    private BigDecimal amountOriginalSum;
    private BigDecimal amountLocalSum;
}
