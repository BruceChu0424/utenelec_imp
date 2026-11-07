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
            var output = new ExportRowBatches(columns);
            IntStream.range(0, 1001).forEach(value -> output.accept(Map.of("id", value)));
            assertThat(output.finish()).isEqualTo(1001);
            assertThatThrownBy(output::finish).isInstanceOf(IllegalStateException.class);
        }
        assertThat(pages).extracting(page -> page.rows().size()).containsExactly(500, 500, 1);
        assertThat(pages.stream().flatMap(page -> page.rows().stream()).map(row -> row.get("id")))
                .containsExactlyElementsOf(IntStream.range(0, 1001).boxed().toList());
    }

    @Test void calculatedRowsBeyondTheOldConfiguredLimitRemainCompleteAndOrdered() {
        List<ExportPayload> pages = new ArrayList<>();
        try (var scope = ExportPageSink.open(pages::add)) {
            var output = new ExportRowBatches(columns);
            IntStream.range(0,1201).forEach(value->output.accept(Map.of("id",value)));
            assertThat(output.finish()).isEqualTo(1201);
        }
        assertThat(pages).extracting(page->page.rows().size()).containsExactly(500,500,201);
        assertThat(pages).flatExtracting(ExportPayload::rows).extracting(row->row.get("id"))
                .containsExactlyElementsOf(IntStream.range(0,1201).boxed().toList());
    }

    @Test void cancellationAndUnknownSinkFailuresPoisonOutputRatherThanAllowingPartialSuccess() {
        try(var scope=ExportPageSink.open(page->{})) {
            var output=new ExportRowBatches(columns);
            IntStream.range(0,500).forEach(value->output.accept(Map.of("id",value)));
            Thread.currentThread().interrupt();
            try{assertThatThrownBy(()->output.accept(Map.of("id",500))).isInstanceOf(java.util.concurrent.CancellationException.class);}
            finally{Thread.interrupted();}
            assertThatThrownBy(output::finish).isInstanceOf(IllegalStateException.class);
        }
        try (var scope = ExportPageSink.open(page -> { throw new IllegalStateException("write outcome unknown"); })) {
            var output = new ExportRowBatches(columns);
            output.accept(Map.of("id", 1));
            assertThatThrownBy(output::finish).hasMessage("write outcome unknown");
            assertThatThrownBy(output::finish).hasMessage("Report output is already finished");
        }
    }
}
