package com.uten.imp.features.stock.dto;

import java.util.List;

/**
 * 不良品专门通道一次建单并过账的结果(ADR-146)。
 *
 * @param document 生成并已过账的仓库调拨单
 * @param warnings 给办理人的提醒(大白话): 「转不良品仓」记录的是事实(货已经判为不良), 不会被预留挡住,
 *                 转走后已经没有实物支撑的预留在这里逐条列出, 由办理人通知计划/销售重新安排; 没有则为空
 */
public record StockDefectiveMoveResult(StockDocDetail document, List<String> warnings) {
    public StockDefectiveMoveResult {
        warnings = warnings == null ? List.of() : List.copyOf(warnings);
    }
}
