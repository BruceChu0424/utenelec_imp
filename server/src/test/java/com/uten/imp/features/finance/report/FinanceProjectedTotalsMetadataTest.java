package com.uten.imp.features.finance.report;

import java.util.List;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class FinanceProjectedTotalsMetadataTest {
    @Test void missingCurrencyIdentityOrMaskedMoneyCannotBecomeAnUngroupedTotal() {
        var local=ReportColumn.money("local","本币").totaled("本币合计");
        var original=ReportColumn.money("original","原币").totaled("原币合计","currencyName","__currencyId");
        var name=ReportColumn.text("currencyName","币别");var identity=ReportColumn.text("__currencyId","");
        assertThat(FinanceProjectedReportTable.totalSpecs(List.of(local,original),List.of(local,original,name)))
                .extracting(com.uten.imp.common.report.ReportTotalsCalculator.Spec::key).containsExactly("local");
        assertThat(FinanceProjectedReportTable.totalSpecs(List.of(local,original),List.of(local,original,identity)))
                .extracting(com.uten.imp.common.report.ReportTotalsCalculator.Spec::key).containsExactly("local");
        var safe=FinanceProjectedReportTable.totalSpecs(List.of(local,original),List.of(local,original,name,identity));
        assertThat(safe).hasSize(2);assertThat(safe.getLast().groupKey()).isEqualTo("currencyName");
        assertThat(safe.getLast().groupIdentityKey()).isEqualTo("__currencyId");
        assertThat(FinanceProjectedReportTable.totalSpecs(List.of(local),List.of(local,original,name,identity)))
                .extracting(com.uten.imp.common.report.ReportTotalsCalculator.Spec::key).containsExactly("local");
    }
}
