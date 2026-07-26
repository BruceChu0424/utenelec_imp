package com.uten.imp.features.production.plan.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 生产计划明细保存行。
 *
 * <p><b>仅核心字段可编辑</b>（货品/颜色/单位/数量族/日期/重量/备注/辅助文本）。
 * 累计量（iqty/fqty/rqty/bqty/tqty/paqty/isrqty/poqty/piqty 由下游单据回写）录入页通常仅展示不可编辑，
 * 但 SaveRequest 透传以兼容老库"保存即生效"的全字段编辑习惯（design §4.1）。
 */
@Getter
@Setter
public class PlanItemLine {
    private Integer lineNo;

    /** ProductNo 业务主键（同表 UNIQUE）。 */
    @NotBlank
    private String productNo;

    @NotNull
    private UUID goodsId;
    private UUID colorId;
    private UUID mgoodsId;
    private UUID unitId;
    private BigDecimal unitRate;

    /** 关联销售订单明细（可选，V51 销售模块上线后才会有值）。 */
    private UUID salesOrderItemId;
    private String salesOrderNo;
    private String clientName;
    private String clientNo;

    // 数量族（12，全可编辑透传；触发器重算本期后置）
    private BigDecimal oqty;
    @NotNull
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
