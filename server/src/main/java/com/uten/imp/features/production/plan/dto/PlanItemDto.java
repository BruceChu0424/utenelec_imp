package com.uten.imp.features.production.plan.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 生产计划明细 DTO（含 12 个数量族，全保留；本期不重算，原样保触发器游标累计量）。
 *
 * <p>数量族语义见 {@link com.uten.imp.features.production.plan.ProductionPlanItem}。
 */
@Getter
@AllArgsConstructor
public class PlanItemDto {
    private UUID id;
    private Integer lineNo;
    private String productNo;
    private UUID goodsId;
    private UUID colorId;
    private UUID mgoodsId;
    private UUID unitId;
    private BigDecimal unitRate;
    private UUID salesOrderItemId;
    private String salesOrderNo;
    private String clientName;
    private String clientNo;
    // 数量族（12）
    private BigDecimal oqty;
    private BigDecimal qty;
    private BigDecimal lqty;
    private BigDecimal iqty;
    private BigDecimal fqty;
    private BigDecimal rqty;
    private BigDecimal bqty;
    private BigDecimal tqty;
    private BigDecimal paqty;
    private BigDecimal isrqty;
    private BigDecimal cpqty;
    private BigDecimal poqty;
    private BigDecimal piqty;
    // 日期
    private LocalDate orderDate;
    private LocalDate outboundDate;
    private LocalDate planBeginDate;
    private LocalDate planEndDate;
    // 重量
    private BigDecimal finishedWeight;
    private BigDecimal inboundWeight;
    // 状态/工序
    private Short lstatus;
    private Short cstatus;
    private Integer stepLegacyId;
    // 领域字典
    private Integer veilLegacyId;
    private Integer assTeamLegacyId;
    private String fittings;
    // 辅助
    private String requestNote;
    private String customerModel;
    private BigDecimal discount;
    private String labelNo;
    private String planAppNo;
    private String sourceDocNo;
    private String remark;
}
