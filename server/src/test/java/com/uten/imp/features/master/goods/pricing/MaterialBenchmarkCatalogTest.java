package com.uten.imp.features.master.goods.pricing;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import java.util.Arrays;
import static org.junit.jupiter.api.Assertions.*;

class MaterialBenchmarkCatalogTest {
    private final MaterialBenchmarkCatalog catalog=new MaterialBenchmarkCatalog(new ObjectMapper());

    @Test void canonicalSeriesAcceptMonthBoundsWithoutRestrictingValidDeliveryYears(){
        assertEquals(3,catalog.all().size());
        for(var benchmark:catalog.all()){
            for(String yearMonth:Arrays.asList("2601","2612","9901","0012")){
                assertTrue(MaterialBenchmarkCatalog.validContract(benchmark,benchmark.symbol()+yearMonth),
                        benchmark.symbol()+yearMonth);
            }
        }
    }

    @Test void malformedContractsAndInvalidMonthsAreRejectedWithoutEscapingTheReaderBoundary(){
        assertEquals(3,catalog.all().size());
        for(var benchmark:catalog.all()){
            String symbol=benchmark.symbol();
            for(String value:Arrays.asList(null,"",symbol,symbol+"2600",symbol+"2613",symbol+"2699",
                    symbol+"260",symbol+"26001",symbol+"26ab",symbol+"26+1",symbol+"26\uFF10\uFF11",
                    symbol+"26\u0660\u0661",symbol.toUpperCase(java.util.Locale.ROOT)+"2601",
                    " "+symbol+"2601",symbol+"2601 ",symbol+"2601\n","other2601")){
                assertFalse(MaterialBenchmarkCatalog.validContract(benchmark,value),String.valueOf(value));
            }
        }
    }
}
