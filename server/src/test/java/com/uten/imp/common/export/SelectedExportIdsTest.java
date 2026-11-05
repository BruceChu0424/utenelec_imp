package com.uten.imp.common.export;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.util.List;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;

class SelectedExportIdsTest {
    @Test void sameSourceFixtureIsConsumedByJavaAndNativeMutationContract() throws Exception {
        var fixture=new com.fasterxml.jackson.databind.ObjectMapper().readTree(java.nio.file.Path.of("..","contracts","table-output-selection","v1.json").toFile());
        for(var sample:fixture.get("cases")){
            String raw=sample.get("raw").isNull()?null:sample.get("raw").asText();
            if(sample.get("valid").asBoolean())assertDoesNotThrow(()->SelectedExportIds.parse(raw),sample.get("name").asText());
            else assertThrows(ApiException.class,()->SelectedExportIds.parse(raw),sample.get("name").asText());
        }
    }
    @Test void absentMeansAllAndExplicitSelectionRetainsStableOrder() {
        assertNull(SelectedExportIds.parse(null));
        UUID first=UUID.randomUUID(),second=UUID.randomUUID();
        assertEquals(List.of(first,second),SelectedExportIds.parse("[\""+first+"\",\""+second+"\"]"));
    }
    @Test void malformedEmptyAndDuplicateSelectionsAreRejected() {
        String id=UUID.randomUUID().toString();
        for(String input:List.of(" ","null","{}","[]","[null]","[1]","[\"unknown\"]",
                "[\""+id+"\",\""+id+"\"]"))
            assertThrows(ApiException.class,()->SelectedExportIds.parse(input),input);
    }
    @Test void fiftyThousandIdentitiesAreAcceptedWithoutTruncation() {
        var ids=java.util.stream.IntStream.rangeClosed(1,50000)
                .mapToObj(index->new UUID(1,index)).toList();
        String input=ids.stream().map(id->"\""+id+"\"").collect(java.util.stream.Collectors.joining(",","[","]"));
        assertEquals(ids,SelectedExportIds.parse(input));
        assertThrows(ApiException.class,()->SelectedExportIds.parse(input.substring(0,input.length()-1)
                +",\""+new UUID(1,50001)+"\"]"));
    }
}
