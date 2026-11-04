package com.uten.imp.features.finance.payables;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.ProcurementCreditBookAllocationPort.BookAllocationPlan;
import org.junit.jupiter.api.Test;
import java.util.UUID;
import static org.assertj.core.api.Assertions.assertThat;

/** The immutable legacy plan JSON must not gain a null field that would invalidate existing database proofs. */
class ProcurementCreditBookSourceContractTest {
    private final ObjectMapper json=new ObjectMapper();
    @Test void oldPlanKeepsItsExactMoneyAndOriginalJsonShape()throws Exception{
        UUID ap=UUID.randomUUID();String source=plan(ap,null);
        var parsed=json.readValue(source,BookAllocationPlan.class);
        assertThat(parsed.sourceApLedgerId()).isEqualTo(ap);assertThat(parsed.sourceCandidateId()).isNull();
        assertThat(parsed.amountOriginal().toPlainString()).isEqualTo("12.1234567890123456789");
        String written=json.writeValueAsString(parsed);assertThat(json.readTree(written).has("sourceCandidateId")).isFalse();
        assertThat(json.readTree(written)).isEqualTo(json.readTree(source));
    }
    @Test void pendingReceiptIsASeparateUuidAndNeverSerializedAsAnAp()throws Exception{
        UUID candidate=UUID.randomUUID();var parsed=json.readValue(plan(null,candidate),BookAllocationPlan.class);
        assertThat(parsed.sourceApLedgerId()).isNull();assertThat(parsed.sourceCandidateId()).isEqualTo(candidate);
        var written=json.readTree(json.writeValueAsString(parsed));assertThat(written.get("sourceApLedgerId").isNull()).isTrue();
        assertThat(written.get("sourceCandidateId").asText()).isEqualTo(candidate.toString());
    }
    private static String plan(UUID ap,UUID candidate){return """
        {"sourceApLedgerId":%s,%s"amountOriginal":12.1234567890123456789,"amountLocal":84.8641975230864197523,
          "offsetOriginal":0,"offsetLocal":0,"creditRemainingOriginal":12.1234567890123456789,"creditRemainingLocal":84.8641975230864197523,
          "sourceBeforeOriginal":80,"sourceBeforeLocal":560,"sourceAfterOriginal":80,"sourceAfterLocal":560,"basis":[]}
        """.formatted(ap==null?"null":"\""+ap+"\"",candidate==null?"":"\"sourceCandidateId\":\""+candidate+"\",");}
}
