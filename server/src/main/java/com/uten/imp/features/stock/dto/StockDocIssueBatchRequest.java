package com.uten.imp.features.stock.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;

import java.util.List;
import java.util.UUID;

/**
 * 领料任务中心「批量出库」请求（2026-09-09；2026-09-10 修订）：选中多张领料单按各自
 * 剩余量全额出库——逐单独立锁定与子幂等键（SHA-256(操作人+批量键+单据)），草稿单
 * 走「审核并出库」，任一单失败整批回滚；已出完的单自动跳过并计入 skipped，
 * 同人同批量键重放时按子键识别为 replayed。
 */
@Getter
@Setter
public class StockDocIssueBatchRequest {

    /** 单次批量上限（与服务端校验同值；前端勾选超出时先行截断提示）。 */
    public static final int MAX_DOCUMENTS = 50;

    @NotBlank(message = "批量出库缺少幂等键")
    @Size(min = 8, max = 128, message = "批量出库幂等键长度须为 8~128 位")
    private String idempotencyKey;

    @NotNull(message = "批量出库缺少单据清单")
    @Size(min = 1, max = MAX_DOCUMENTS, message = "一次最多批量出库 50 张领料单")
    private List<UUID> docIds;

    /** 统一备注（选填）：随本批每张领料单的出库追加到单据备注留痕，单条 ≤200 字。 */
    @Size(max = 200, message = "统一备注最多 200 字")
    private String reason;
}
