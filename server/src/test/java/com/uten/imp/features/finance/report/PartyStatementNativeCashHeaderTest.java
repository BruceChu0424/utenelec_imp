package com.uten.imp.features.finance.report;

import com.uten.imp.common.web.ApiException;
import java.util.Map;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class PartyStatementNativeCashHeaderTest {
    @Test void actualCashIsAnExplicitApOnlyLocalMoneyColumn() {
        var query=new PartyStatementHeaderQuery(Map.of(),false,false,true);
        assertThat(query.keys()).contains("actualCashLocal");
        assertThat(query.orderBy("actualCashLocal","desc")).startsWith("report.\"actualCashLocal\" DESC NULLS LAST,");
        assertThat(query.withoutFacet("type",false).keys()).contains("actualCashLocal");
        assertThat(new PartyStatementHeaderQuery(Map.of(),true,false,true).keys()).contains("actualCashLocal");
        assertThat(new PartyStatementHeaderQuery(Map.of("type","预付应用"),false,true,true).keys()).contains("type","actualCashLocal");
    }
    @Test void existingArAndLegacyConstructorsDoNotAdvertiseOrAcceptTheApCashColumn() {
        assertThat(new PartyStatementHeaderQuery(Map.of(),false,false).keys()).doesNotContain("actualCashLocal");
        assertThat(new PartyStatementHeaderQuery(Map.of(),true,false).keys()).doesNotContain("actualCashLocal");
        assertThatThrownBy(()->new PartyStatementHeaderQuery(Map.of("search.actualCashLocal","1"),false,false)).isInstanceOf(ApiException.class);
    }
    @Test void publicApColumnsNameBothBookDirectionsAndCashWhileArKeepsItsExistingColumns() {
        var access=mock(com.uten.imp.features.finance.FinanceDocumentAccessPolicy.class);
        when(access.scope()).thenReturn(new com.uten.imp.security.OwnerVisibility.OwnerScope(true,java.util.Set.of()));
        var service=new FinanceReportService(null,access,null,null,null,null,null,null);
        for(boolean detail:java.util.List.of(false,true)) {
            var report=detail?service.partyStatementDetail(null,"AP",null,null,1,50):service.partyStatementFlow(null,"AP",null,null,1,50);
            var columns=report.columns();var keys=columns.stream().map(ReportColumn::key).toList();
            assertThat(keys.indexOf("type")).isEqualTo(keys.indexOf("refNo")+1);
            assertThat(keys.stream().filter("type"::equals)).hasSize(1);
            assertThat(keys.indexOf("actualCashLocal")).isEqualTo(keys.indexOf("receiptLocal")+1);
            assertThat(columns.stream().filter(c->c.key().equals("salesLocal")).findFirst().orElseThrow().label()).isEqualTo("往来立账金额(本)");
            assertThat(columns.stream().filter(c->c.key().equals("salesRate")).findFirst().orElseThrow().label()).isEqualTo("往来立账汇率");
            assertThat(columns.stream().filter(c->c.key().equals("receiptLocal")).findFirst().orElseThrow().label()).isEqualTo("往来冲减金额(本)");
        }
        var annual=service.partyAnnualStatement(null,"AP",2026,1,50);var keys=annual.columns().stream().map(ReportColumn::key).toList();
        assertThat(keys.indexOf("actualCashLocal")).isEqualTo(keys.indexOf("settled")+1);
        assertThat(annual.columns().stream().filter(c->c.key().equals("posted")).findFirst().orElseThrow().label()).isEqualTo("往来立账金额");
        assertThat(annual.columns().stream().filter(c->c.key().equals("settled")).findFirst().orElseThrow().label()).isEqualTo("往来冲减金额");
        var ar=service.partyStatementFlow(null,"AR",null,null,1,50);assertThat(ar.columns()).extracting(ReportColumn::key).doesNotContain("actualCashLocal","type");
        assertThat(ar.columns().stream().filter(c->c.key().equals("salesLocal")).findFirst().orElseThrow().label()).isEqualTo("销售金额(本)");
        var arAnnual=service.partyAnnualStatement(null,"AR",2026,1,50);
        assertThat(arAnnual.columns().stream().filter(c->c.key().equals("posted")).findFirst().orElseThrow().label()).isEqualTo("发货金额");
        assertThat(arAnnual.columns().stream().filter(c->c.key().equals("settled")).findFirst().orElseThrow().label()).isEqualTo("回款金额");
    }
}
