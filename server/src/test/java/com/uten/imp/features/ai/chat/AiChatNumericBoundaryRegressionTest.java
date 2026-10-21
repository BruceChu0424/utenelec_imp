package com.uten.imp.features.ai.chat;

import org.junit.jupiter.api.Test;
import java.util.ArrayList;
import java.util.List;
import static org.assertj.core.api.Assertions.assertThat;

class AiChatNumericBoundaryRegressionTest {
    @Test
    void impossibleAndOverflowingCalculationsNeverBecomeTrustedDerivations() {
        for (String text : List.of("1 ÷ 0 = 0", "9".repeat(400) + " + 1 = 1", "1 + 1 = " + "9".repeat(400))) {
            var problems = new ArrayList<String>();
            AiChatAnswerGuard.checkArithmetic(text, problems);
            assertThat(problems).as(text).anyMatch(problem -> problem.startsWith("ARITHMETIC:"));
        }
        var valid = new ArrayList<String>();
        AiChatAnswerGuard.checkArithmetic("12.5 × 8 = 100", valid);
        assertThat(valid).isEmpty();
    }
}
