package com.uten.imp.features.subcontract.order;

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
 * 委外订货 BOM 展开成本子表。源 E_OrderCostItem（67 行）。
 *
 * <p><b>本期只读：保结构 + 迁老库 67 行原样数据</b>，新系统不实现自动展开触发器
 * （design doc 22 §五）。{@code waste_allowance} 字段化老库硬编码 +0.46，供未来 BOM 引擎使用。
 *
 * <p>自关联 {@code parent_cost_item_id} 表达 BOM 层级（最深 30）；
 * {@code order_item_id} 指向根成品明细（{@code SubcontractOrderItem}）。
 *
 * <p>{@code issued_qty/returned_qty} 仅保存迁移来的 legacy 只读值。
 * 当前表没有冻结的 BOM 版本，新发料审核也已安全关闭，不能把这里的
 * 当前结构当作历史订单的发料权威台账。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "subcontract_order_cost_items")
public class SubcontractOrderCostItem extends BaseEntity {

    private Integer legacyId;

    @Column(name = "bill_no")
    private String billNo;

    @Column(name = "bill_date")
    private LocalDate billDate;

    @Column(name = "order_id", nullable = false)
    private UUID orderId;

    @Column(name = "order_item_id", nullable = false)
    private UUID orderItemId;            // 根成品明细

    /** BOM 父件（自关联）。 */
    @Column(name = "parent_cost_item_id")
    private UUID parentCostItemId;

    @Column(name = "bom_level", nullable = false)
    private Integer bomLevel = 1;

    @Column(name = "parent_goods_id")
    private UUID parentGoodsId;          // MGoodsID

    @Column(name = "parent_goods_code_snapshot") private String parentGoodsCodeSnapshot;
    @Column(name = "parent_goods_name_snapshot") private String parentGoodsNameSnapshot;
    @Column(name = "parent_goods_snapshot_source") private String parentGoodsSnapshotSource;
    @Column(name = "parent_goods_snapshot_locked_at") private OffsetDateTime parentGoodsSnapshotLockedAt;

    @Column(name = "parent_color_id")
    private UUID parentColorId;          // MColorID

    @Column(name = "goods_id", nullable = false)
    private UUID goodsId;                // 子件货品

    @Column(name = "goods_code_snapshot") private String goodsCodeSnapshot;
    @Column(name = "goods_name_snapshot") private String goodsNameSnapshot;
    @Column(name = "goods_snapshot_source", nullable = false) private String goodsSnapshotSource;
    @Column(name = "goods_snapshot_locked_at") private OffsetDateTime goodsSnapshotLockedAt;

    @Column(name = "color_id")
    private UUID colorId;                // 子件颜色

    @Column(name = "unit_id")
    private UUID unitId;

    @Column(name = "unit_rate", precision = 18, scale = 6)
    private BigDecimal unitRate;

    /** DQTY 单支用量（BOM 子件单位用量）。 */
    @Column(name = "unit_qty", precision = 18, scale = 6)
    private BigDecimal unitQty;

    /** QTY = 父件量×子件用量+余量（迁老库原值）。 */
    @Column(name = "qty", nullable = false, precision = 18, scale = 4)
    private BigDecimal qty;

    /** 规则化余量（老库硬编码 +0.46；新库字段化，默认 0）。 */
    @Column(name = "waste_allowance", precision = 18, scale = 6)
    private BigDecimal wasteAllowance = BigDecimal.ZERO;

    /** SQTY 已出仓量（迁移 legacy 只读值，新业务不写）。 */
    @Column(name = "issued_qty", precision = 18, scale = 4)
    private BigDecimal issuedQty = BigDecimal.ZERO;

    /** WQTY 已退量（迁移 legacy 只读值，新业务不写）。 */
    @Column(name = "returned_qty", precision = 18, scale = 4)
    private BigDecimal returnedQty = BigDecimal.ZERO;

    @Column(name = "line_class")
    private String lineClass;            // 老库 Class 字段

    @Column(name = "source_doc_no")
    private String sourceDocNo;

    private String remark;
}
