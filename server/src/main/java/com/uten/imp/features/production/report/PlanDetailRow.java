package com.uten.imp.features.production.report;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 生产计划明细报表行（design §6.2）。
 *
 * <p>源 production_plan_items JOIN goods/colors/units（前端解析名称）。
 * 参数化分页查询，<b>不</b>走物化视图（明细实时性要求高）。
 */
@Getter
@AllArgsConstructor
public class PlanDetailRow {
    private UUID id;
    private String billNo;
    private LocalDate billDate;
    private UUID planId;
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
    private LocalDate deliveryDate;
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
    private Short planStatus;
    private boolean planClosed;
    private Integer legacyId;
    private String remark;
}
