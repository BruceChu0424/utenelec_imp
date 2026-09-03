package com.uten.imp.features.subcontract.order.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/**
 * 委外订货明细返回 DTO。received/returned 是成品维度权威累计；
 * issued/materialReturned 为兼容旧客户端保留的 legacy 展示值，新业务不写。
 * 另含 applicationItemId。
 */
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
    private BigDecimal issuedQty;
    private BigDecimal materialReturnedQty;
    private UUID applicationItemId;
    private LocalDate deliverDate;
    private BigDecimal weight;
    private String sourceDocNo;
    private String remark;
    /**
     * 全部来源申请（V463 合并行多来源；稳定顺序与 sources.line_no 一致）：
     * 申请明细 id + 申请单 id（跳详情用）+ 申请单号。单来源行同样返回一条；
     * 手工行（无申请来源）为空。
     */
    private List<SourceApplicationDoc> sourceApplications;

    /** 订货行的来源委外申请引用（合并行多来源展示/编辑回显/跳转）。 */
    public record SourceApplicationDoc(
            UUID applicationItemId, UUID applicationId, String billNo) {}
}
