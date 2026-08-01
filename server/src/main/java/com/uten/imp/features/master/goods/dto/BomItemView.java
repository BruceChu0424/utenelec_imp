package com.uten.imp.features.master.goods.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 组装信息行视图：BOM 行 + 组件货品展示信息（编号/名称/型号/规格/单位/颜色/材质）。
 * hasChildren = 组件自身也有 BOM（组装树可继续展开）。
 */
@Getter
@AllArgsConstructor
public class BomItemView {
    private UUID id;
    private UUID componentGoodsId;
    private String componentCode;      // 组件编号（唯一关联键）
    private String componentName;      // 组件名称
    private String componentModel;     // 型号
    private String componentSpec;      // 规格
    private String componentMaterial;  // 材质
    private String componentUnitName;  // 单位名
    private String componentColorName; // 颜色名（行级 color_legacy_id 优先，空回落组件主颜色）
    private UUID colorId;
    private Integer colorLegacyId;
    private UUID defaultSupplierId;
    private Integer vendLegacyId;
    private BigDecimal qty;
    private BigDecimal price;
    private BigDecimal total;
    private String summary;            // 备注
    private Integer legacyId;
    private boolean hasChildren;       // 组件自身有 BOM（可展开）
    private String componentSourceType; // 组件来源（自制/采购/委外，组件信息只读展示 + 成本聚合区分用）
}
