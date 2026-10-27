package com.uten.imp.common.finance;

import com.uten.imp.common.util.DecimalText;
import java.math.BigDecimal;
import java.util.UUID;
import lombok.Getter;
import lombok.Setter;

/** Current cumulative delivery variance of one explicitly linked source order, in its own unit. */
@Getter
@Setter
public abstract class ProcurementSourceOrderDifferenceResponse {
    private BigDecimal sourceOrderDifferenceQty;
    private UUID sourceOrderDifferenceUnitId;

    public abstract UUID getOrderItemId();

    public String getSourceOrderDifferenceQtyExact() {
        return DecimalText.of(sourceOrderDifferenceQty);
    }

    public void copySourceOrderDifferenceTo(ProcurementSourceOrderDifferenceResponse target) {
        target.setSourceOrderDifferenceQty(sourceOrderDifferenceQty);
        target.setSourceOrderDifferenceUnitId(sourceOrderDifferenceUnitId);
    }
}
