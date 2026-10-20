package com.uten.imp.features.purchase.order.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

@Getter

public class OrderItemDto extends com.uten.imp.common.finance.OrderAmountInputResponse {
    @lombok.Setter private String quantitySemantics = "LEGACY_RECORDED";
    @lombok.Setter private BigDecimal giftReceivedQty = BigDecimal.ZERO;
    @lombok.Setter private BigDecimal giftReturnedQty = BigDecimal.ZERO;
    @lombok.Setter private BigDecimal remainingGiftQty = BigDecimal.ZERO;

    public OrderItemDto(UUID id, Integer lineNo, UUID goodsId, String goodsCodeSnapshot, String goodsNameSnapshot, String goodsSnapshotSource, OffsetDateTime goodsSnapshotLockedAt, UUID colorId, UUID unitId, BigDecimal unitRate, BigDecimal qty, BigDecimal price, BigDecimal amountOriginal, BigDecimal amountLocal, BigDecimal receivedQty, BigDecimal returnedQty, BigDecimal giftQty, UUID requestItemId, LocalDate deliverDate, BigDecimal weight, String sourceDocNo, String productionPlanNo, String salesOrderNo, String remark, BigDecimal allowedOverReceiptPct, List<SourceRequestDoc> sourceRequests) {
        this.id = id;
        this.lineNo = lineNo;
        this.goodsId = goodsId;
        this.goodsCodeSnapshot = goodsCodeSnapshot;
        this.goodsNameSnapshot = goodsNameSnapshot;
        this.goodsSnapshotSource = goodsSnapshotSource;
        this.goodsSnapshotLockedAt = goodsSnapshotLockedAt;
        this.colorId = colorId;
        this.unitId = unitId;
        this.unitRate = unitRate;
        this.qty = qty;
        this.price = price;
        this.amountOriginal = amountOriginal;
        this.amountLocal = amountLocal;
        this.receivedQty = receivedQty;
        this.returnedQty = returnedQty;
        this.giftQty = giftQty;
        this.requestItemId = requestItemId;
        this.deliverDate = deliverDate;
        this.weight = weight;
        this.sourceDocNo = sourceDocNo;
        this.productionPlanNo = productionPlanNo;
        this.salesOrderNo = salesOrderNo;
        this.remark = remark;
        this.allowedOverReceiptPct = allowedOverReceiptPct;
        this.sourceRequests = sourceRequests;
    }
    public String getGiftQtyExact(){return com.uten.imp.common.util.DecimalText.of(giftQty);}
    public String getUnitRateExact(){return com.uten.imp.common.util.DecimalText.of(unitRate);}
    public String getReceivedQtyExact(){return com.uten.imp.common.util.DecimalText.of(receivedQty);}
    public String getReturnedQtyExact(){return com.uten.imp.common.util.DecimalText.of(returnedQty);}
    public String getPhysicalQtyExact(){return com.uten.imp.common.finance.ProcurementQuantities.physicalText(quantitySemantics,qty,giftQty);}
    public String getGiftReceivedQtyExact(){return com.uten.imp.common.util.DecimalText.of(giftReceivedQty);}
    public String getGiftReturnedQtyExact(){return com.uten.imp.common.util.DecimalText.of(giftReturnedQty);}
    public String getRemainingGiftQtyExact(){return com.uten.imp.common.util.DecimalText.of(remainingGiftQty);}

    private UUID id;
    private Integer lineNo;
    private UUID goodsId;
    private String goodsCodeSnapshot;
    private String goodsNameSnapshot;
    private String goodsSnapshotSource;
    private OffsetDateTime goodsSnapshotLockedAt;
    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;
    @lombok.Getter(onMethod_ = @Override) private BigDecimal qty;
    @lombok.Getter(onMethod_ = @Override) private BigDecimal price;
    @lombok.Getter(onMethod_ = @Override) private BigDecimal amountOriginal;
    @lombok.Getter(onMethod_ = @Override) private BigDecimal amountLocal;
    private BigDecimal receivedQty;
    private BigDecimal returnedQty;
    private BigDecimal giftQty;
    private UUID requestItemId;
    private LocalDate deliverDate;
    private BigDecimal weight;
    private String sourceDocNo;
    private String productionPlanNo;
    private String salesOrderNo;
    private String remark;
    /** 本行允许超收百分比(ADR-144); 空 = 0。不是价格, 不随价格脱敏。 */
    private BigDecimal allowedOverReceiptPct;
    /**
     * 全部来源申请（V463 合并行多来源；稳定顺序与 sources.line_no 一致）：
     * 申请明细 id + 申请单 id（跳详情用）+ 申请单号。单来源行同样返回一条。
     */
    private List<SourceRequestDoc> sourceRequests;

    /** 订货行的来源申请引用（合并行多来源展示/编辑回显/跳转）。 */
    public record SourceRequestDoc(
            UUID requestItemId, UUID requestId, String billNo) {}
}
