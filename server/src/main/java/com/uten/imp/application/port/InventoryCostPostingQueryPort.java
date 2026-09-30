package com.uten.imp.application.port;

import java.math.BigDecimal;
import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import com.uten.imp.common.finance.ExactDecimalText;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/** Published read boundary for actual COGS, returns and late value differences. */
public interface InventoryCostPostingQueryPort {
    record Posting(UUID postingId,UUID eventId,UUID nodeId,long valueRevision,UUID shipmentId,
            UUID shipmentItemId,UUID clientId,UUID goodsId,UUID warehouseId,UUID colorId,
            LocalDate businessDate,String sourcePeriod,String targetPeriod,String sourceDocType,
            UUID sourceDocId,UUID sourceItemId,String operation,@JsonSerialize(using=ExactDecimalText.class) BigDecimal amountLocal,
            boolean costPending,String postingStatus,UUID voucherId) {}
    List<Posting> postings(LocalDate from,LocalDate to,UUID goodsId);
}
