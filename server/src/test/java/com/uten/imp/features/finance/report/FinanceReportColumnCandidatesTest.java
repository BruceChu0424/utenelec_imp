package com.uten.imp.features.finance.report;

import com.uten.imp.common.web.*;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.asset.FixedAssetService;
import com.uten.imp.features.finance.cost.FinanceCostService;
import com.uten.imp.features.finance.gl.GlReportService;
import com.uten.imp.features.finance.statement.FinanceStatementService;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import jakarta.persistence.EntityManager;
import java.util.*;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class FinanceReportColumnCandidatesTest {
    private final EntityManager em=mock(EntityManager.class);
    private final FinanceDocumentAccessPolicy access=mock(FinanceDocumentAccessPolicy.class);
    private final FinanceStatementService statements=mock(FinanceStatementService.class);
    private final FinanceReportService service=new FinanceReportService(em,access,mock(SystemSettingsService.class),statements,
            mock(FinanceCostService.class),mock(GlReportService.class),mock(FixedAssetService.class),mock(PartyMonthlySummaryService.class));
    @Test void candidateReadersCannotBypassCompanyOrAccountAccess() {
        when(access.scope()).thenReturn(new OwnerScope(false,Set.of(UUID.randomUUID())));
        for(String report:List.of("statements/client","cost/product","gl/balance-sheet"))
            assertThatThrownBy(()->service.columnCandidates(report,"clientName",Map.of()))
                    .isInstanceOf(ApiException.class).hasMessageContaining("finance:view:all");
        assertThatThrownBy(()->service.columnCandidates("account/statement","billNo",Map.of()))
                .isInstanceOf(ApiException.class).hasMessageContaining("账户流水要求同时具备");
        verifyNoInteractions(em,statements);
        assertThat(FinanceReportColumnCandidates.current()).isNull();
    }
    @Test void ownColumnConditionIsRemovedOtherConditionsAndEmptyAuthorityRemain() {
        when(access.scope()).thenReturn(new OwnerScope(true,Set.of()));
        when(statements.clientStatement(any(),any(),any(),anyInt(),anyInt(),any())).thenAnswer(call->{
            FinanceReportColumnOptions options=call.getArgument(5);
            assertThat(options.filters()).containsExactly(Map.entry("search.goodsName","开关"));
            return new ReportTableResponse(List.of(ReportColumn.text("clientName","客户名称",180)),List.of(),Map.of(),1,1,0,0);
        });
        try(var nativeScope=NativeFacetCandidates.open("value","优腾",1,100)) {
            var response=service.columnCandidates("statements/client","clientName",Map.of(
                    "f.search.clientName","旧客户","f.clientName","旧ID","f.search.goodsName","开关"));
            assertThat(nativeScope.result(response,"current").items()).isEmpty();
        }
        verifyNoInteractions(em);assertThat(FinanceReportColumnCandidates.current()).isNull();
    }
    @Test void emptyAccountCandidateKeepsTheOriginalAccountAuthoritiesWithoutCompanyScope() {
        when(access.hasAuthority(anyString())).thenReturn(true);
        try(var nativeScope=NativeFacetCandidates.open("value","",1,100)) {
            var response=service.columnCandidates("account/statement","billNo",Map.of());
            assertThat(nativeScope.result(response,"current").items()).isEmpty();
        }
        verify(access,never()).scope();verifyNoInteractions(em);
        assertThat(FinanceReportColumnCandidates.current()).isNull();
    }
    @Test void hiddenUnknownAndNumericColumnsFailBeforeAnyCandidateSql() {
        for(String column:List.of("__private","unknown","amount")) {
            assertThatThrownBy(()->{
                try(var candidates=FinanceReportColumnCandidates.open(column)) {
                    candidates.requireVisibleText(List.of(ReportColumn.text("clientName","客户名称",180),
                            ReportColumn.money("amount","金额")),Set.of());
                }
            }).isInstanceOf(ApiException.class);
        }
        assertThat(FinanceReportColumnCandidates.current()).isNull();verifyNoInteractions(em);
    }
}
