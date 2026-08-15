package com.uten.imp.features.subcontract.waste;

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
 * 委外损耗明细。源 E_SWasteItem。
 *
 * <p>{@code material_issue_item_id} 真FK（OutID）→ 发料明细；<b>★新库补全</b>：
 * 审核时回写 {@code subcontract_material_issue_items.wasted_qty += qty}
 * （老库 E_SWaste 仅写库存台账未回写发料累计，新库 Service 闭环，design doc 22 §六）。
 *
 * <p>特有字段（损耗业务）：
 * <ul>
 *   <li>{@code ending_qty}（FQTY 期末数量，损耗基准量）</li>
 *   <li>{@code standard_qty}（OQTY 标准/应损量；与 ending_qty 反向算盈亏）</li>
 *   <li>{@code waste_rate}（WRate 损耗率%）</li>
 *   <li>{@code cause}（损耗原因）</li>
 * </ul>
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "subcontract_waste_items")
public class SubcontractWasteItem extends BaseEntity {

    private Integer legacyId;

    @Column(name = "bill_no")
    private String billNo;

    @Column(name = "bill_date")
    private LocalDate billDate;

    @Column(name = "waste_id", nullable = false)
    private UUID wasteId;

    /** 关联发料明细（E_SWasteItem.OutID）。审核时回写 material_issue_items.wasted_qty（★新库补全）。 */
    @Column(name = "material_issue_item_id")
    private UUID materialIssueItemId;

    private Integer lineNo;

    @Column(name = "goods_id", nullable = false)
    private UUID goodsId;

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

    /** 实际损耗量。 */
    @Column(name = "qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal qty;

    /** FQTY 期末数量（损耗基准量）。 */
    @Column(name = "ending_qty", precision = 18, scale = 4)
    private BigDecimal endingQty;

    /** OQTY 标准/应损量（与 ending_qty 反向算盈亏）。 */
    @Column(name = "standard_qty", precision = 18, scale = 4)
    private BigDecimal standardQty;

    /** WRate 损耗率(%)。 */
    @Column(name = "waste_rate", precision = 8, scale = 4)
    private BigDecimal wasteRate;

    /** Cause 损耗原因。 */
    @Column(name = "cause")
    private String cause;

    @Column(name = "price", precision = 18, scale = 4)
    private BigDecimal price;

    @Column(name = "amount_original", precision = 18, scale = 4)
    private BigDecimal amountOriginal;

    @Column(name = "amount_local", precision = 18, scale = 4)
    private BigDecimal amountLocal;

    @Column(name = "weight", precision = 18, scale = 4)
    private BigDecimal weight;

    @Column(name = "source_doc_no")
    private String sourceDocNo;

    private String remark;
}
