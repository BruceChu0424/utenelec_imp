package com.uten.imp.common.finance;

import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;

class SellingPriceCurrencyTest {
    @Test void explicitForeignCurrencyNeverBecomesABaseCurrencyDefault() {
        BigDecimal price=new BigDecimal("12345678901234.1234");
        assertSame(price,SellingPriceCurrency.forBaseCurrency(price,null,false));
        assertSame(price,SellingPriceCurrency.forBaseCurrency(price,UUID.randomUUID(),true));
        assertNull(SellingPriceCurrency.forBaseCurrency(price,UUID.randomUUID(),false));
        assertNull(SellingPriceCurrency.forBaseCurrency(null,null,false));
    }
}
