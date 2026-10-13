package com.uten.imp.features.master.goods.pricing;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** Physical delivery loss, never an unreturned-material balance or a financial preservation rate. */
public final class GoodsSubcontractSupplierContracts {
    private GoodsSubcontractSupplierContracts() {}
    public record Capability(UUID goodsId,boolean applicable) {}
    public record Result(UUID goodsId,boolean applicable,String status,boolean dataComplete,int days,
            OffsetDateTime generatedAt,String summary,List<String> reasonCodes,List<Group> groups) {}
    public record Group(String key,UUID supplierId,String supplierName,UUID colorId,String colorName,
            UUID unitId,String unitName,String unitRate,String materialBasisKey,int materialKindCount,
            int sourceOrderCount,int settledSourceOrderCount,int lineCount,int settledLineCount,int pendingLineCount,int excludedLineCount,
            String settledOrderQty,String settledConfirmedLossQty,String confirmedLossRatePct,
            String allowedLossPctMin,String allowedLossPctMax,LocalDate lastOrderDate,
            List<String> reasonCodes,List<Line> lines) {}
    public record Line(UUID orderId,UUID orderItemId,String orderNo,LocalDate orderDate,String sourceRevision,
            UUID approvalCaseId,String status,boolean included,String orderedQty,String issuedEquivalentQty,
            String receivedQty,String returnedQty,String qualifiedStockedNetQty,String confirmedLossQty,
            String legacyConfirmedLossQty,String allowedLossPct,List<String> reasonCodes,boolean canOpenSource) {}
}
