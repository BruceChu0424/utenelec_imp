package com.uten.imp.features.production.dailyreport.dto;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/**
 * 一次录入的实际产出批次(ADR-148)：报工页一行 = 一批，服务端按去向分组并生成审核摘要。
 * 草稿恢复按 itemIds 把同批各份合回一行；页面不再自己按 outputBatchId 拼组与拼摘要。
 */
public record DailyReportOutputBatch(
        /** 产出批次号(没拆分的行 = 行 id)。 */
        UUID batchKey,
        /** 本批第一份(行号最小)的报工行：草稿恢复取来源与备注。 */
        UUID sourceItemId,
        /** 本批全部份(按行号)。 */
        List<UUID> itemIds,
        BigDecimal qty,
        /** 「货品 共 1100：送入仓库 1100(其中实际超产 100)」；审核确认逐批列出。 */
        String summary,
        /** 同去向、同接收方一组。 */
        List<DailyReportOutputGroup> groups) {

    public DailyReportOutputBatch {
        itemIds = List.copyOf(itemIds);
        groups = List.copyOf(groups);
    }
}
