package com.uten.imp.features.subcontract.material_issue;

import com.uten.imp.common.domain.BaseEntity;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 委外发料明细。源 E_SOutItem；子件维度。
 *
 * <p>累计量字段（2 个）由下游单据审核回写：
 * <ul>
 *   <li>{@code returned_qty} ← 材料退货单审核（E_SWithDraw 回写）</li>
 *   <li>{@code wasted_qty} ← 损耗单审核（E_SWaste 回写，<b>新库补全老库缺失链路</b>，design doc 22 §六）</li>
 * </ul>
 * {@code order_item_id} 真FK 挂历史来源订货明细，但不再把子件数量回写到
 * 成品行 {@code issued_qty}；{@code parent_goods_id/parent_color_id}
 * 仅用于历史来源追溯，不能替代冻结的 BOM 版本。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "subcontract_material_issue_items")
public class SubcontractMaterialIssueItem extends BaseEntity {

    private Integer legacyId;

    @Column(name = "bill_no")
    private String billNo;

    @Column(name = "bill_date")
    private LocalDate billDate;

    @Column(name = "issue_id", nullable = false)
    private UUID issueId;

    /** 关联订货明细（E_SOutItem.EOrderID）；仅用于来源追溯，不回写成品行累计量。 */
    @Column(name = "order_item_id")
    private UUID orderItemId;

    /** 来源发料计划行（V304）；计划生成的出仓单必填，审核/红冲回写 plan_items.issued_qty。 */
    @Column(name = "plan_item_id")
    private UUID planItemId;

    private Integer lineNo;

    @Column(name = "goods_id", nullable = false)
    private UUID goodsId;                // 子件（发料货品）

    @Column(name = "goods_code_snapshot") private String goodsCodeSnapshot;
    @Column(name = "goods_name_snapshot") private String goodsNameSnapshot;
    @Column(name = "goods_snapshot_source", nullable = false) private String goodsSnapshotSource;
    @Column(name = "goods_snapshot_locked_at") private OffsetDateTime goodsSnapshotLockedAt;

    @Column(name = "color_id")
    private UUID colorId;

    @Column(name = "unit_id")
    private UUID unitId;

    @Column(name = "unit_rate", precision = 18, scale = 6)
    private BigDecimal unitRate;

    @Column(name = "qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal qty;              // 发料量

    /** 无 Price；空（材料按成本发出）。 */
    @Column(name = "price", precision = 18, scale = 4)
    private BigDecimal price;

    /** 空（审核 Service 按成本重算）。 */
    @Column(name = "amount_original", precision = 18, scale = 4)
    private BigDecimal amountOriginal;

    @Column(name = "amount_local", precision = 18, scale = 4)
    private BigDecimal amountLocal;

    /** 已材料退（E_SWithDraw 审核回写）。 */
    @Column(name = "returned_qty", precision = 18, scale = 4)
    private BigDecimal returnedQty = BigDecimal.ZERO;

    /** 已损耗（E_SWaste 审核回写 · 新库补全老库缺失）。 */
    @Column(name = "wasted_qty", precision = 18, scale = 4)
    private BigDecimal wastedQty = BigDecimal.ZERO;

    // ---- 委外物料守恒子账（at_supplier / consumed / frozen / supplier_ending）----

    /** 已发至供应商处的子件量（审核置为发料量；单据单位）。 */
    @Column(name = "at_supplier_qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal atSupplierQty = BigDecimal.ZERO;

    /** 回厂进仓按冻结 BOM 消费的子件量（单据单位）。 */
    @Column(name = "consumed_qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal consumedQty = BigDecimal.ZERO;

    /** 审核时冻结的 BOM 版本：每单位父件耗用本子件量。 */
    @Column(name = "frozen_unit_qty", precision = 18, scale = 6)
    private BigDecimal frozenUnitQty;

    /** 供应商期末结存（生成列，只读）。 */
    @Column(name = "supplier_ending", insertable = false, updatable = false, precision = 18, scale = 4)
    private BigDecimal supplierEnding;

    @Column(name = "parent_goods_id")
    private UUID parentGoodsId;          // MGoodsID 父件货品

    @Column(name = "parent_goods_code_snapshot") private String parentGoodsCodeSnapshot;
    @Column(name = "parent_goods_name_snapshot") private String parentGoodsNameSnapshot;
    @Column(name = "parent_goods_snapshot_source") private String parentGoodsSnapshotSource;
    @Column(name = "parent_goods_snapshot_locked_at") private OffsetDateTime parentGoodsSnapshotLockedAt;

    @Column(name = "parent_color_id")
    private UUID parentColorId;          // MColorID 父件颜色

    @Column(name = "weight", precision = 18, scale = 4)
    private BigDecimal weight;

    @Column(name = "source_doc_no")
    private String sourceDocNo;

    /** 胶箱数量（老库无源 → 留空）。 */
    @Column(name = "box_qty", precision = 18, scale = 4)
    private BigDecimal boxQty;

    /** 材料退货单号（E_SOutItem.WDrawNo，多值 varchar 原样）。 */
    @Column(name = "return_no")
    private String returnNo;

    /** 委外订货单号（E_SOutItem.EOrderNo，多值 varchar 原样）。 */
    @Column(name = "order_no")
    private String orderNo;

    private String remark;
}
