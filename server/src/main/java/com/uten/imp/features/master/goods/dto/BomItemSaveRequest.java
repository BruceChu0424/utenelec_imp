package com.uten.imp.features.master.goods.dto;

import lombok.Getter;
import lombok.Setter;

import jakarta.validation.constraints.NotNull;
import java.math.BigDecimal;
import java.util.UUID;

/**
 * 组装信息行 新建/编辑请求（goods:edit）。
 *
 * <p>componentGoodsId 必填且必须指向存在的货品（编号唯一关联：UI 按编号搜索选中后传 id）。
 * total 不传时后端按 qty*price 兜底重算。
 */
@Getter
@Setter
public class BomItemSaveRequest {

    @NotNull
    private UUID componentGoodsId;   // 组件货品 id（必填）

    private BigDecimal qty;          // 用量（默认 1）
    private BigDecimal price;        // 单价
    private BigDecimal total;        // 金额（可空，后端兜底 qty*price）
    private Integer colorLegacyId;   // 组件颜色（colors.legacy_id）
    private String summary;          // 备注（外购/外加工...）
}
