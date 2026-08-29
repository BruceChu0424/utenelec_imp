package com.uten.imp.features.warehouse.inbound.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.DecimalMin;
import jakarta.validation.constraints.Digits;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/**
 * 同一采购/委外收货单的 IQC 批量合格放行请求。
 *
 * <p>每行携带质检明细 UUID、操作人看到的剩余待检量和独立幂等键。
 * 服务端在任何库存写入前锁定并校验完整集合；任一行冲突时整批回滚。
 */
public record BatchInspectionPassRequest(
        @NotEmpty @Size(max = 100) List<@Valid Item> items,
        @Size(max = 500) String reason) {

    public record Item(
            @NotNull UUID inspectionItemId,
            @NotNull
            @DecimalMin(value = "0", inclusive = false)
            @Digits(integer = 14, fraction = 4)
            BigDecimal expectedRemainingBaseQty,
            @NotBlank @Size(min = 8, max = 128) String idempotencyKey) {
    }
}
