package com.uten.imp.features.subcontract.material_return;

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
 * 委外材料退明细。源 E_SWithDrawItem；子件维度。
 *
 * <p>来源链骨干：
 * <ul>
 *   <li>{@code material_issue_item_id} → 发料明细（EOutID）；审核时回写
 *       {@code subcontract_material_issue_items.returned_qty += qty}</li>
 *   <li>{@code order_item_id} → 订货明细（EOrderID）；只用于核验发料的
 *       二跳来源，不再回写成品行累计量</li>
 * </ul>
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "subcontract_material_return_items")
public class SubcontractMaterialReturnItem extends BaseEntity {

    private Integer legacyId;

    @Column(name = "bill_no")
    private String billNo;

    @Column(name = "bill_date")
    private LocalDate billDate;

    @Column(name = "material_return_id", nullable = false)
    private UUID materialReturnId;

    /** 关联发料明细（E_SWithDrawItem.EOutID）。审核时回写 material_issue_items.returned_qty。 */
    @Column(name = "material_issue_item_id")
    private UUID materialIssueItemId;

    /** 关联订货明细（EOrderID）；用于来源核验，不回写成品行累计量。 */
    @Column(name = "order_item_id")
    private UUID orderItemId;

    private Integer lineNo;

    @Column(name = "goods_id", nullable = false)
    private UUID goodsId;

    @Column(name = "color_id")
    private UUID colorId;

    @Column(name = "unit_id")
    private UUID unitId;

    @Column(name = "unit_rate", precision = 18, scale = 6)
    private BigDecimal unitRate;

    @Column(name = "qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal qty;

    /** 无 Price；空。 */
    @Column(name = "price", precision = 18, scale = 4)
    private BigDecimal price;

    @Column(name = "amount_original", precision = 18, scale = 4)
    private BigDecimal amountOriginal;

    @Column(name = "amount_local", precision = 18, scale = 4)
    private BigDecimal amountLocal;

    @Column(name = "parent_goods_id")
    private UUID parentGoodsId;

    @Column(name = "parent_color_id")
    private UUID parentColorId;

    @Column(name = "weight", precision = 18, scale = 4)
    private BigDecimal weight;

    @Column(name = "source_doc_no")
    private String sourceDocNo;

    /** 围数（E_SWithDrawItem.KQTY）。 */
    @Column(name = "girth_qty", precision = 18, scale = 4)
    private BigDecimal girthQty;

    /** 材料出仓单号（E_SWithDrawItem.EOutNo，多值 varchar 原样）。 */
    @Column(name = "issue_no")
    private String issueNo;

    /** 委外订货单号（E_SWithDrawItem.EOrderNo，多值 varchar 原样）。 */
    @Column(name = "order_no")
    private String orderNo;

    private String remark;
}
