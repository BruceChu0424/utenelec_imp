package com.uten.imp.features.sales.ret.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

/**
 * 客户处置决策请求（V219）。
 *
 * <p>由销售确认客户对退货的处理结论：退款结案 / 换货 / 补发 / 维修后返还。
 * 处置确认后产生确定影响并禁止整单普通红冲（须走受控补偿），因此要求原因与幂等键。
 */
public record CustomerDispositionRequest(
        @NotBlank
        @Pattern(regexp = "REFUND_CLOSED|EXCHANGE|RESHIP|REPAIR_RETURN",
                message = "客户处置仅支持 REFUND_CLOSED/EXCHANGE/RESHIP/REPAIR_RETURN")
        String disposition,
        @NotBlank @Size(max = 500) String reason,
        @NotBlank @Size(min = 8, max = 128) String idempotencyKey) {
}
