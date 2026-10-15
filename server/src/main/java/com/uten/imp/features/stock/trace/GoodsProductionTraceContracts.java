package com.uten.imp.features.stock.trace;

import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import com.uten.imp.common.finance.ExactDecimalText;
import com.uten.imp.application.port.MaterialTraceabilityReadPort;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

public final class GoodsProductionTraceContracts {
    private GoodsProductionTraceContracts() {}
    public record GoodsIdentity(UUID goodsId,String goodsCode,String goodsName,UUID colorId,String colorName,
                                UUID unitId,String unitName) {}
    public record DocumentRef(UUID id,String billNo,String docType,LocalDate billDate) {}
    /** Ordered participants of the whole report, not per-person production quantities. */
    public record Worker(UUID id,String name) {}
    public record OutputBatch(UUID id,String code,UUID reportItemId,
                              @JsonSerialize(using=ExactDecimalText.class) BigDecimal productQty,String unitName,
                              Integer lineNo,String label) {}
    public record ProductionReport(UUID id,String billNo,LocalDate billDate,UUID segmentId,
                                   @JsonSerialize(using=ExactDecimalText.class) BigDecimal productQty,
                                   String unitName,List<Worker> workers,List<OutputBatch> batches) {
        public ProductionReport(UUID id,String billNo,LocalDate billDate,UUID segmentId,BigDecimal productQty,
                                String unitName,List<Worker> workers) {
            this(id,billNo,billDate,segmentId,productQty,unitName,workers,List.of());
        }
    }
    /** Only an exact receipt-to-issued-reservation bridge can populate this list. */
    public record ReceiptSource(UUID id,String billNo,UUID receiptItemId,LocalDate billDate,UUID supplierId,
                                String supplierName,@JsonSerialize(using=ExactDecimalText.class) BigDecimal qty,
                                String sourceBasis,String sourceDocType,
                                String sourceDocCode) {}
    /** One ORDER demand or one PERIODIC allocation. Report quantities must never be summed across materials. */
    public record TraceRow(String id,String kind,String quantityBasis,UUID planId,String planNo,UUID segmentId,
                           String segmentCode,String workshopName,GoodsIdentity product,GoodsIdentity material,
                           @JsonSerialize(using=ExactDecimalText.class) BigDecimal issuedQty,
                           @JsonSerialize(using=ExactDecimalText.class) BigDecimal returnedQty,
                           @JsonSerialize(using=ExactDecimalText.class) BigDecimal consumedQty,
                           @JsonSerialize(using=ExactDecimalText.class) BigDecimal lossQty,
                           @JsonSerialize(using=ExactDecimalText.class) BigDecimal allocatedQty,
                           List<DocumentRef> drawDocuments,List<ProductionReport> reports,
                           List<ReceiptSource> receiptSources) implements MaterialTraceabilityReadPort.TraceItem {}
}
