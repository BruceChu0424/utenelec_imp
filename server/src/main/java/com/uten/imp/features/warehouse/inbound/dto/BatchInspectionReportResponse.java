package com.uten.imp.features.warehouse.inbound.dto;

import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import com.fasterxml.jackson.databind.ser.std.ToStringSerializer;

import java.util.List;
import java.util.UUID;

/**
 * 整份检验报告的执行回执：全部收货单同事务原子提交，[replay] 为 true 表示
 * 每一张单都是同一原报告的幂等重放（响应丢失后重试的确认路径）。
 */
public record BatchInspectionReportResponse(
        int receiptCount,
        int lineCount,
        boolean replay,
        List<Outcome> results) {

    public record Outcome(
            String receiptType,
            @JsonSerialize(using = ToStringSerializer.class) UUID receiptId,
            boolean replayed) {
    }
}
