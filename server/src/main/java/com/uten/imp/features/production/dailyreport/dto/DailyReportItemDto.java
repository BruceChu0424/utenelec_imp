package com.uten.imp.features.production.dailyreport.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 生产日报明细 DTO。 */
@Getter
@AllArgsConstructor
public class DailyReportItemDto {
    private UUID id;
    private Integer lineNo;
    private UUID goodsId;
    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;
    private BigDecimal qty;
    private BigDecimal price;
    private BigDecimal total;
    private BigDecimal stotal;
    private UUID salesOrderItemId;
    private String salesOrderNo;
    private UUID planItemId;
    private UUID executionSegmentId;
    private UUID executionSegmentSalesAllocationId;
    private UUID fqcRecoveryAuthorizationId;
    private String planNo;
    private String outboundNo;
    private BigDecimal outboundQty;
    private BigDecimal orderQty;
    private Integer stepLegacyId;
    private LocalDate orderDate;
    private BigDecimal boxes;
    private BigDecimal perBoxQty;
    private BigDecimal weight;
    private String clientName;
    private String sourceDocNo;
    private String remark;
    private Boolean isFinal;
    /** 产出去向(V584)：WAREHOUSE / WORKSHOP。 */
    private String destination;
    /** 直送的接收需求(V585)；WAREHOUSE 行为空。 */
    private UUID directTransferDemandId;
    /** 直送接收方的可读标识(V595)：父件产品名 编号 · 工单号；详情页「转给工单」列用，非直送行为空。 */
    private String directTransferTargetLabel;
    /** Exact plan identity for reloading a draft's material rows. */
    @lombok.Setter
    private UUID planId;
    /** Remaining task target after approved ordinary reports; drafts are not completion. */
    @lombok.Setter
    private BigDecimal remainingPlanQty;
    /**
     * 货品身份三列随单下发(名称/编号/颜色)与单位：页面不再自己查字典解析。
     *
     * <p>客户端字典缓存会随连接恢复或权限快照变化整体清空，那时逐格解析出来的名称
     * 会集体变成「—」且不会自愈(2026-09-21 生产日报审核超时实测)。同一响应里的
     * 制单员与「转给工单」本来就由服务端解析，这里补齐口径；跨模块读货品字典还要
     * goods:view/color:view/unit:view，随单下发一并解除这层权限耦合。
     */
    private String goodsName;
    private String goodsCode;
    private String colorName;
    private String unitName;
    @lombok.Setter private UUID outputBatchId;
    @lombok.Setter private BigDecimal outputBatchQty;
    @lombok.Setter private boolean publicOutput;
    @lombok.Setter private boolean actualSurplus;
    @lombok.Setter private boolean allowActualOverproduction;
    @lombok.Setter private UUID supplementProofId;
    @lombok.Setter private UUID outputSourceExecutionSegmentId;
    @lombok.Setter private UUID outputSourcePlanItemId;
    @lombok.Setter private UUID outputSourcePlanId;
    @lombok.Setter private UUID outputSourceSalesAllocationId;
    @lombok.Setter private UUID outputSourceSalesOrderItemId;
    @lombok.Setter private BigDecimal allowedOverproductionRate;
    @lombok.Setter private BigDecimal overproductionLimitQty;
    @lombok.Setter private BigDecimal remainingActualSurplusQty;

    public String getOutputKind() {
        return actualSurplus ? "ACTUAL_SURPLUS" : publicOutput ? "PLANNED_PUBLIC" : "PLANNED";
    }
}
