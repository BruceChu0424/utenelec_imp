package com.uten.imp.features.stock.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.UUID;

/**
 * 货架目视化清单行（仓库管理 → 货架目视化清单 / 打印张贴用）。
 *
 * <p>对标仓库现场「目视化管理清单 Visual Management List」挂牌：
 * 每个货架（库行，如 A31/A39，取 stock_place 首段）一张表，
 * 列 = 库位号 / 物料编码 / 物料系列 / 物料名称 / 颜色。
 *
 * <p>数据来源：货品主档 goods.stock_place（库位号，仓库摆放位置）。
 * 与库存数量无关——货架上固定摆放什么就显示什么，与即时库存口径解耦。
 */
@Getter
@AllArgsConstructor
public class ShelfLabelRow {
    private UUID goodsId;
    /** 库行（货架编号，stock_place 首段，如 A31；无分隔符时为整个 stock_place）。 */
    private String rack;
    /** 库位号（goods.stock_place 原样，如 A31-3-1）。 */
    private String place;
    /** 物料编码（goods.code）。 */
    private String goodsCode;
    /** 物料系列（goods.series）。 */
    private String series;
    /** 物料名称（goods.name）。 */
    private String goodsName;
    /** 颜色（goods.color_id → colors.name；主档未填色时为空串）。 */
    private String colorName;
}
