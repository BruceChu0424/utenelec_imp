package com.uten.imp.features.production.analysis;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;

/** Persisted source facts needed to create a plan, independent of page projections. */
interface MaterialAnalysisPlanSource {
    UUID analysisLineId();
    UUID goodsId();
    String goodsName();
    UUID colorId();
    UUID unitId();
    BigDecimal unitRate();
    UUID salesOrderItemId();
    String salesOrderNo();
    String clientName();
    BigDecimal requestedQty();
    LocalDate orderDate();
    LocalDate deliveryDate();
}
