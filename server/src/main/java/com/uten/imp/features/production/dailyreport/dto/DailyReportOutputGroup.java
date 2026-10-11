package com.uten.imp.features.production.dailyreport.dto;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/**
 * 实物交接批(ADR-148)在车间侧的样子：同一产出批次、同一去向、同一接收方的各份合成一行，
 * 例如「送入仓库 1100(其中实际超产 100)」「转给 上层工单 200」。
 */
public record DailyReportOutputGroup(
        UUID lotId,
        List<UUID> itemIds,
        /** WAREHOUSE 送入仓库 / WORKSHOP 转给上层工单。 */
        String destination,
        UUID directTransferDemandId,
        String receiverLabel,
        BigDecimal qty,
        BigDecimal demandQty,
        BigDecimal publicQty,
        BigDecimal actualSurplusQty,
        /** 「需求 1000 · 实际超产 100」；整批都是需求份时为空。 */
        String splitText,
        /** 需求份送入仓库的原因(大白话)；没有时为空。 */
        String reasonText,
        String summary) {

    public DailyReportOutputGroup {
        itemIds = List.copyOf(itemIds);
    }
    @com.fasterxml.jackson.annotation.JsonProperty(value="qtyExact", access=com.fasterxml.jackson.annotation.JsonProperty.Access.READ_ONLY)
    public String qtyExact() { return exact(qty); }
    @com.fasterxml.jackson.annotation.JsonProperty(value="demandQtyExact", access=com.fasterxml.jackson.annotation.JsonProperty.Access.READ_ONLY)
    public String demandQtyExact() { return exact(demandQty); }
    @com.fasterxml.jackson.annotation.JsonProperty(value="publicQtyExact", access=com.fasterxml.jackson.annotation.JsonProperty.Access.READ_ONLY)
    public String publicQtyExact() { return exact(publicQty); }
    @com.fasterxml.jackson.annotation.JsonProperty(value="actualSurplusQtyExact", access=com.fasterxml.jackson.annotation.JsonProperty.Access.READ_ONLY)
    public String actualSurplusQtyExact() { return exact(actualSurplusQty); }
    private static String exact(BigDecimal value) { return value == null ? null : value.toPlainString(); }
}
