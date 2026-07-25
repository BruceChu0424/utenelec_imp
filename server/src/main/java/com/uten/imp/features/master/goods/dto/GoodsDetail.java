package com.uten.imp.features.master.goods.dto;

import com.fasterxml.jackson.annotation.JsonProperty;
import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 货品详情：列表核心字段 + 关键业务字段（够看即可，不必 78 字段全返）。
 * category_name 由 @ManyToOne category 的 name 取；path 暂不返（分类详情页已有）。
 */
@Getter
@AllArgsConstructor
public class GoodsDetail {
    // ===== 列表核心 =====
    private UUID id;
    private String code;
    private String name;
    private String spec;
    private String model;
    private BigDecimal price;
    private String status;
    private Integer legacyId;

    // ===== 详情扩展 =====
    private String shortName;
    private UUID categoryId;
    private String categoryName;
    private String pack;
    private String material;
    private BigDecimal thickness;
    private Integer unitLegacyId;
    @JsonProperty("mWeight")
    private BigDecimal mWeight;      // MWeight 单重（防 Jackson 连续大写 quirk，显式锁定键名）
    private Integer pieces;
    private String colorName;        // 主颜色名（color_legacy_id → colors.name 解析）
    private String unitName;         // 单位名（unit_legacy_id → units.name 解析）
    private Integer colorLegacyId;   // 主颜色 legacy id（编辑表单回显选中用；unitLegacyId 已在上方）
}
