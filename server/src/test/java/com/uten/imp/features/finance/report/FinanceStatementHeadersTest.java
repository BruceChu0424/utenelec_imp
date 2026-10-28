package com.uten.imp.features.finance.report;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ContactSensitiveFilter;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class FinanceStatementHeadersTest {
    @Test void originalAmountConditionsAndOrderingRequireOneExactCurrency() {
        assertThatThrownBy(()->new PartyStatementHeaderQuery(Map.of("search.balanceOriginal",">=10"),false,true))
                .isInstanceOf(ApiException.class).hasMessageContaining("币别");
        assertThatThrownBy(()->new PartyStatementHeaderQuery(Map.of(),false,true).orderBy("salesOriginal","desc"))
                .isInstanceOf(ApiException.class).hasMessageContaining("币别");
        assertThatThrownBy(()->new PartyStatementHeaderQuery(Map.of("currencyCode","USD","search.salesOriginal","1"),false,true))
                .isInstanceOf(ApiException.class);
    }
    @Test void typedFactsKeepExactDecimalsAndCalendarDatesAfterTheProjection() {
        var query=new PartyStatementHeaderQuery(Map.of("currencyCode",UUID.randomUUID().toString(),
                "search.balanceOriginal",">=9007199254740993.0001","search.billDate","2026-10","search.refNo","A B"),false,true);
        var criteria=query.criteria();
        assertThat(criteria.predicate()).contains("report.\"balanceOriginal\"", "report.\"billDate\"", "report.\"__currencyId\"");
        assertThat(criteria.parameters().values()).contains(new BigDecimal("9007199254740993.0001"),
                LocalDate.of(2026,10,1),LocalDate.of(2026,11,1));
        assertThat(query.orderBy("balanceOriginal","desc")).startsWith("report.\"balanceOriginal\" DESC NULLS LAST,")
                .contains("eventOrder");
    }
    @Test void annualFieldsCannotProbeTheConstantTemplateReturnColumnOrRawInternals() {
        var annual=new PartyStatementHeaderQuery(Map.of("search.ym","2026-02"),true,false);
        assertThat(annual.keys()).doesNotContain("returned","__currencyId");
        assertThat(annual.criteria().predicate()).contains("to_date(report.ym,'YYYY-MM')");
        assertThatThrownBy(()->new PartyStatementHeaderQuery(Map.of("search.returned","0"),true,false)).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->new PartyStatementHeaderQuery(Map.of("search.__currencyId","secret"),false,false)).isInstanceOf(ApiException.class);
    }
    @Test void bodyOnlyContactFiltersShareTheSamePrivateExportParameters() {
        assertThat(FinanceReportHeaderRequest.filters(null)).isEmpty();
        assertThat(PartyStatementHeaderQuery.withKeyword(null,null)).isEmpty();
        assertThatThrownBy(()->FinanceReportHeaderRequest.requireBodyOnly(Map.of("f.search.phone","1234")))
                .isInstanceOf(ApiException.class);
        var body=new ContactSensitiveFilter(null,null,null,null,null,Map.of("phone","1234 5678"));
        var parameters=FinanceReportHeaderRequest.withContactBody(Map.of("f.search.receivable",">=25"),body);
        assertThat(FinanceReportHeaderRequest.filters(parameters))
                .containsEntry("search.phone","1234 5678").containsEntry("search.receivable",">=25");
        var where=new FinanceReportService.FinanceWhereBuilder("WHERE TRUE");
        new ArApOverviewHeaderQuery(FinanceReportHeaderRequest.filters(parameters)).apply(where);
        assertThat(where.build(null).sql()).contains("receivable", "phone").doesNotContain("1234");
    }
}
