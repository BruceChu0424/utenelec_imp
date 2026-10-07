package com.uten.imp.features.production.dailyreport.dto;

import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** 生产日报明细保存行。 */
@Getter
@Setter
public class DailyReportItemLine extends com.uten.imp.common.platformcolumns.PlatformColumnLineInput {
    /** Server-authored output ownership; never accepted from a client. */
    @com.fasterxml.jackson.annotation.JsonIgnore private UUID outputBatchId;
    @com.fasterxml.jackson.annotation.JsonIgnore private BigDecimal outputBatchQty;
    @com.fasterxml.jackson.annotation.JsonIgnore private boolean publicOutput;
    @com.fasterxml.jackson.annotation.JsonIgnore private boolean actualSurplus;
    @com.fasterxml.jackson.annotation.JsonIgnore private boolean overLimit;
    /** 已经产出的超限事实说明；不能通过填写原因获得库存放行。 */
    @jakarta.validation.constraints.Size(max = 500)
    private String overLimitReason;
    /** Approved, exact same-batch additional-plan proof; never a free-form plan link. */
    private UUID supplementProofId;
    @com.fasterxml.jackson.annotation.JsonIgnore private Integer inputLineIndex;
    private Integer lineNo;
    @NotNull private UUID goodsId;
    private UUID colorId;
    private UUID unitId;
    private BigDecimal unitRate;
    @NotNull private BigDecimal qty;
    /** 不良数(ADR-129)：只记录，不改良品数；不传或为空按 0。 */
    private BigDecimal defectQty;
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
     * 本行实际产量的去向分配(V736/ADR-127)：逐个转给上层工单多少、送入仓库多少，合计等于本行实际产量。
     * 不传或为空 = 整行送入仓库。去向只从这里读，客户端不再传单个去向或单个接收需求。
     */
    @jakarta.validation.Valid
    @jakarta.validation.constraints.Size(max = com.uten.imp.common.validation.RequestLimits.DAILY_REPORT_LINE_DESTINATIONS)
    private List<DailyReportOutputAllocationLine> allocations;

    /**
     * 拆分后单条明细的产出去向(V584)：WAREHOUSE 或 WORKSHOP。由服务端按 {@link #allocations} 拆出，
     * 从不接受客户端传入。
     */
    @com.fasterxml.jackson.annotation.JsonIgnore private String destination;

    /** 拆分后转送明细的接收需求(V585)；只由服务端按 {@link #allocations} 写入。 */
    @com.fasterxml.jackson.annotation.JsonIgnore private UUID directTransferDemandId;

    /** 拆分后送仓明细为什么没转下一道工序(V736 原因码)；只由服务端写入。 */
    @com.fasterxml.jackson.annotation.JsonIgnore private String outputRouteReason;

    /**
     * 部署 V736 之前打开的旧页面仍按「行上单个去向」提交(destination / directTransferDemandId)。
     * 这两个 JSON 名只收不发、只用来认出旧页面：保存入口据此整单拒收并请用户刷新
     * (ADR-127 §7)，绝不按新口径把旧页面想转下一道工序的量悄悄送入仓库。
     * 与上面服务端自用的同名字段互不相干(那两个字段不从 JSON 读取)。
     */
    @com.fasterxml.jackson.annotation.JsonIgnore
    @Getter(lombok.AccessLevel.NONE) @Setter(lombok.AccessLevel.NONE)
    private boolean staleRouteShape;

    @com.fasterxml.jackson.annotation.JsonSetter("destination")
    private void readStaleDestination(String value) {
        if (value != null && !value.isBlank()) staleRouteShape = true;
    }

    @com.fasterxml.jackson.annotation.JsonSetter("directTransferDemandId")
    private void readStaleDirectTransferDemandId(UUID value) {
        if (value != null) staleRouteShape = true;
    }

    /** 请求 JSON 是否带着旧页面的单去向字段(见上)。 */
    public boolean carriesStaleRouteShape() {
        return staleRouteShape;
    }
}
