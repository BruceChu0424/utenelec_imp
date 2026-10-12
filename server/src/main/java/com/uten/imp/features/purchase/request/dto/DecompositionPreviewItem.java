package com.uten.imp.features.purchase.request.dto;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** Demand-only purchase line exposed to the procurement decomposition screen. */
public record DecompositionPreviewItem(
        UUID sourceDocumentId,
        String sourceDocumentNo,
        UUID sourceItemId,
        UUID goodsId,
        UUID colorId,
        UUID unitId,
        BigDecimal unitRate,
        BigDecimal requestedQty,
        BigDecimal orderedQty,
        BigDecimal pendingQty,
        BigDecimal remainingQty,
        LocalDate needDate,
        UUID warehouseId,
        String sourcePlanNo,
        String quantitySemantics,
        BigDecimal giftQty,
        BigDecimal giftOrderedQty,
        BigDecimal pendingGiftQty,
        BigDecimal remainingGiftQty,
        BigDecimal physicalRemainingQty) {
    public DecompositionPreviewItem(UUID sourceDocumentId,String sourceDocumentNo,UUID sourceItemId,
            UUID goodsId,UUID colorId,UUID unitId,BigDecimal unitRate,BigDecimal requestedQty,
            BigDecimal orderedQty,BigDecimal pendingQty,BigDecimal remainingQty,LocalDate needDate,
            UUID warehouseId,String sourcePlanNo) {
        this(sourceDocumentId,sourceDocumentNo,sourceItemId,goodsId,colorId,unitId,unitRate,
                requestedQty,orderedQty,pendingQty,remainingQty,needDate,warehouseId,sourcePlanNo,
                com.uten.imp.common.finance.ProcurementQuantities.LEGACY,BigDecimal.ZERO,
                BigDecimal.ZERO,BigDecimal.ZERO,BigDecimal.ZERO,remainingQty);
    }
    public String getUnitRateExact(){return text(unitRate);}
    public String getRequestedQtyExact(){return text(requestedQty);}
    public String getOrderedQtyExact(){return text(orderedQty);}
    public String getPendingQtyExact(){return text(pendingQty);}
    public String getRemainingQtyExact(){return text(remainingQty);}
    public String getGiftQtyExact(){return text(giftQty);}
    public String getGiftOrderedQtyExact(){return text(giftOrderedQty);}
    public String getPendingGiftQtyExact(){return text(pendingGiftQty);}
    public String getRemainingGiftQtyExact(){return text(remainingGiftQty);}
    public String getPhysicalQtyExact(){return com.uten.imp.common.finance.ProcurementQuantities.physicalText(quantitySemantics,requestedQty,giftQty);}
    public BigDecimal getPhysicalOrderedQty(){return zero(orderedQty).add(zero(giftOrderedQty));}
    public BigDecimal getPhysicalPendingQty(){return zero(pendingQty).add(zero(pendingGiftQty));}
    public String getPhysicalOrderedQtyExact(){return text(getPhysicalOrderedQty());}
    public String getPhysicalPendingQtyExact(){return text(getPhysicalPendingQty());}
    public String getPhysicalRemainingQtyExact(){return text(physicalRemainingQty);}
    private static BigDecimal zero(BigDecimal value){return value==null?BigDecimal.ZERO:value;}
    private static String text(BigDecimal value){return com.uten.imp.common.util.DecimalText.of(value);}
}
