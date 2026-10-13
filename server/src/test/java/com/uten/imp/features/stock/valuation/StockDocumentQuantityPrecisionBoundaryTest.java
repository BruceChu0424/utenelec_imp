package com.uten.imp.features.stock.valuation;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.StockDocumentItem;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

/** ADR-112: conversion uses the shared four-decimal quantity quantum; submitted and valuation facts remain strict. */
class StockDocumentQuantityPrecisionBoundaryTest {
    @Test void representableNonUnitRatesRetainTheirExactBaseQuantity() {
        assertEquals(new BigDecimal("6.0000"),ValueMath.positive(base("3","2"),"库存基本量"));
        assertEquals(new BigDecimal("1.5000"),ValueMath.positive(base("3","0.5"),"库存基本量"));
    }

    @Test void fractionalConversionUsesTheSameStoredBaseForDraftStockAndValuation() {
        BigDecimal stored=base("3","0.333333");
        assertEquals(new BigDecimal("1.0000"),stored);
        var line=new com.uten.imp.features.stock.dto.StockDocItemLine();
        line.setQty(new BigDecimal("3"));line.setUnitRate(new BigDecimal("0.333333"));
        StockDocService service=mock(StockDocService.class,CALLS_REAL_METHODS);
        assertEquals(stored,ReflectionTestUtils.invokeMethod(service,"baseQtyOf",line));
        assertEquals(stored,ValueMath.positive(stored,"库存基本量"));
        assertEquals(new BigDecimal("3"),line.getQty());
        assertEquals(new BigDecimal("0.333333"),line.getUnitRate());
    }

    @Test void unnormalizedValuationFactsBeyondTheStorageQuantumStillFail() {
        BigDecimal requested=new BigDecimal("3").multiply(new BigDecimal("0.333333"));
        assertEquals(new BigDecimal("0.999999"),requested);
        ApiException failure=assertThrows(ApiException.class,()->ValueMath.positive(requested,"库存基本量"));
        assertEquals(ErrorCode.VALIDATION_FAILED,failure.getCode());
        assertTrue(failure.getMessage().contains("最多4位小数"));
        assertThrows(ApiException.class,()->com.uten.imp.common.util.FinancialExactAmount.quantity(requested,"输入数量"));
    }

    private static BigDecimal base(String qty,String rate) {
        StockDocumentItem item=new StockDocumentItem();item.setQty(new BigDecimal(qty));item.setUnitRate(new BigDecimal(rate));
        StockDocService service=mock(StockDocService.class,CALLS_REAL_METHODS);
        return ReflectionTestUtils.invokeMethod(service,"baseQty",item);
    }
}
