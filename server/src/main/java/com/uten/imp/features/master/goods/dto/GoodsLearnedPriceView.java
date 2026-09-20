package com.uten.imp.features.master.goods.dto;

import java.math.BigDecimal;

/** A learned price is displayed together with its original commercial dimensions. */
public record GoodsLearnedPriceView(BigDecimal price, String supplierName, String colorName,
        String unitName, String currencyName, BigDecimal taxRate, boolean contextComplete) {}
