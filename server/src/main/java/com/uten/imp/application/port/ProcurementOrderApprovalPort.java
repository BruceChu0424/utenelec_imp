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

    /**
     * Submission is an owner-controlled state transition. Finance review calls
     * deliberately do not use this guard because they are pooled operations.
     */
    void requireFinanceSubmitterWritable(UUID orderId);

    OrderSnapshot lockAndValidateFinanceSubmission(UUID orderId);

    void applyFinanceApproval(UUID orderId, UUID approverEmployeeId);

    /**
     * V486 批准后改量（对齐销售 V482）：订单是否已处于财务批准生效状态。
     * 复核 case 审批时据此跳过草稿校验与重复生效副作用（改量已在 change-qty
     * 事务内生效，复核通过只是财务确认）。
     */
    boolean isFinanceApproved(UUID orderId);

    /** Lock the effective order and snapshot current commercial facts without applying them again. */
    OrderSnapshot lockFinanceReconfirmationSnapshot(UUID orderId);

    record OrderSnapshot(
            String orderType,
            UUID orderId,
            String billNo,
            LocalDate billDate,
            UUID supplierId,
            UUID warehouseId,
            UUID currencyId,
            BigDecimal exchangeRate,
            UUID settlementMethodId,
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
