package com.uten.imp.features.stock.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/**
 * 领料任务中心「批量出库」请求（2026-09-09；2026-09-10 修订）：选中多张领料单按各自
 * 当前已申请剩余量全额出库，整批按固定顺序预锁，草稿走「审核并出库」，任一单失败整批回滚。
 * 父回执冻结同人同键的完整单据集合、备注、重量及结果，已出完的单也冻结为 skipped。
 * 同键重试只读回放，不因后续取消出库或新增申请再次扣库；旧子键缺父回执时必须核查历史。
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

    /** Missing/1 preserves the original command. 2 freezes the complete review returned by issue-batch/review. */
    private Integer protocolVersion;
    @Valid
    @Size(max = MAX_DOCUMENTS)
    private List<DocumentReview> reviews;

    public record DocumentReview(@NotNull UUID docId,
                                @NotBlank @jakarta.validation.constraints.Pattern(regexp = "[0-9a-f]{64}")
                                String reviewToken) {}

    /**
     * 逐行实称重量(选填, ADR-135): 领料行 id -> 本次出库的实称重量(千克)与「数量按称重推算」标记。
     * 行必须属于本批所选领料单; 本次没有剩余可出的行忽略其重量。
     */
    @Valid
    @Size(max = RequestLimits.DOCUMENT_LINES, message = "逐行重量最多 500 行")
    private List<ItemWeight> weights;

    /** 一行领料的本次实称重量(千克, 空或 0 = 没称)。 */
    public record ItemWeight(
            @NotNull UUID itemId,
            @DecimalMin("0") @Digits(integer = 14, fraction = 4) BigDecimal weightKg,
            Boolean qtyFromWeight) {
    }
}
