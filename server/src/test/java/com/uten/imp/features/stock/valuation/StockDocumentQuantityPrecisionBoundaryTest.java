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

/**
 * ADR-112: 数量按共享无损存储口径保存；提交与计价事实保持严格。
 * 2026-11-04 显式精度选择契约（0aaffa3aa/d533807ca 范式）：基本量/库存事实精确保存（尾零剥离，
 * 小数最多 24 位、整数最多 40 位，FinancialExactAmount），不再四位 HALF_UP 量子化。
 */
class StockDocumentQuantityPrecisionBoundaryTest {
    @Test void representableNonUnitRatesRetainTheirExactBaseQuantity() {
        org.assertj.core.api.Assertions.assertThat(ValueMath.positive(base("3","2"),"库存基本量")).isEqualByComparingTo("6");
        org.assertj.core.api.Assertions.assertThat(ValueMath.positive(base("3","0.5"),"库存基本量")).isEqualByComparingTo("1.5");
    }

    @Test void fractionalConversionUsesTheSameStoredBaseForDraftStockAndValuation() {
        BigDecimal stored=base("3","0.333333");
        // 3 × 0.333333 = 0.999999 精确保存，不再按四位 HALF_UP 归一到 1.0000。
        org.assertj.core.api.Assertions.assertThat(stored).isEqualByComparingTo("0.999999");
        var line=new com.uten.imp.features.stock.dto.StockDocItemLine();
        line.setQty(new BigDecimal("3"));line.setUnitRate(new BigDecimal("0.333333"));
        StockDocService service=mock(StockDocService.class,CALLS_REAL_METHODS);
        assertEquals(stored,ReflectionTestUtils.invokeMethod(service,"baseQtyOf",line));
        assertEquals(stored,ValueMath.positive(stored,"库存基本量"));
        assertEquals(new BigDecimal("3"),line.getQty());
        assertEquals(new BigDecimal("0.333333"),line.getUnitRate());
    }

    @Test void unnormalizedValuationFactsBeyondTheStorageQuantumStillFail() {
        BigDecimal within=new BigDecimal("3").multiply(new BigDecimal("0.333333"));
        assertEquals(new BigDecimal("0.999999"),within);
        // 0.999999 在 24 位小数无损口径内，不再拒绝。
        assertDoesNotThrow(()->ValueMath.positive(within,"库存基本量"));
        BigDecimal beyond=new BigDecimal("1.0000000000000000000000001");
        ApiException failure=assertThrows(ApiException.class,()->ValueMath.positive(beyond,"库存基本量"));
        assertEquals(ErrorCode.VALIDATION_FAILED,failure.getCode());
        assertTrue(failure.getMessage().contains("超出可无损保存的金额范围"));
        assertThrows(ApiException.class,()->com.uten.imp.common.util.FinancialExactAmount.quantity(beyond,"输入数量"));
    }

    private static BigDecimal base(String qty,String rate) {
        StockDocumentItem item=new StockDocumentItem();item.setQty(new BigDecimal(qty));item.setUnitRate(new BigDecimal(rate));
        StockDocService service=mock(StockDocService.class,CALLS_REAL_METHODS);
        return ReflectionTestUtils.invokeMethod(service,"baseQty",item);
    }
}
