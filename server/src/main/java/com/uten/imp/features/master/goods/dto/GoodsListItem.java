package com.uten.imp.features.master.goods.dto;

import com.fasterxml.jackson.annotation.JsonProperty;
import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 货品列表项。
 *
 * <p>除原摘要字段外，补 6 个筛选/展示字段（系列/材质/客户型号/备注/颜色 legacy id/单位 legacy id），
 * 供基础资料筛选栏与卡片展示。cNumber 显式 {@code @JsonProperty("cNumber")} 防 Jackson 连续大写
 * decapitalize 坑（参考 mWeight→mweight），前端 fromJson 同名读取。
 *
 * <p>price 使用 BigDecimal，与数据库 NUMERIC(18,4) 一致。
 */
@Getter
@AllArgsConstructor
public class GoodsListItem {
    private UUID id;
    private String code;
    private String name;
    private String spec;
    private String model;
    private BigDecimal price;
    private BigDecimal discount;   // 折扣倍率 1.00=原价 0.90=9折（复用老库 B_Goods.zk）
    private String status;
    private Integer legacyId;
    private String series;
    private String material;
    @JsonProperty("cNumber")
    private String cNumber;
    private String requireRemark;
    private Integer colorLegacyId;
    private Integer unitLegacyId;
    private String colorName;     // 主颜色名（goods.color_legacy_id → colors.name 解析，无则 null）
    private String unitName;      // 单位名（goods.unit_legacy_id → units.name 解析，无则 null）
    private String sourceType;    // 来源（自制/采购/委外；V128）
    private UUID categoryId;      // 所属分类 id（goods.category_id；货品资料页"搜货品定位分类"用）
    private boolean autoCreated;  // 迁移兜底占位货品标记（V177；auto_created 列）
    private BigDecimal stockQty;  // 即时库存合计（聚合 stock_balances，仅参与核算仓库；列表展示用）
}
