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

/**
 * 货品组装信息（BOM）行：「成品/半成品 goods 由组件 component 组装 qty 个」。
 *
 * <p>逐字段对照 V79 goods_bom_items 表（id/审计/软删来自 {@link SoftDeletableEntity}）。
 * 老库 B_BomItem 迁移：legacy_id=B_BomItem.ID（溯源+重跑幂等）。
 *
 * <p>组件本身也可有自己的 BOM 行（component 作为别人的 goods），递归即成组装树。
 * 同一成品下组件唯一（V79 部分唯一索引 uq_goods_bom_component 保障）。
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

    @Column(nullable = false)
    private BigDecimal qty = BigDecimal.ONE;  // QTY 用量

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
}
