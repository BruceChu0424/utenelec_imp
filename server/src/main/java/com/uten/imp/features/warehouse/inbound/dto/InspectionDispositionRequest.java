package com.uten.imp.features.warehouse.inbound.dto;

import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;

/** 采购/委外收货待检处置请求：PASS 合格放行（进可用 + 唤醒生产）/ FAIL 不合格（只记事实）。
 *
 * <p>{@code baseQty} 可空（傻瓜式操作）：不传时按"全部剩余待检量"处置，便于仓库一键合格/不合格；
 * 传值则部分处置（仍不得超剩余）。{@code reason} 对 PASS 可空，对 FAIL 仍由服务与数据库强制必填。 */
public record InspectionDispositionRequest(
        @Pattern(regexp = "PASS|FAIL", message = "质检结论仅支持 PASS 或 FAIL")
        String action,
        @DecimalMin(value = "0", inclusive = false)
        @Digits(integer = 14, fraction = 4) BigDecimal baseQty,
        @Size(max = 500) String reason,
        @NotBlank @Size(min = 8, max = 128) String idempotencyKey) {
}
