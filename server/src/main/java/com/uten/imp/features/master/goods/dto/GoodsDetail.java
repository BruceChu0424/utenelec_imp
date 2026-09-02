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
    private Integer legacyId;       // 旧库主键快照，仅迁移溯源

    // ===== 详情扩展 =====
    private String shortName;
    private UUID categoryId;        // 所属分类 UUID 关系
    private String categoryName;
    private String pack;
    private String material;
    private BigDecimal thickness;
    private UUID unitId;
    private Integer unitLegacyId;
    private BigDecimal mWeight;      // MWeight 单重（防 Jackson 连续大写 quirk，显式锁定键名）
    private Integer pieces;
    private String colorName;        // UUID 关系解析优先；历史 UUID 缺失时只读回落 legacy 快照
    private String unitName;         // UUID 关系解析优先；历史 UUID 缺失时只读回落 legacy 快照
    private UUID colorId;
    private Integer colorLegacyId;   // 旧库主颜色主键快照；不能作为新关系键
    private UUID mouldId;
    private Integer mouldLegacyId;
    private String mouldCode;       // 模具编号（moulds.code；UUID 关系优先，历史缺失回落 legacy 快照解析）
    private String mouldName;       // 模具名称（moulds.name；同上回落）
    private String rearInsertCode;  // 后模镶件编号（V457）：生产该货品需使用的后模镶件标识
    private String paper;           // 备注（老库 B_Goods.Paper；require_remark 仅迁移残值不再展示）
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
    private BigDecimal cTotal;       // CTotal 成本价（防 Jackson 连续大写 quirk）
    private BigDecimal gTotal;       // GTotal 出厂价（防 Jackson 连续大写 quirk）

    // ===== 来源 =====
    private String sourceType;       // 来源（自制/采购/委外）

    // ===== 规格单位（UUID 是关系；legacy id 仅保留历史回显快照） =====
    private Integer thicknessUnitLegacyId;
    private Integer mWeightUnitLegacyId;

    // ===== 成本可见性（goods:cost:view；未授权时成本字段置 null 且 costMasked=true） =====
    private boolean costMasked;

    // ===== 折扣可见性（goods:discount:view；未授权时 discount 置 null 且 discountMasked=true，前端隐藏折扣字段） =====
    private boolean discountMasked;

    // ===== 即时库存（聚合 stock_balances，仅参与核算仓库；详情展示+关联仓库） =====
    private BigDecimal stockQty;                 // 各参与核算仓库余量合计
    private List<GoodsStockRow> stockByWarehouse; // 按仓库（×颜色）展开

    private Long version;                        // 乐观锁版本（编辑回传）

    private String series;                       // 物料系列（goods.series，如塑胶件/五金件）
    private String stockPlace;                   // 库位号（goods.stock_place，仓库摆放位置）

    private UUID thicknessUnitId;                // 厚度单位 UUID 真源
    private UUID mWeightUnitId;                   // 单重单位 UUID 真源

    @JsonProperty("mWeight")
    public BigDecimal getMWeight() {
        return mWeight;
    }

    @JsonProperty("cTotal")
    public BigDecimal getCTotal() {
        return cTotal;
    }

    @JsonProperty("gTotal")
    public BigDecimal getGTotal() {
        return gTotal;
    }
}
