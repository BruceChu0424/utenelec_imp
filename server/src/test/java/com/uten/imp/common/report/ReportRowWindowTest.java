package com.uten.imp.common.report;

import org.junit.jupiter.api.Test;

import java.util.Map;
import java.util.stream.IntStream;

import static org.assertj.core.api.Assertions.assertThat;

class ReportRowWindowTest {
    @Test void walksEveryCalculatedRowButRetainsOnlyTheRequestedPage() {
        var window = new ReportRowWindow(2, 50);
        IntStream.range(0, 101).forEach(value -> window.accept(Map.of("id", value)));
        assertThat(window.count()).isEqualTo(101);
        assertThat(window.rows()).extracting(row -> row.get("id"))
                .containsExactlyElementsOf(IntStream.range(50, 100).boxed().toList());
    }

    @Test void extremeOffsetsDoNotWrapAndInvalidPageSizesStayBounded() {
        var beyond = new ReportRowWindow(Integer.MAX_VALUE, Integer.MAX_VALUE);
        IntStream.range(0, 1000).forEach(value -> beyond.accept(Map.of("id", value)));
        assertThat(beyond.rows()).isEmpty();assertThat(beyond.size()).isEqualTo(500);
        assertThat(beyond.count()).isEqualTo(1000);
        var first = new ReportRowWindow(Integer.MIN_VALUE, 0);
        first.accept(Map.of("id", 1));first.accept(Map.of("id", 2));
        assertThat(first.page()).isEqualTo(1);assertThat(first.size()).isEqualTo(1);
        assertThat(first.rows()).containsExactly(Map.of("id", 1));
    }
}
