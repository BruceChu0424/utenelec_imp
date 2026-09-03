package com.uten.imp.features.purchase.order.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

@Getter
@AllArgsConstructor
public class OrderItemDto {
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
    private BigDecimal qty;
    private BigDecimal price;
    private BigDecimal amountOriginal;
    private BigDecimal amountLocal;
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
    /**
     * 全部来源申请（V463 合并行多来源；稳定顺序与 sources.line_no 一致）：
     * 申请明细 id + 申请单 id（跳详情用）+ 申请单号。单来源行同样返回一条。
     */
    private List<SourceRequestDoc> sourceRequests;

    /** 订货行的来源申请引用（合并行多来源展示/编辑回显/跳转）。 */
    public record SourceRequestDoc(
            UUID requestItemId, UUID requestId, String billNo) {}
}
