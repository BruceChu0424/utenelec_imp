package com.uten.imp.features.finance.report.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 客户/供应商年度对账单汇总行（X 报表）。
 *
 * <p>口径：期末 = 期初 + 本期立帐 − 本期收款。
 */
@Getter
@AllArgsConstructor
public class PartyAnnualStatementRow {
    private UUID partyId;
    private String partyName;
    /** 期初余额（截至 year-01-01 之前未核销的累计 balance）。 */
    private BigDecimal openingBalance;
    /** 本期立帐（year 内 amount_original_local 求和）。 */
    private BigDecimal currentPosted;
    /** 本期收款/付款核销（year 内 amount_settled 求和）。 */
    private BigDecimal currentSettled;
    /** 期末余额 = 期初 + 本期立帐 − 本期核销。 */
    private BigDecimal closingBalance;
}
