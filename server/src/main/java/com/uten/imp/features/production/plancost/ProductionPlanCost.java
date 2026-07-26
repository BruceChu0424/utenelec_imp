package com.uten.imp.features.production.plancost;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.Instant;
import java.time.LocalDate;
import java.util.UUID;

/**
 * 生产计划成本 / BOM 展开表（生产管理 · 源 F_PlanCostItem，1,359,875 行 · 按年 RANGE 分区）。
 *
 * <p><b>⚠ FK 陷阱</b>（design §3.3）：{@link #billItemId} → {@code production_plan_items.id}
 * （老库 F_PlanCostItem.BillID → F_PlanItem.ID，<b>不是</b> F_Plan.ID！）。
 * 本 Entity 留 UUID {@link #billItemId} <b>不建</b> {@code @ManyToOne}：跨分区 FK 复杂，仅索引 + 应用层保证。
 *
 * <p><b>分区表 PK = (id, bill_date)</b>，但 JPA 单 {@code @Id} 在 {@link #id} 即可查询
 * （{@link #billDate} 作为普通 {@code @Column}）；写入受限——<b>本期只读保数据</b>所以无妨（design §3.3）。
 *
 * <p>数量族（16 个 NUMERIC(18,4)，全保留触发器游标回写的累计量）：
 * {@link #qty} QTY 总需量、{@link #dqty} DQTY 单套用量、{@link #pqty} PQTY 计划数量、
 * {@link #lqty} LQTY 排产占用、{@link #slqty} SLQTY 本次用量（计算列）、{@link #rqty} RQTY 入库、
 * {@link #orderQty} OrderQTY 已订货、{@link #inQty} INQTY 已收货、{@link #pdrawQty} PDrawQTY 已领料、
 * {@link #owdrawQty} OWDrawQTY 已退料、{@link #pwdrawQty} PWDrawQTY 采购退货、
 * {@link #eoQty} EOQTY 委外订货、{@link #eiQty} EIQTY 委外缴回、{@link #ewQty} EWQTY 委外退回、
 * {@link #mqty} MQTY 多订量、{@link #paQty} PAQTY 已排产。
 *
 * <p><b>【本期后置】</b>所有触发器重算逻辑均不实现（design §4.2）：
 * <ul>
 *   <li>BOM 自动展开（TRI_F_PlanCostItem_Insert）—— 归未来 BOM/MRP 模块</li>
 *   <li>数量级联重算（TRI_F_PlanCostItem_Update：父.QTY×DQTY → 子）—— 归未来成本/MRP 模块</li>
 *   <li>Level 计算（TRI_F_PlanCostItem_Level ≤30）—— 迁移原样保 Level，新建走应用层校验</li>
 *   <li>MRP 需购量公式（View_F_PlanCostItem 三分支 CASE）—— 归未来 MRP 模块</li>
 * </ul>
 *
 * <p>多值溯源 9 个 varchar 已在 DDL 合并为 {@link #sourceDocNo}（前缀化保留类型可识别）。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "production_plan_costs")
public class ProductionPlanCost {

    /**
     * 单 {@code @Id}（分区表 PK 实为 (id, bill_date)）。Hibernate 单 @Id 对查询无碍；
     * 本期只读不写入（design §3.3）。
     */
    @Id
    @Column(name = "id", nullable = false, updatable = false)
    private UUID id;

    /** F_PlanCostItem.ID（老库 IDENTITY；分区表 UNIQUE 含 bill_date）。 */
    @Column(name = "legacy_id", nullable = false)
    private Integer legacyId;

    /**
     * ⚠ BillID → production_plan_items.id（不是 plans.id！）。
     * 老库 fkeys.txt：F_PlanCostItem.BillID → F_PlanItem.ID（成本展开行挂在计划明细行下）。
     */
    @Column(name = "bill_item_id", nullable = false)
    private UUID billItemId;

    /** 反冗余（JOIN 三级链取，裁剪 + 报表免 JOIN 主表）。 */
    @Column(name = "bill_no", nullable = false)
    private String billNo;

    /** ⭐ 反冗余自 F_Plan.BillDate，分区键（NOT NULL）。 */
    @Column(name = "bill_date", nullable = false)
    private LocalDate billDate;

    /** ParentID 自引用（UUID 映射后回填；不建 FK：分区表 PK 含 bill_date，自引用需含分区键）。 */
    @Column(name = "parent_id")
    private UUID parentId;

    /** 老库 ParentID（0=顶层），迁移留底便于校验。 */
    @Column(name = "parent_legacy_id", nullable = false)
    private Integer parentLegacyId = 0;

    /** Level BOM 层级（TRI_F_PlanCostItem_Level ≤30，原样保）。 */
    @Column(name = "level", nullable = false)
    private Short level = 0;

    /** Class 0=物料 / ≠0=工序或费用。 */
    @Column(name = "node_class", nullable = false)
    private Short nodeClass = 0;

    /** GoodsID 当前节点。 */
    @Column(name = "goods_id", nullable = false)
    private UUID goodsId;

    @Column(name = "color_id")
    private UUID colorId;

    /** MGoodsID 顶层成品（冗余便于按成品汇总）。 */
    @Column(name = "master_goods_id")
    private UUID masterGoodsId;

    @Column(name = "master_color_id")
    private UUID masterColorId;

    /** SOCItemID → sales_order_cost_items.id（V51；跨模块不建 REFERENCES）。 */
    @Column(name = "sales_order_cost_item_id")
    private UUID salesOrderCostItemId;

    // ===== 数量族（16 个，全保留；本期不重算） =====
    @Column(name = "qty", precision = 18, scale = 4)
    private BigDecimal qty = BigDecimal.ZERO;
    @Column(name = "dqty", precision = 18, scale = 4)
    private BigDecimal dqty = BigDecimal.ZERO;
    @Column(name = "pqty", precision = 18, scale = 4)
    private BigDecimal pqty = BigDecimal.ZERO;
    @Column(name = "lqty", precision = 18, scale = 4)
    private BigDecimal lqty = BigDecimal.ZERO;
    @Column(name = "slqty", precision = 18, scale = 4)
    private BigDecimal slqty = BigDecimal.ZERO;
    @Column(name = "rqty", precision = 18, scale = 4)
    private BigDecimal rqty = BigDecimal.ZERO;
    @Column(name = "order_qty", precision = 18, scale = 4)
    private BigDecimal orderQty = BigDecimal.ZERO;
    @Column(name = "in_qty", precision = 18, scale = 4)
    private BigDecimal inQty = BigDecimal.ZERO;
    @Column(name = "pdraw_qty", precision = 18, scale = 4)
    private BigDecimal pdrawQty = BigDecimal.ZERO;
    @Column(name = "owdraw_qty", precision = 18, scale = 4)
    private BigDecimal owdrawQty = BigDecimal.ZERO;
    @Column(name = "pwdraw_qty", precision = 18, scale = 4)
    private BigDecimal pwdrawQty = BigDecimal.ZERO;
    @Column(name = "eo_qty", precision = 18, scale = 4)
    private BigDecimal eoQty = BigDecimal.ZERO;
    @Column(name = "ei_qty", precision = 18, scale = 4)
    private BigDecimal eiQty = BigDecimal.ZERO;
    @Column(name = "ew_qty", precision = 18, scale = 4)
    private BigDecimal ewQty = BigDecimal.ZERO;
    @Column(name = "mqty", precision = 18, scale = 4)
    private BigDecimal mqty = BigDecimal.ZERO;
    @Column(name = "pa_qty", precision = 18, scale = 4)
    private BigDecimal paQty = BigDecimal.ZERO;

    // ===== 金额 =====
    @Column(name = "price", precision = 18, scale = 4)
    private BigDecimal price;

    /** Total = QTY × Price。 */
    @Column(name = "total", precision = 18, scale = 4)
    private BigDecimal total;

    /** VendID 建议供应。 */
    @Column(name = "supplier_id")
    private UUID supplierId;

    /** AssTeamID → B_AssTeam（主档未建，留 legacy int）。 */
    @Column(name = "ass_team_legacy_id")
    private Integer assTeamLegacyId;

    /**
     * 多值溯源号 9 个 varchar 合并文本（前缀化保留类型可识别）：
     * {@code 'PO:xxx | PI:yyy | PW:zzz | PD:aaa | OW:bbb | EO:ccc | EI:ddd | EW:eee | PA:fff'}。
     */
    @Column(name = "source_doc_no")
    private String sourceDocNo;

    /** LStatus 行状态（影响 View_F_PlanCostItem 需购量 CASE 分支）。 */
    @Column(name = "lstatus")
    private Short lstatus;

    /** Summary 摘要。 */
    private String summary;

    // ===== 审计（分区明细省 created_by/updated_by，见 V55） =====
    @Column(name = "created_at", updatable = false)
    private Instant createdAt;

    @Column(name = "updated_at")
    private Instant updatedAt;

    @Column(name = "is_deleted")
    private Boolean isDeleted = false;
}
