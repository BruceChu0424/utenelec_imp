package com.uten.imp.features.production.schedule.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.List;
import java.util.UUID;

/**
 * 一键批量转发 BOM 缺失给工程研发部（POST /api/production/schedule/forward-rd-batch）。
 *
 * <p>物料评审 / 待排产页一次把所有缺 BOM 的件（成品 + 自制组件）批量转发。每货品按 goods 去重，
 * 研发只收一条；当前计划员登记为每个货品的等待者。组件转发无 order_item，来源填计划单。
 */
public record ForwardBomGapBatchRequest(
        @NotEmpty @Size(max = 200) @Valid List<Line> items,
        @Size(max = 1000) String note,
        UUID sourcePlanId,        // 组件转发场景的来源计划 id（成品转发可空，用 order_item 反查）
        String sourcePlanNo) {    // 来源计划单号

    /** 单个缺 BOM 货品。成品转发带 orderItemId；自制组件转发 orderItemId 为空。 */
    public record Line(
            @NotNull UUID goodsId,
            UUID orderItemId) {
    }
}
