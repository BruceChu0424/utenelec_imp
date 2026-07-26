package com.uten.imp.features.finance.report.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 应收应付明细行（A/C 报表，查 ar_ap_ledger + clients/suppliers JOIN）。
 *
 * <p>对比 {@code ArApLedgerListItem}，多 partyName + sourceDocType 描述（前端展示用）。
 */
@Getter
@AllArgsConstructor
public class ArApDetailReportRow {
    private UUID id;
    private String direction;
    private String sourceDocType;
    private UUID sourceDocId;
    private String sourceDocNo;
    private String billNo;
    private LocalDate billDate;
    private UUID partyId;
    private String partyName;
    private UUID currencyId;
    private BigDecimal amountOriginalLocal;
    private BigDecimal amountSettled;
    private BigDecimal amountBalance;
    private boolean settled;
    private LocalDate settledDate;
    private Short status;
    private String remark;
}
