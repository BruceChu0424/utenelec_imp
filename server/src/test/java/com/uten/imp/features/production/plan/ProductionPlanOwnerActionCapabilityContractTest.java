package com.uten.imp.features.production.plan;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class ProductionPlanOwnerActionCapabilityContractTest {

    @Test
    void allowedActionsSeparateOrdinaryWritesFromPooledApproval() throws Exception {
        String source = Files.readString(
                Path.of("src/main/java/com/uten/imp/features/production/plan/ProductionPlanService.java"),
                StandardCharsets.UTF_8);
        String method = lastMethod(source, " planDetailAllowedActions(");

        assertThat(method).contains(
                "ordinaryWritable = access.canWrite(plan.getMakerId(), access.scope())",
                "access.scope(\"production_plan:approve\")",
                "actions.add(\"EDIT\")",
                "actions.add(\"DELETE\")",
                "actions.add(\"APPROVE\")",
                "actions.add(\"REVERSE\")");
    }

    private static String lastMethod(String source, String signature) {
        int start = source.lastIndexOf(signature);
        assertThat(start).isGreaterThanOrEqualTo(0);
        int bodyStart = source.indexOf('{', start + signature.length());
        int depth = 0;
        for (int index = bodyStart; index < source.length(); index++) {
            char token = source.charAt(index);
            if (token == '{') depth++;
            if (token == '}' && --depth == 0) return source.substring(start, index + 1);
        }
        throw new IllegalStateException("Unclosed method");
    }
}
