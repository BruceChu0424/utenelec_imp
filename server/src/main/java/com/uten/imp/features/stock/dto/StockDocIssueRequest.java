package com.uten.imp.features.stock.dto;

import com.uten.imp.common.validation.RequestLimits;
import jakarta.validation.Valid;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;
import jakarta.validation.constraints.Size;
import lombok.Getter;
import lombok.Setter;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/**
 * DRAW 领料单分轮出库/取消出库请求（取消沿兼容 reverse API）。
 * 每行：itemId + 本次数量（出库须 ≤ qty−issued_qty；取消出库须 ≤ issued_qty）。
 *
 * <p>出库行可带本次实称重量(千克, 最多 4 位小数, 0 视为没称)与「数量按称重推算」标记(ADR-135);
 * 同一领料行拆成多行提交时重量相加, 不能一部分带重量一部分不带。取消出库不带重量:
 * 库存账按本行已出库流水的重量镜像退回。
 */
@Getter
@Setter
public class StockDocIssueRequest {

    @NotBlank
    @Size(min = 8, max = 128)
    private String idempotencyKey;

    @Valid
    @NotNull
    @Size(min = 1, max = RequestLimits.DOCUMENT_LINES)
    private List<Line> lines;

    /**
     * 取消出库：必填的取消原因（进审计，不落 remark）。
     * 正向出库（issue / approve-and-issue / 批量）：选填的出库备注，服务端按单条
     * ≤200 字追加到单据 remark（多轮出库用「；」连接、整条相同不重复、总长 ≤500）。
     */
    @Size(max = 1000)
    private String reason;

    @Getter
    @Setter
    public static class Line {
        @NotNull
        private UUID itemId;

        @NotNull
        @Positive
        private BigDecimal qty;

        /** 本次实称重量(千克, 整行); 空或 0 = 没称。 */
        @DecimalMin("0")
        @Digits(integer = 14, fraction = 4)
        private BigDecimal weightKg;

        /** 本次数量是否按称重计数推算; 为真时本次出库不进单重学习。 */
        private Boolean qtyFromWeight;
    }
}
