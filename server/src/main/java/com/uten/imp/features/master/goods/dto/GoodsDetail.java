package com.uten.imp.features.master.goods.dto;

import com.fasterxml.jackson.annotation.JsonProperty;
import lombok.AllArgsConstructor;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/**
 * 货品详情：列表核心字段 + 关键业务字段（够看即可，不必 78 字段全返）。
 * category_name 由 @ManyToOne category 的 name 取；path 暂不返（分类详情页已有）。
 *
 * <p>成本预算 17 字段（老系统「成本预算」页签，对照 B_Goods 成本项列）：
 * 材料合计 sourceE / 加工费 machiningE / 杂费 incidentalE / 喷漆朔费 lacquerE /
 * 电镀费 platingE / 包装费 casingE / 抛光费 polishE / 成品价 total /
 * 人工比率 workRate / 人工费 workE / 损耗比率 lostRate / 损耗费 lostE /
 * 厂租比率 rentRate / 厂房租金 rentE / 生产利率 makeRate / 生产利润 makeE /
 * 成本价 cTotal / 出厂价 gTotal。
 */
@Getter
@Setter
@AllArgsConstructor
public class GoodsDetail {
    // ===== 列表核心 =====
    private UUID id;
    private String code;
    private String name;
    private String spec;
    private String model;
    private BigDecimal price;
    private BigDecimal discount;   // 折扣倍率 1.00=原价 0.90=9折（复用老库 B_Goods.zk）
    private String status;
    private Integer legacyId;

    // ===== 详情扩展 =====
    private String shortName;
    private UUID categoryId;
    private String categoryName;
    private String pack;
    private String material;
    private BigDecimal thickness;
    private UUID unitId;
    private Integer unitLegacyId;
    @JsonProperty("mWeight")
    private BigDecimal mWeight;      // MWeight 单重（防 Jackson 连续大写 quirk，显式锁定键名）
    private Integer pieces;
    private String colorName;        // 主颜色名（color_legacy_id → colors.name 解析）
    private String unitName;         // 单位名（unit_legacy_id → units.name 解析）
    private UUID colorId;
    private Integer colorLegacyId;   // 主颜色 legacy id（编辑表单回显选中用；unitLegacyId 已在上方）
    private UUID mouldId;
    private Integer mouldLegacyId;
    private UUID clientId;
    private Integer clientLegacyId;
    private UUID defaultSupplierId;
    private Integer vendLegacyId;
    private UUID secondarySupplierId;
    private Integer vend2LegacyId;

    // ===== 成本预算（「成本预算」页签） =====
    private BigDecimal sourceE;      // SourceE 材料合计
    private BigDecimal machiningE;   // MachiningE 加工费
    private BigDecimal incidentalE;  // IncidentalE 杂费
    private BigDecimal lacquerE;     // LacquerE 喷漆、朔费
    private BigDecimal platingE;     // PlatingE 电镀费
    private BigDecimal casingE;      // CasingE 包装费
    private BigDecimal polishE;      // PolishE 抛光费
    private BigDecimal total;        // Total 成品价
    private BigDecimal workRate;     // WorkRate 人工比率(%)
    private BigDecimal workE;        // WorkE 人工费
    private BigDecimal lostRate;     // LostRate 损耗比率(%)
    private BigDecimal lostE;        // LostE 损耗费
    private BigDecimal rentRate;     // RentRate 厂租比率(%)
    private BigDecimal rentE;        // RentE 厂房租金
    private BigDecimal makeRate;     // MakeRate 生产利率(%)
    private BigDecimal makeE;        // MakeE 生产利润
    @JsonProperty("cTotal")
    private BigDecimal cTotal;       // CTotal 成本价（防 Jackson 连续大写 quirk）
    @JsonProperty("gTotal")
    private BigDecimal gTotal;       // GTotal 出厂价（防 Jackson 连续大写 quirk）

    // ===== 来源 =====
    private String sourceType;       // 来源（自制/采购/委外；V128）

    // ===== 规格单位（V203：厚度/单重的计量单位，桥接 units.legacy_id） =====
    private Integer thicknessUnitLegacyId;
    private Integer mWeightUnitLegacyId;

    // ===== 成本可见性（goods:cost:view；未授权时成本字段置 null 且 costMasked=true） =====
    private boolean costMasked;

    // ===== 折扣可见性（goods:discount:view；未授权时 discount 置 null 且 discountMasked=true，前端隐藏折扣字段） =====
    private boolean discountMasked;

    // ===== 即时库存（聚合 stock_balances，仅参与核算仓库；详情展示+关联仓库） =====
    private BigDecimal stockQty;                 // 各参与核算仓库余量合计
    private List<GoodsStockRow> stockByWarehouse; // 按仓库（×颜色）展开
}
