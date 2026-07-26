package com.uten.imp.features.finance.report.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;

/**
 * 单客户/供应商对账行（I/J/K/L 报表，AR/AP 立帐 + 收款/付款流水合并 ORDER BY bill_date）。
 *
 * <p>{@code entryType} 区分立帐与收/付款：'POSTED' 立帐（inAmount=AR 应收 / outAmount=AP 应付），
 * 'SETTLED' 收/付款核销（反方向）。
 */
@Getter
@AllArgsConstructor
public class PartyStatementRow {
    private LocalDate billDate;
    private String billNo;
    private String entryType;            // POSTED（立帐）/ SETTLED（收/付款核销）
    private String sourceDocType;        // SALES_SHIPMENT / DIRECT_RECEIPT / ...
    private String remark;
    private BigDecimal inAmount;         // 应收/收款 → 正
    private BigDecimal outAmount;        // 应付/付款 → 正
    private BigDecimal runningBalance;   // 滚动余额（应收 - 已收 / 应付 - 已付）
}
