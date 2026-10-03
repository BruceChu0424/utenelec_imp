package com.uten.imp.common.finance;

import com.uten.imp.common.columns.ExtraColumnResponse;
import java.math.BigDecimal;

/** Exact edit round-trip alongside legacy numeric response fields. */
public abstract class OrderAmountInputResponse extends ExtraColumnResponse {
    private BigDecimal totalAmountInput;

    public BigDecimal getTotalAmountInput() { return totalAmountInput; }
    public void setTotalAmountInput(BigDecimal value) { totalAmountInput = value; }
    public String getTotalAmountInputExact() { return text(totalAmountInput); }
    public String getQtyExact() { return text(getQty()); }
    public String getPriceExact() { return text(getPrice()); }
    public String getAmountOriginalExact() { return text(getAmountOriginal()); }
    public String getAmountLocalExact() { return text(getAmountLocal()); }

    public abstract BigDecimal getQty();
    public abstract BigDecimal getPrice();
    public abstract BigDecimal getAmountOriginal();
    public abstract BigDecimal getAmountLocal();

    private static String text(BigDecimal value) {
        return value == null ? null : value.stripTrailingZeros().toPlainString();
    }
}
