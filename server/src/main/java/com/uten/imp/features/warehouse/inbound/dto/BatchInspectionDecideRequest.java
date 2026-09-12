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
 * 同一采购/委外收货单的 IQC 批量检验报告请求（2026-09-05「提交报告」按钮）。
 *
 * <p>每行同时携带合格数量与不合格数量（均可为 0，但合计必须大于 0 且不超过
 * 操作人看到的剩余待检量）。服务端在库存写入前锁定并校验完整集合，任一行
 * 冲突整批回滚；含不合格数量的整批必须携带统一结论原因（FAIL 处置必填）。
 * V557 起完整规范化请求摘要冻结在原 PASS/FAIL 事件，响应丢失后同体重放；
 * 修改成员/剩余量/数量/原因或部分历史均拒绝。历史无摘要的报告不猜测原请求。
 */
public record BatchInspectionDecideRequest(
        @NotEmpty @Size(max = 100) List<@Valid Item> items,
        @Size(max = 500) String reason) {

    public record Item(
            @NotNull UUID inspectionItemId,
            @NotNull
            @DecimalMin(value = "0", inclusive = false)
            @Digits(integer = 14, fraction = 4)
            BigDecimal expectedRemainingBaseQty,
            @NotNull
            @DecimalMin(value = "0")
            @Digits(integer = 14, fraction = 4)
            BigDecimal passBaseQty,
            @NotNull
            @DecimalMin(value = "0")
            @Digits(integer = 14, fraction = 4)
            BigDecimal failBaseQty,
            @NotBlank @Size(min = 8, max = 128) String idempotencyKey) {
    }
}
