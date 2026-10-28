package com.uten.imp.features.finance.report;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.asset.FixedAssetService;
import com.uten.imp.features.finance.gl.GlReportService;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import java.time.LocalDate;
import java.util.Map;
import java.util.Set;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Fixed layouts and true paged schedules require company authority before any read or typed probe. */
class GlFaCompanyReportAccessTest {
    private static final LocalDate DATE=LocalDate.of(2026,10,31);
    @ParameterizedTest @ValueSource(strings={"trial-balance","balance-sheet","profit-annual","profit-monthly","manufacturing-expense","admin-expense","sales-expense","operating-pl","depreciation","amortization"})
    void oldAndTypedEntriesRejectBeforeAnyLedgerSourceOrFinancialProbe(String kind)throws Exception{
        EntityManager em=mock(EntityManager.class);TxSessionVars tx=mock(TxSessionVars.class);
        var access=mock(FinanceDocumentAccessPolicy.class);when(access.scope()).thenReturn(new OwnerScope(false,Set.of(java.util.UUID.randomUUID())));
        // Keep the production row-source collaborator package-private; tests do not widen its API.
        Class<?> lineType=Class.forName("com.uten.imp.features.finance.gl.GlReportLineSource");Object lines=mock(lineType);
        var constructor=GlReportService.class.getDeclaredConstructor(EntityManager.class,lineType,FinanceDocumentAccessPolicy.class);
        constructor.setAccessible(true);var gl=constructor.newInstance(em,lines,access);var assets=new FixedAssetService(em,tx,access);
        for(FinanceReportColumnOptions options:new FinanceReportColumnOptions[]{null,
                new FinanceReportColumnOptions(Map.of("search.amountLocal","NaN","search.__private","probe"),"amountLocal","desc")}){
            assertThatThrownBy(()->invoke(kind,gl,assets,options)).isInstanceOfSatisfying(ApiException.class,failure->{
                assertThat(failure.getCode()).isEqualTo(ErrorCode.FORBIDDEN);assertThat(failure.getMessage()).contains("finance:view:all");
            });
        }
        verifyNoInteractions(em,lines,tx);verify(access,atLeast(2)).scope();
    }
    private static ReportTableResponse invoke(String kind,GlReportService gl,FixedAssetService assets,FinanceReportColumnOptions options){
        if(options==null)return switch(kind){case "trial-balance"->gl.trialBalance(DATE,DATE,1,20);case "balance-sheet"->gl.balanceSheet(DATE);
            case "profit-annual"->gl.profitAnnual(2026);case "profit-monthly"->gl.profitMonthly(2026,10);case "manufacturing-expense"->gl.manufacturingExpense(2026);
            case "admin-expense"->gl.adminExpense(2026);case "sales-expense"->gl.salesExpense(2026);case "operating-pl"->gl.operatingPl(2026,10);
            case "depreciation"->assets.depreciationSchedule();default->assets.amortizationSchedule();};
        return switch(kind){case "trial-balance"->gl.trialBalance(DATE,DATE,1,20,options);case "balance-sheet"->gl.balanceSheet(DATE,options);
            case "profit-annual"->gl.profitAnnual(2026,options);case "profit-monthly"->gl.profitMonthly(2026,10,options);case "manufacturing-expense"->gl.manufacturingExpense(2026,options);
            case "admin-expense"->gl.adminExpense(2026,options);case "sales-expense"->gl.salesExpense(2026,options);case "operating-pl"->gl.operatingPlPage(2026,10,1,20,options);
            case "depreciation"->assets.depreciationSchedule(1,20,options);default->assets.amortizationSchedule(1,20,options);};
    }
}
