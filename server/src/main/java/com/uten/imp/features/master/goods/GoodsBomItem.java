package com.uten.imp.features.master.goods;

import com.uten.imp.common.domain.SoftDeletableEntity;
import com.uten.imp.features.master.color.Color;
import com.uten.imp.features.master.supplier.Supplier;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.FetchType;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.ManyToOne;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.Objects;

/**
 * 货品组装信息（BOM）行：「成品/半成品 goods 由组件 component 组装 qty 个」。
 *
 * <p>逐字段对照 goods_bom_items 表（id/审计/软删来自 {@link SoftDeletableEntity}）。
 * 老库 B_BomItem 迁移：legacy_id=B_BomItem.ID（溯源+重跑幂等）。
 *
 * <p>组件本身也可有自己的 BOM 行（component 作为别人的 goods），递归即成组装树。
 * 同一成品下组件 UUID 唯一（部分唯一索引 uq_goods_bom_component 保障）；组件编号不是外键。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "goods_bom_items")
public class GoodsBomItem extends SoftDeletableEntity {

    /** 老库 B_BomItem.ID（迁移溯源+重跑幂等）；手工新建的为 null。 */
    @Column(name = "legacy_id", unique = true)
    private Integer legacyId;

    /** 成品/半成品（B_BomItem.BillID → goods）。 */
    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "goods_id", nullable = false)
    private Goods goods;

    /** 组件货品（B_BomItem.GoodsID → goods）。 */
    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "component_goods_id", nullable = false)
    private Goods component;

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "color_id")
    private Color color;

    @Column(name = "color_legacy_id")
    private Integer colorLegacyId;      // ColorID（组件颜色，老库主键）

    /** 设计使用数量(老库 QTY)；真实使用数量在 goods_bom_actual_usages，经 v_goods_bom_item_usage 按边读取。 */
    @Column(nullable = false)
    private BigDecimal qty = BigDecimal.ONE;

    /** 该组件在哪个生产阶段参与齐套控制。 */
    @Column(name = "control_stage", nullable = false)
    private String controlStage = "START";

    /** 用量换算方式：按件、按包装单位或固定批耗。 */
    @Column(name = "consumption_basis", nullable = false)
    private String consumptionBasis = "PER_UNIT";

    /** 一次 BOM 用量对应的产出数量。 */
    @Column(name = "basis_output_qty", nullable = false, precision = 18, scale = 6)
    private BigDecimal basisOutputQty = BigDecimal.ONE;

    /** 按包装计量时是否允许最后一个包装不足整包。 */
    @Column(name = "allow_partial_package", nullable = false)
    private boolean allowPartialPackage = true;

    /** 缺料是否阻断生产阶段；仅 START/ASSEMBLY/FINISH 可为 true。 */
    @Column(name = "hard_gate", nullable = false)
    private boolean hardGate = true;

    private BigDecimal price;           // Price 单价
    private BigDecimal total;           // Total 金额（= qty*price，service 兜底重算）

    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "default_supplier_id")
    private Supplier defaultSupplier;

    @Column(name = "vend_legacy_id")
    private Integer vendLegacyId;       // VendID（默认供应商，老库主键）

    private String summary;             // Summary 备注（外购/外加工...）

    @Column(name = "bom_status")
    private Boolean bomStatus;          // BomStatus

    @Column(name = "sstatus")
    private Boolean sstatus;            // SStatus

    @Column(name = "sort_order", nullable = false)
    private Integer sortOrder = 0;      // 展示序号（迁移按老库 ID 序）

    /** 审计标记时间：非空 = 该组件已核对无误；编辑行内容时服务端清空。 */
    @Column(name = "audited_at")
    private java.time.OffsetDateTime auditedAt;

    /** 审计标记人（users.id 宽松不 FK）。 */
    @Column(name = "audited_by")
    private java.util.UUID auditedBy;

    /**
     * 系统学习边标记(ADR-129)：非空 = 这条边由学习引擎新建、设计使用数量由系统同步。只读映射：
     * 人工改结构列后由数据库触发器清空，JPA 整行更新绝不回写。
     */
    @Column(name = "learning_profile_goods_id", insertable = false, updatable = false)
    private java.util.UUID learningProfileGoodsId;

    /** 人工删除该组件边的时间(数据库触发器记)：学习不再自动把该组件加回。只读映射。 */
    @Column(name = "learning_released_at", insertable = false, updatable = false)
    private java.time.OffsetDateTime learningReleasedAt;

    /** 设计使用数量/控制段/价格/颜色/供应商/备注与 {@code other} 一致(排序与审核标记不算内容)。 */
    boolean sameContentAs(GoodsBomItem other) {
        return sameNumber(qty, other.getQty())
                && Objects.equals(controlStage, other.getControlStage())
                && Objects.equals(consumptionBasis, other.getConsumptionBasis())
                && sameNumber(basisOutputQty, other.getBasisOutputQty())
                && allowPartialPackage == other.isAllowPartialPackage()
                && hardGate == other.isHardGate()
                && sameNumber(price, other.getPrice())
                && sameNumber(total, other.getTotal())
                && Objects.equals(idOf(color), idOf(other.getColor()))
                && Objects.equals(colorLegacyId, other.getColorLegacyId())
                && Objects.equals(idOf(defaultSupplier), idOf(other.getDefaultSupplier()))
                && Objects.equals(vendLegacyId, other.getVendLegacyId())
                && Objects.equals(summary, other.getSummary());
    }

    /** 把 {@code source} 的内容整体写到本行(同一组件原地覆盖)；内容变了原审核结论作废。 */
    void takeContentFrom(GoodsBomItem source) {
        qty = source.getQty();
        controlStage = source.getControlStage();
        consumptionBasis = source.getConsumptionBasis();
        basisOutputQty = source.getBasisOutputQty();
        allowPartialPackage = source.isAllowPartialPackage();
        hardGate = source.isHardGate();
        price = source.getPrice();
        total = source.getTotal();
        color = source.getColor();
        colorLegacyId = source.getColorLegacyId();
        defaultSupplier = source.getDefaultSupplier();
        vendLegacyId = source.getVendLegacyId();
        summary = source.getSummary();
        auditedAt = null;
        auditedBy = null;
    }

    private static boolean sameNumber(BigDecimal left, BigDecimal right) {
        return left == null ? right == null : right != null && left.compareTo(right) == 0;
    }

    private static java.util.UUID idOf(com.uten.imp.common.domain.BaseEntity entity) {
        return entity == null ? null : entity.getId();
    }
}
