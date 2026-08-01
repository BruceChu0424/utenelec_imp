package com.uten.imp.features.sales.ret;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class SalesReturnQualityIdempotencyWiringTest {

    @Test
    void replayCheckPrecedesEveryDispositionSideEffect() throws IOException {
        String source = Files.readString(
                Path.of("src/main/java/com/uten/imp/features/sales/ret/SalesReturnQualityService.java"),
                StandardCharsets.UTF_8);
        String method = source.substring(
                source.indexOf("public List<ReturnQualityItemDto> dispose("),
                source.indexOf("private boolean isDispositionReplay("));

        assertBefore(method, "if (isDispositionReplay(", "stockService.recordMovement(");
        assertBefore(method, "if (isDispositionReplay(", "UPDATE sales_return_quality_items");
        assertBefore(method, "if (isDispositionReplay(", "appendEvent(eventId");
        assertThat(method)
                .contains("normalizeIdempotencyKey(request.idempotencyKey())")
                .contains("dispositionEventId(qualityItemId, idempotencyKey)");
    }

    private static void assertBefore(String source, String guard, String effect) {
        assertThat(source.indexOf(guard)).isGreaterThanOrEqualTo(0);
        assertThat(source.indexOf(effect)).isGreaterThanOrEqualTo(0);
        assertThat(source.indexOf(guard)).isLessThan(source.indexOf(effect));
    }
}
