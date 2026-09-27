package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.PreplanAnalysisPegPort.FinishedInboundSlice;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class PreplanMakeInboundSplitTest {
    private static final UUID PLAN = UUID.fromString("00000000-0000-0000-0000-000000000010");
    private static final UUID GOODS = UUID.fromString("00000000-0000-0000-0000-000000000020");

    private static FinishedInboundSlice slice(int id, UUID plan, String qty) {
        return new FinishedInboundSlice(new UUID(0, id), plan, GOODS, null, new BigDecimal(qty));
    }

    private static BigDecimal total(List<FinishedInboundSlice> lines) {
        return lines.stream().map(FinishedInboundSlice::baseQty).reduce(BigDecimal.ZERO, BigDecimal::add);
    }

    @Test void siblingSlicesShareOnePrivateBudgetAndDoNotMutateTheirInputs() {
        var lines = List.of(slice(1, PLAN, "2"), slice(2, PLAN, "3"));
        var budgets = Map.of(PLAN, new BigDecimal("3"));
        var split = PreplanAnalysisStockPegService.splitMakeInbound(lines, budgets, Set.of());
        assertThat(total(split.privateLines())).isEqualByComparingTo("3");
        assertThat(total(split.publicLines())).isEqualByComparingTo("2");
        assertThat(split.publicLines().getFirst().stockDocumentItemId()).isEqualTo(lines.getLast().stockDocumentItemId());
        assertThat(budgets.get(PLAN)).isEqualByComparingTo("3");
        assertThat(total(lines)).isEqualByComparingTo("5");
    }

    @Test void explicitPublicOutputDoesNotConsumePrivateBudgetEvenWhenItArrivesFirst() {
        var publicLine = slice(1, PLAN, "2");
        var privateLine = slice(2, PLAN, "3");
        var split = PreplanAnalysisStockPegService.splitMakeInbound(List.of(publicLine, privateLine),
                Map.of(PLAN, new BigDecimal("3")), Set.of(publicLine.stockDocumentItemId()));
        assertThat(split.privateLines()).containsExactly(privateLine);
        assertThat(split.publicLines()).containsExactly(publicLine);
    }

    @Test void independentPlansAndFractionalBaseUnitsStaySeparate() {
        UUID secondPlan = new UUID(0, 11);
        var split = PreplanAnalysisStockPegService.splitMakeInbound(
                List.of(slice(3, PLAN, "0.0002"), slice(1, PLAN, "0.0003"), slice(2, secondPlan, "20")),
                Map.of(PLAN, new BigDecimal("0.0004"), secondPlan, new BigDecimal("10")), Set.of());
        assertThat(total(split.privateLines())).isEqualByComparingTo("10.0004");
        assertThat(total(split.publicLines())).isEqualByComparingTo("10.0001");
        assertThat(split.publicLines().stream().filter(line -> line.planItemId().equals(PLAN))
                .map(FinishedInboundSlice::baseQty).reduce(BigDecimal.ZERO, BigDecimal::add))
                .isEqualByComparingTo("0.0001");
    }
}
