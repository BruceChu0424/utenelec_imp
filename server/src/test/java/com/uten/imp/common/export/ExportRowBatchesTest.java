package com.uten.imp.common.export;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.stream.IntStream;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ExportRowBatchesTest {
    private final List<ExportColumn> columns = List.of(new ExportColumn("id", "身份", "number"));

    @Test void boundedBatchesKeepOrderAndEmitTheFinalPartialBatchExactlyOnce() {
        List<ExportPayload> pages = new ArrayList<>();
        try (var scope = ExportPageSink.open(pages::add)) {
            var output = new ExportRowBatches(columns, 1001);
            IntStream.range(0, 1001).forEach(value -> output.accept(Map.of("id", value)));
            assertThat(output.finish()).isEqualTo(1001);
            assertThatThrownBy(output::finish).isInstanceOf(IllegalStateException.class);
        }
        assertThat(pages).extracting(page -> page.rows().size()).containsExactly(500, 500, 1);
        assertThat(pages.stream().flatMap(page -> page.rows().stream()).map(row -> row.get("id")))
                .containsExactlyElementsOf(IntStream.range(0, 1001).boxed().toList());
    }

    @Test void limitAndUnknownSinkFailuresPoisonTheOutputRatherThanAllowingAPartialSuccess() {
        List<ExportPayload> pages = new ArrayList<>();
        try (var scope = ExportPageSink.open(pages::add)) {
            var output = new ExportRowBatches(columns, 500);
            IntStream.range(0, 500).forEach(value -> output.accept(Map.of("id", value)));
            assertThatThrownBy(() -> output.accept(Map.of("id", 501))).isInstanceOf(ApiException.class);
            assertThatThrownBy(output::finish).isInstanceOf(IllegalStateException.class);
        }
        assertThat(pages).hasSize(1);
        try (var scope = ExportPageSink.open(page -> { throw new IllegalStateException("write outcome unknown"); })) {
            var output = new ExportRowBatches(columns, 500);
            output.accept(Map.of("id", 1));
            assertThatThrownBy(output::finish).hasMessage("write outcome unknown");
            assertThatThrownBy(output::finish).hasMessage("Report output is already finished");
        }
    }
}
