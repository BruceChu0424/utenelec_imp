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
    /** 货品基本单位 UUID；数量展示必须使用该关系，不能按单位名称猜。 */
    private UUID unitId;
    /**
     * 所属仓库名 (V587)：这批货平时归哪个仓管的主档归属，不是单据落点仓。
     * 批量取名后拼入；仓库已软删或未解析时为 null。
     */
    private String owningWarehouseName;
    /**
     * 归属生产车间名 (V590)：最近一次排产确认/改派自动学习回写。
     * 批量取名后拼入；部门已软删或未解析时为 null。
     */
    private String owningWorkshopName;
}
