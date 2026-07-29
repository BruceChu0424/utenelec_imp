package com.uten.imp.features.finance.expense.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 一般费用单详情。 */
@Getter
@AllArgsConstructor
public class FinanceExpenseDetail {
    private UUID id;
    private Integer legacyId;
    private String billNo;
    private LocalDate billDate;
    private UUID accountId;
    private UUID counterpartAccountId;
    private UUID currencyId;
    private BigDecimal exchangeRate;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
    private UUID operatorId;
    private UUID makerId;
    private UUID approverId;
    private String remark;
    private Short status;
    private boolean closed;
    /** C6：0 未过账 / 1 已过账待确认 / 2 财务已确认。 */
    private Short glStatus;
    private List<FinanceExpenseItemDto> items;
    /** 制单员姓名（服务端按 maker_id 解析：employees 直查 + users 历史数据兼容）。 */
    private String makerName;
    /** 制单时间（审计 created_at，创建后不可变）。 */
    private java.time.Instant createdAt;
}
