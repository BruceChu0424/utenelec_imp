package com.uten.imp.features.stock.dto;

import java.util.List;

/**
 * 领料任务中心「批量出库」结果。
 *
 * @param issuedCount   本次新出库的领料单张数
 * @param skippedCount  提交前已出完、且不属于本批幂等键的单（自动跳过）
 * @param replayedCount 已在本批(同操作人同幂等键)此前完成、本次按完整父回执回放的单
 * @param replayed      本批已有完整父回执，本次没有新增出库；此前全部跳过时也为 true
 * @param issuedDocNos  本次新出库的领料单号
 */
public record StockDocIssueBatchResponse(
        int issuedCount,
        int skippedCount,
        int replayedCount,
        boolean replayed,
        List<String> issuedDocNos) {

    public StockDocIssueBatchResponse {
        issuedDocNos = issuedDocNos == null ? List.of() : List.copyOf(issuedDocNos);
    }
}
