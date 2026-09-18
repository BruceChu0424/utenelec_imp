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
}
