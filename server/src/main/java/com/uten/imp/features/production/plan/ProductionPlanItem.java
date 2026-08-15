package com.uten.imp.features.production.plan;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 生产计划明细（生产管理 · 源 F_PlanItem，73,388 行）。
 *
 * <p><b>⚠ legacy_id（= F_PlanItem.ID）被 {@code production_plan_costs.bill_item_id} 经它映射为 UUID</b>
 * （老库 fkeys.txt：F_PlanCostItem.BillID → F_PlanItem.ID，不是 F_Plan.ID！）。
 *
 * <p>数量族（12 个 NUMERIC(18,4)，全保留触发器游标回写的累计量）：
 * <ul>
 *   <li>{@link #oqty} OQTY 销售订货量；{@link #qty} QTY 本单排产数量（float→numeric）</li>
 *   <li>{@link #lqty} LQTY 本次用量（BOM 展开锁定）；{@link #iqty} IQTY 完工/进仓数量（仓库 O_ProductionItem 回写）</li>
 *   <li>{@link #fqty} FQTY 完工数量（工序回写）；{@link #rqty} RQTY 入库数量</li>
 *   <li>{@link #bqty} BQTY 在产数量（F_ProductItem 回写）；{@link #tqty} TQTY 开工数量（F_Transfer 回写）</li>
 *   <li>{@link #paqty} PAQTY 已排产量；{@link #isrqty} ISRQTY 已入库量；{@link #cpqty} CPQTY 应排数量</li>
 *   <li>{@link #poqty} POQTY 已订货（采购回写）；{@link #piqty} PIQTY 已收货（采购回写）</li>
 * </ul>
 *
 * <p><b>【本期后置】</b>所有触发器游标回写（TRI_F_PlanCostItem_Update 数量级联重算 / 审核回写
 * sales_order_items / 设 step_legacy_id / F_ProductingItem 产能填充）均不实现，原样保累计量。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "production_plan_items")
public class ProductionPlanItem extends BaseEntity {

    /** F_PlanItem.ID（⚠ 被 production_plan_costs.bill_item_id 引用）。 */
    private Integer legacyId;

    @Column(name = "bill_no")
    private String billNo;

    @Column(name = "bill_date")
    private LocalDate billDate;

    @Column(name = "plan_id", nullable = false)
    private UUID planId;

    private Integer lineNo;

    /** ProductNo 业务主键（IX_F_PlanItem 唯一）。 */
    @Column(name = "product_no", nullable = false)
    private String productNo;

    @Column(name = "goods_id", nullable = false)
    private UUID goodsId;

    @Column(name = "color_id")
    private UUID colorId;

    /** MGoodsID 替代/顶层货品。 */
    @Column(name = "mgoods_id")
    private UUID mgoodsId;

    @Column(name = "unit_id")
    private UUID unitId;

    @Column(name = "unit_rate", precision = 18, scale = 6)
    private BigDecimal unitRate;

    /** S_OrderID → sales_order_items.id（跨模块不建 REFERENCES，仅逻辑 FK + 索引）。 */
    @Column(name = "sales_order_item_id")
    private UUID salesOrderItemId;

    /** S_OrderNo（文本占位，老库软关联）。 */
    @Column(name = "sales_order_no")
    private String salesOrderNo;

    /** Client varchar(250) 客户名冗余。 */
    @Column(name = "client_name")
    private String clientName;

    /** ClientNo varchar(50) 客户号冗余。 */
    @Column(name = "client_no")
    private String clientNo;

    // ===== 数量族（12 个，全保留；本期不重算，原样保触发器游标累计量） =====
    @Column(name = "oqty", precision = 18, scale = 4)
    private BigDecimal oqty = BigDecimal.ZERO;
    @Column(name = "qty", precision = 18, scale = 4)
    private BigDecimal qty = BigDecimal.ZERO;
    @Column(name = "lqty", precision = 18, scale = 4)
    private BigDecimal lqty = BigDecimal.ZERO;
    @Column(name = "iqty", precision = 18, scale = 4)
    private BigDecimal iqty = BigDecimal.ZERO;
    @Column(name = "fqty", precision = 18, scale = 4)
    private BigDecimal fqty = BigDecimal.ZERO;
    @Column(name = "rqty", precision = 18, scale = 4)
    private BigDecimal rqty = BigDecimal.ZERO;
    @Column(name = "bqty", precision = 18, scale = 4)
    private BigDecimal bqty = BigDecimal.ZERO;
    @Column(name = "tqty", precision = 18, scale = 4)
    private BigDecimal tqty = BigDecimal.ZERO;
    @Column(name = "paqty", precision = 18, scale = 4)
    private BigDecimal paqty = BigDecimal.ZERO;
    @Column(name = "isrqty", precision = 18, scale = 4)
    private BigDecimal isrqty = BigDecimal.ZERO;
    @Column(name = "cpqty", precision = 18, scale = 4)
    private BigDecimal cpqty = BigDecimal.ZERO;
    @Column(name = "poqty", precision = 18, scale = 4)
    private BigDecimal poqty = BigDecimal.ZERO;
    @Column(name = "piqty", precision = 18, scale = 4)
    private BigDecimal piqty = BigDecimal.ZERO;

    // ===== 日期 =====
    /** OderDate 下订日期（老库拼写保留）。 */
    @Column(name = "order_date")
    private LocalDate orderDate;

    /** OutDate 交货日期。 */
    @Column(name = "outbound_date")
    private LocalDate outboundDate;

    /** PBeginDate 计划开工。 */
    @Column(name = "plan_begin_date")
    private LocalDate planBeginDate;

    /** PEndDate 计划完工。 */
    @Column(name = "plan_end_date")
    private LocalDate planEndDate;

    // ===== 重量（float→numeric） =====
    /** FWeight 完工重量。 */
    @Column(name = "finished_weight", precision = 18, scale = 4)
    private BigDecimal finishedWeight;

    /** IWeight 进仓重量。 */
    @Column(name = "inbound_weight", precision = 18, scale = 4)
    private BigDecimal inboundWeight;

    // ===== 状态/工序（多套并存，原样保留） =====
    /** LStatus 排产状态。 */
    @Column(name = "lstatus")
    private Short lstatus;

    /** CStatus 成本状态。 */
    @Column(name = "cstatus")
    private Short cstatus;

    /** StepID → B_Step（主档未建，留 legacy int）。 */
    @Column(name = "step_legacy_id")
    private Integer stepLegacyId;

    // ===== 领域字典（主档未建，留 legacy int + 文本） =====
    /** VeilID → B_Veil 面罩。 */
    @Column(name = "veil_legacy_id")
    private Integer veilLegacyId;

    /** AssTeamID → B_AssTeam 装配组。 */
    @Column(name = "ass_team_legacy_id")
    private Integer assTeamLegacyId;

    /** Fittings 配件（文本）。 */
    private String fittings;

    // ===== 辅助 =====
    /** Request 特殊要求。 */
    @Column(name = "request_note")
    private String requestNote;

    /** CNumber 客户型号。 */
    @Column(name = "customer_model")
    private String customerModel;

    @Column(name = "discount", precision = 18, scale = 4)
    private BigDecimal discount;

    /** LabelNo 标签号。 */
    @Column(name = "label_no")
    private String labelNo;

    /** PAppNo 排产单号。 */
    @Column(name = "plan_app_no")
    private String planAppNo;

    /**
     * 多值溯源合并文本（InNo/TranNo varchar(5000)）。
     * 格式：'IN:xxx | TRAN:yyy'，每字段 NULL/空跳过，保留前缀便于未来按类型回填真 FK。
     */
    @Column(name = "source_doc_no")
    private String sourceDocNo;

    private String remark;
}
