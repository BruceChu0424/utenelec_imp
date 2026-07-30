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
 * <p>price 统一用 BigDecimal 便于前端精度展示（实体 price 为 Double，service 端转换）。
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
}
