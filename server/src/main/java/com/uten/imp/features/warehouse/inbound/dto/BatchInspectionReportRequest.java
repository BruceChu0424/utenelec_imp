package com.uten.imp.features.warehouse.inbound.dto;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

import java.util.List;
import java.util.UUID;

/**
 * 品质批量审批「整份检验报告」跨收货单一次提交（2026-10-10）。
 *
 * <p>此前前端对每张收货单各发一次 {@code decide-batch}，N 张单就是 N 次 HTTP 往返 +
 * N 个重事务，长批次既慢又容易在中间撞会话边界/超时。本请求把多张收货单合成一个
 * 服务端事务：联合预锁全部收货单的品质足迹后按报告顺序逐单执行，任一单失败整批
 * 回滚；每行携带的数量/幂等键与单张 {@link BatchInspectionDecideRequest} 完全同构，
 * 响应丢失后同体重放（已确认的单静默重放，回滚过的单重新执行）。</p>
 */
public record BatchInspectionReportRequest(
        @NotEmpty @Size(max = 20) List<@Valid Receipt> receipts,
        @Size(max = 500) String reason) {

    public record Receipt(
            @NotBlank String receiptType,
            @NotNull UUID receiptId,
            // 行级内容（数量/幂等键）由 ProcurementInspectionBatchCommand.decide 程序化校验，
            // 与单张 decide-batch 完全同一套；这里只钉集合形状。
            @NotEmpty @Size(max = 100) List<BatchInspectionDecideRequest.Item> items) {
    }
}
