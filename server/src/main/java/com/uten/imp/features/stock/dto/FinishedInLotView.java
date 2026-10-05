package com.uten.imp.features.stock.dto;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

/**
 * 成品入库单里的一批实物(ADR-148): 单内各行(各份)合计与按归属拆分, 仓库按批点收一次。
 * 少收时服务端先扣实际超产, 再扣计划公共, 最后扣需求份。
 */
public record FinishedInLotView(
        UUID lotId,
        List<UUID> itemIds,
        UUID goodsId,
        UUID colorId,
        UUID unitId,
        BigDecimal qty,
        BigDecimal demandQty,
        BigDecimal publicQty,
        BigDecimal actualSurplusQty,
        /** 「需求 1000 · 实际超产 100」; 整批都是需求份时为空。 */
        String splitText,
        /** 「其中实际超产 100」; 没有实际超产时为空。 */
        String actualSurplusNote,
        /** 本批几份时的少收规则说明; 只有一份时为空。 */
        String shortageHint,
        BigDecimal weight) {

    public FinishedInLotView {
        itemIds = List.copyOf(itemIds);
    }
}
