package com.uten.imp.common.util;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import static org.junit.jupiter.api.Assertions.*;

class ColumnKeywordSearchTest {
    @Test void validatedKeysComeFromTheServerDeclarationWhileValuesRemainUnmodifiedData() {
        String declared=new String("amount");
        String requested=new String("amount");
        var result=ColumnKeywordSearch.validate(Map.of(requested,"  >=0.0000000001  "),Set.of(declared));
        assertSame(declared,result.keySet().iterator().next());
        assertEquals(">=0.0000000001",result.get(declared));
        assertNotSame(requested,result.keySet().iterator().next());
    }

    @Test void unknownKeysFailEvenWhenTheirValuesAreEmptyAndKnownRequestOrderIsPreserved() {
        assertThrows(ApiException.class,()->ColumnKeywordSearch.validate(Map.of("amount) OR TRUE --",""),Set.of("amount")));
        Map<String,String> requested=new LinkedHashMap<>();
        requested.put("second","2");requested.put("first","1");
        assertEquals(java.util.List.of("second","first"),ColumnKeywordSearch.validate(requested,Set.of("first","second"))
                .keySet().stream().toList());
    }
}
