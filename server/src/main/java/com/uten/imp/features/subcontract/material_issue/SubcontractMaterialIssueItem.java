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
import java.util.UUID;

/**
 * 委外发料明细。源 E_SOutItem；子件维度。
 *
 * <p>累计量字段（2 个）由下游单据审核回写：
 * <ul>
 *   <li>{@code returned_qty} ← 材料退货单审核（E_SWithDraw 回写）</li>
 *   <li>{@code wasted_qty} ← 损耗单审核（E_SWaste 回写，<b>新库补全老库缺失链路</b>，design doc 22 §六）</li>
 * </ul>
 * {@code order_item_id} 真FK 挂订货明细，审核时回写订货 issued_qty；
 * {@code parent_goods_id/parent_color_id} 反查父件成品（BOM 视图）。
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

    /** 关联订货明细（E_SOutItem.EOrderID）。审核时回写 subcontract_order_items.issued_qty。 */
    @Column(name = "order_item_id")
    private UUID orderItemId;

    private Integer lineNo;

    @Column(name = "goods_id", nullable = false)
    private UUID goodsId;                // 子件（发料货品）

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

    @Column(name = "parent_goods_id")
    private UUID parentGoodsId;          // MGoodsID 父件货品

    @Column(name = "parent_color_id")
    private UUID parentColorId;          // MColorID 父件颜色

    @Column(name = "weight", precision = 18, scale = 4)
    private BigDecimal weight;

    @Column(name = "source_doc_no")
    private String sourceDocNo;

    private String remark;
}
