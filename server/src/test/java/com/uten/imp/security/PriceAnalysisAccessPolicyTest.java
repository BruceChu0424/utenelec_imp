package com.uten.imp.security;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.file.*;
import java.util.*;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class PriceAnalysisAccessPolicyTest {
    @Test void sharedDartAndJavaCapabilityCases() throws Exception {
        Path path=Path.of("../contracts/price-analysis-access/v1.json");
        if(!Files.exists(path))path=Path.of("contracts/price-analysis-access/v1.json");
        var fixture=new ObjectMapper().readTree(Files.readString(path));
        for(var row:fixture.path("cases")) {
            Set<String> grants=new HashSet<>();row.path("permissions").forEach(p->grants.add(p.asText()));
            boolean admin=row.path("superAdmin").asBoolean();
            List<String> analyze=new ArrayList<>(),history=new ArrayList<>();
            for(var kind:PriceAnalysisAccessPolicy.KINDS) {
                if(PriceAnalysisAccessPolicy.canAnalyze(grants,admin,kind))analyze.add(kind);
                if(PriceAnalysisAccessPolicy.canReadHistory(grants,admin,kind))history.add(kind);
            }
            List<String> expectedAnalysis=new ArrayList<>(),expectedHistory=new ArrayList<>();
            row.path("analyze").forEach(k->expectedAnalysis.add(k.asText()));row.path("history").forEach(k->expectedHistory.add(k.asText()));
            assertThat(analyze).as(row.path("name").asText()).isEqualTo(expectedAnalysis);
            assertThat(history).as(row.path("name").asText()).isEqualTo(expectedHistory);
            assertThat(PriceAnalysisAccessPolicy.canOpen(grants,admin)).isEqualTo(!history.isEmpty());
        }
        assertThat(PriceAnalysisAccessPolicy.canAnalyze(Set.of(),true,null)).isFalse();
        assertThat(PriceAnalysisAccessPolicy.canAnalyze(Set.of(),true,"UNKNOWN")).isFalse();
    }
}
