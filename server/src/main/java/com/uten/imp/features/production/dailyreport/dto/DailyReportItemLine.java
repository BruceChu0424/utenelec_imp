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
}
