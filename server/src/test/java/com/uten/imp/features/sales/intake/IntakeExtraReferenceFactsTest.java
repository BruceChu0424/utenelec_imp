package com.uten.imp.features.sales.intake;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import java.util.*;
import static org.assertj.core.api.Assertions.assertThat;

class IntakeExtraReferenceFactsTest {
    private final ObjectMapper json=new ObjectMapper();
    @Test void pdfFactsMustBePresentAndIdentifiersRetainLeadingZeroes() throws Exception {
        var context=FakeJobContext.of("facts.pdf","PDF",new byte[0],"quote");
        var run=new SalesIntakePipeline.Run(context,IntakeParams.parse(context.params()),new IntakeAi(context,json));
        SalesIntakePipeline.absorbExtraFields(run,"P1R1",json.readTree("""
            [{"label":"Certification","value":"CE"},{"label":"Parcel code","value":"00017"},
             {"label":"Freight","value":"2.50"},{"label":"Invented","value":"99"},
             {"label":"Bank account","value":"123456"}]
            """),"Certification CE Parcel code 00017 Freight 2.50 Bank account 123456");
        assertThat(run.extraColumns).hasSize(3);
        var code=run.extraColumns.stream().filter(column->"Parcel code".equals(column.get("label"))).findFirst().orElseThrow();
        assertThat(code).containsEntry("dataType","TEXT").containsEntry("suggestedOperation","NONE");
        assertThat(run.extraValues.get("P1R1").get(code.get("key"))).isEqualTo("00017");
        assertThat(run.extraColumns).allMatch(column->"NONE".equals(column.get("suggestedOperation")));
    }
    @Test void repeatedHeadersReuseOneDefinitionAndMixedTextNeverBecomesZero() throws Exception {
        var context=FakeJobContext.of("facts.png","PNG",new byte[0],"quote");
        var run=new SalesIntakePipeline.Run(context,IntakeParams.parse(context.params()),new IntakeAi(context,json));
        SalesIntakePipeline.absorbExtraFields(run,"I1R1",json.readTree("[{\"label\":\"Freight\",\"value\":\"3\"}]"),null);
        SalesIntakePipeline.absorbExtraFields(run,"I1R2",json.readTree("[{\"label\":\"Freight\",\"value\":\"Included\"}]"),null);
        assertThat(run.extraColumns).hasSize(1);
        assertThat(run.extraColumns.getFirst().get("dataType")).isEqualTo("TEXT");
        assertThat(run.extraValues.get("I1R2").values()).containsExactly("Included");
    }
}
