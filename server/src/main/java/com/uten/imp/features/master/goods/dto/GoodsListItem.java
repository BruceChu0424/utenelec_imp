package com.uten.imp.features.master.goods.dto;

import com.fasterxml.jackson.annotation.JsonProperty;
import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 货品列表项。
 *
 * <p>除原摘要字段外，补筛选/展示字段以及颜色、单位、分类 UUID。legacy id 仅用于历史行筛选/回显，
 * 不能建立在线关系。cNumber 显式 {@code @JsonProperty("cNumber")} 防 Jackson 连续大写
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
    private String cNumber;
    private String requireRemark;
    private UUID colorId;
    private UUID unitId;
    private Integer colorLegacyId;
    private Integer unitLegacyId;
    private String colorName;     // UUID 优先解析；历史 UUID 缺失时只读回落 legacy 快照
    private String unitName;      // UUID 优先解析；历史 UUID 缺失时只读回落 legacy 快照
    private String sourceType;    // 来源（自制/采购/委外）
    private UUID categoryId;      // 所属分类 UUID（goods.category_id；搜货品定位分类用）
    private boolean autoCreated;  // 迁移兜底占位货品标记（auto_created 列）
    private BigDecimal stockQty;  // 即时库存合计（聚合 stock_balances，仅参与核算仓库；列表展示用）
    private String stockPlace;    // 库位号（goods.stock_place；单据选品/拣货指引，选择器展示用）

    /** Keep the public JSON key stable across Jackson/JavaBeans versions. */
    @JsonProperty("cNumber")
    public String getCNumber() {
        return cNumber;
    }
}
