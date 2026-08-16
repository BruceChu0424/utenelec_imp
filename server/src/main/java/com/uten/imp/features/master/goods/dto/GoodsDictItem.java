package com.uten.imp.features.master.goods.dto;

import lombok.AllArgsConstructor;
import lombok.Getter;

import java.util.UUID;

/**
 * 货品字典项（id/编号/名称）—— 采购单据明细按 id 批量解析货品名用，轻量。
 *
 * <p>货品约 3.5 万条不能全量拉，故按 ids 批量查（GET /api/master/goods/lookup?ids=...）。
 * 货品选择（编辑新增行）走列表关键词搜索，不走本接口。
 */
@Getter
@AllArgsConstructor
public class GoodsDictItem {
    private UUID id;
    private String code;
    private String name;
    /** 物料系列（goods.series）——仓库单据明细展示用。 */
    private String series;
    /** 库位号（goods.stock_place）——仓库单据明细展示用。 */
    private String stockPlace;
}
