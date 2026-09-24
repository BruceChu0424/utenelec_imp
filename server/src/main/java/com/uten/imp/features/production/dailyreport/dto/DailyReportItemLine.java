package com.uten.imp.features.production.dailyreport.dto;

import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** 生产日报明细保存行。 */
@Getter
@Setter
public class DailyReportItemLine {
    /** Server-authored output ownership; never accepted from a client. */
    @com.fasterxml.jackson.annotation.JsonIgnore private UUID outputBatchId;
    @com.fasterxml.jackson.annotation.JsonIgnore private BigDecimal outputBatchQty;
    @com.fasterxml.jackson.annotation.JsonIgnore private boolean publicOutput;
    @com.fasterxml.jackson.annotation.JsonIgnore private boolean actualSurplus;
    /** Approved, exact same-batch additional-plan proof; never a free-form plan link. */
    private UUID supplementProofId;
    @com.fasterxml.jackson.annotation.JsonIgnore private Integer inputLineIndex;
    private Integer lineNo;
    @NotNull private UUID goodsId;
    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;
    @NotNull private BigDecimal qty;
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
    /** 报工完结标记：该计划行报工结束；合格不足自动补产。 */
    private Boolean isFinal;
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

    /**
     * 产出去向(V584)：WAREHOUSE(默认，送仓库)或 WORKSHOP(班组自检后直送同车间上层工单)。
     * 不传按 WAREHOUSE 处理，老客户端行为不变。
     */
    private String destination;

    /** 直送的接收需求(V585)：destination=WORKSHOP 时必填，服务端再校验同车间同货品。 */
    private UUID directTransferDemandId;
}
