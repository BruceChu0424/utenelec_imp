package com.uten.imp.features.production.dailyreport.dto;

import jakarta.validation.constraints.NotNull;

import java.math.BigDecimal;
import java.util.UUID;

/**
 * 一行报工的一个产出去向(V736/ADR-127)：转给哪条上层工单的物料需求多少，或送入仓库多少(需求为空)。
 *
 * <p>数量与报工行同单位；一行的全部去向合计必须等于本行实际产量。服务端按接收需求逐条校验
 * (fn_workshop_direct_targets)，每个接收工单写一条独立的转送明细，送入仓库的部分(连同公共备货与
 * 实际超产)各写一条送仓明细并记下原因。
 */
public record DailyReportOutputAllocationLine(UUID directTransferDemandId, @NotNull BigDecimal qty) {
    @com.fasterxml.jackson.annotation.JsonProperty(value="qtyExact", access=com.fasterxml.jackson.annotation.JsonProperty.Access.READ_ONLY)
    public String qtyExact() { return qty == null ? null : qty.toPlainString(); }

    /** 送入仓库的去向。 */
    public static DailyReportOutputAllocationLine warehouse(BigDecimal qty) {
        return new DailyReportOutputAllocationLine(null, qty);
    }

    /** 转给某条上层工单物料需求的去向。 */
    public static DailyReportOutputAllocationLine direct(UUID demandId, BigDecimal qty) {
        return new DailyReportOutputAllocationLine(demandId, qty);
    }
}
