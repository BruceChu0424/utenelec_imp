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

/** Evidence for the existing four-decimal stock boundary; this does not silently round physical stock. */
class StockDocumentQuantityPrecisionBoundaryTest {
    @Test void representableNonUnitRatesRetainTheirExactBaseQuantity() {
        assertEquals(new BigDecimal("6.0000"),ValueMath.positive(base("3","2"),"库存基本量"));
        assertEquals(new BigDecimal("1.5000"),ValueMath.positive(base("3","0.5"),"库存基本量"));
    }

    @Test void fractionalConversionBeyondTheStorageQuantumFailsInsteadOfInventingARoundedReceipt() {
        BigDecimal requested=base("3","0.333333");
        assertEquals(new BigDecimal("0.999999"),requested);
        ApiException failure=assertThrows(ApiException.class,()->ValueMath.positive(requested,"库存基本量"));
        assertEquals(ErrorCode.VALIDATION_FAILED,failure.getCode());
        assertTrue(failure.getMessage().contains("最多4位小数"));
        // A per-row rounding patch would not conserve repeated receipts versus
        // their total target; quantity storage, issue units and cost basis must
        // adopt one rule together before supporting this case.
    }

    private static BigDecimal base(String qty,String rate) {
        StockDocumentItem item=new StockDocumentItem();item.setQty(new BigDecimal(qty));item.setUnitRate(new BigDecimal(rate));
        StockDocService service=mock(StockDocService.class,CALLS_REAL_METHODS);
        return ReflectionTestUtils.invokeMethod(service,"baseQty",item);
    }
}
