package com.uten.imp.application.port;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * Finance-facing port for purchase and subcontract order approval.
 *
 * <p>The finance feature owns approval cases but never imports procurement feature classes.
 * Implementations lock and validate their aggregate before returning a canonical snapshot.
 */
public interface ProcurementOrderApprovalPort {

    String orderType();

    OrderSnapshot lockAndValidateFinanceSubmission(UUID orderId);

    void applyFinanceApproval(UUID orderId, UUID approverEmployeeId);

    record OrderSnapshot(
            String orderType,
            UUID orderId,
            String billNo,
            LocalDate billDate,
            UUID supplierId,
            UUID warehouseId,
            UUID currencyId,
            BigDecimal exchangeRate,
            BigDecimal taxRate,
            UUID purchaserEmployeeId,
            UUID makerEmployeeId,
            LocalDate deliverDate,
            BigDecimal totalOriginal,
            BigDecimal totalLocal,
            List<ItemSnapshot> items) {
        public OrderSnapshot {
            items = List.copyOf(items);
        }
    }

    record ItemSnapshot(
            UUID itemId,
            Integer lineNo,
            UUID sourceItemId,
            UUID goodsId,
            UUID colorId,
            UUID unitId,
            BigDecimal unitRate,
            BigDecimal qty,
            BigDecimal price,
            BigDecimal amountOriginal,
            BigDecimal amountLocal,
            LocalDate deliverDate) {
    }
}
