package com.uten.imp.features.production.schedule.dto;

import java.util.List;
import java.util.UUID;

/** 批量转发 BOM 缺失结果。created=本次新建任务数；reused=复用既有任务数；items=逐货品明细。 */
public record ForwardBomGapBatchResult(int created, int reused, List<Item> items) {

    /** 单个货品转发结果。isNew=true 表示本次新建了研发任务（研发已收通知）；false 表示复用既有任务（仅登记等待）。 */
    public record Item(UUID goodsId, UUID taskId, boolean isNew) {
    }
}
