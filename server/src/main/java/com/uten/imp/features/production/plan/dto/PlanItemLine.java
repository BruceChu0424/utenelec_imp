package com.uten.imp.features.production.plan.dto;

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
public class PlanItemLine extends com.uten.imp.common.platformcolumns.PlatformColumnLineInput {
    private Integer lineNo;

    /**
     * 编辑草稿时这一行载入自哪条已存计划行(该行 id)；新增行为空。
     * 服务端只凭它认「同一行」，决定允许超产比例是否沿用原来源(ADR-129 §2.10)。
     */
    private UUID sourceItemId;

    /**
     * 用户可选的业务产品编号；留空时由服务端在计划号下原子分配。
     * 关系身份始终是计划行 UUID，编号只用于展示、搜索和打印。
     */
    private String productNo;

    @NotNull
    private UUID goodsId;
    private UUID colorId;
    private UUID mgoodsId;
    private UUID unitId;
    private BigDecimal unitRate;

    /** 关联销售订单明细（可选，销售模块上线后才会有值）。 */
    private UUID salesOrderItemId;
    private String salesOrderNo;
    private String clientName;
    private String clientNo;

    // 数量族（12，全可编辑透传；触发器重算本期后置）
    private BigDecimal oqty;
    @NotNull
    private BigDecimal qty;
    /**
     * Initial allowance approved together with this plan (ADR-129 §2.10)：空 = 按货品默认填写(不记忆)；
     * 填了 = 人确认过的比例(会记成货品下次的默认)。编辑草稿时同一行(sourceItemId 且同一货品)：
     * 空着而原行是系统默认的、或填的与原行相同的，沿用原来的比例与来源，不算新的确认。
     */
    @jakarta.validation.constraints.DecimalMin("0")
    @jakarta.validation.constraints.Digits(integer = 3, fraction = 6)
    private BigDecimal allowedOverproductionRate;
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
