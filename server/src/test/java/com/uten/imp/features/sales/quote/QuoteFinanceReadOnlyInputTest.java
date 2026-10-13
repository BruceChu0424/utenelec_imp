package com.uten.imp.features.sales.quote;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.sales.quote.dto.QuoteFinanceEditRequest;
import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class QuoteFinanceReadOnlyInputTest {
    // Spring accepts unknown fields by default. Retired review inputs still must fail closed.
    private final ObjectMapper json = new ObjectMapper()
            .disable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES);

    @Test
    void originalPricingActionStillDeserializes() throws Exception {
        UUID item = UUID.randomUUID();
        var line = json.readValue("{\"itemId\":\"" + item + "\",\"discount\":0.9}",
                QuoteFinanceEditRequest.Line.class);
        assertThat(line.itemId()).isEqualTo(item);
        assertThat(line.discount()).isEqualByComparingTo("0.9");
    }

    @Test
    void retiredBusinessEditsAreRejectedEvenAlongsideAnAllowedPricingAction() {
        for (String input : new String[]{"\"qty\":5", "\"price\":11", "\"removed\":true"}) {
            assertThatThrownBy(() -> json.readValue("{\"itemId\":\"" + UUID.randomUUID()
                            + "\",\"discount\":0.9," + input + "}", QuoteFinanceEditRequest.Line.class))
                    .hasRootCauseInstanceOf(IllegalArgumentException.class);
        }
    }
}
