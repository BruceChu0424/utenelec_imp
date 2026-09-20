package com.uten.imp.features.purchase.common;

import java.math.BigDecimal;
import java.util.UUID;

/** 单价所属的商业维度；旧默认价缺失这些证据时不能自动预填。 */
public record ProcurementDefaultPriceContext(
        UUID supplierId, UUID colorId, UUID unitId, UUID currencyId, BigDecimal taxRate) {}
