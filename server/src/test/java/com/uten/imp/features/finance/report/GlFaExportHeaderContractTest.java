package com.uten.imp.features.finance.report;

import com.uten.imp.common.export.ExportPageSink;
import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.finance.asset.FixedAssetService;
import com.uten.imp.features.finance.gl.GlReportService;
import com.uten.imp.features.finance.cost.FinanceCostService;
import com.uten.imp.features.finance.statement.FinanceStatementService;
import com.uten.imp.support.FinanceReportTestAccess;
import jakarta.persistence.EntityManager;
import java.util.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Actual export dispatcher must preserve every header in both synchronous and worker paths. */
class GlFaExportHeaderContractTest {
    private record Call(String method,FinanceReportColumnOptions options) { }
    @ParameterizedTest @ValueSource(strings={"gl/trial-balance","gl/balance-sheet","gl/profit-annual","gl/profit-monthly","gl/manufacturing-expense","gl/admin-expense","gl/sales-expense","gl/operating-pl","fa/depreciation-schedule","fa/amortization-schedule"})
    void bothExportPathsForwardTheSameExactConditionsAndKeepFixedOrdering(String report){
        String key=switch(report){case "gl/trial-balance"->"closing";case "gl/balance-sheet"->"periodEnd";
            case "gl/profit-monthly"->"monthAmount";case "gl/operating-pl"->"amount";
            case "fa/depreciation-schedule"->"accumDep";case "fa/amortization-schedule"->"accumAmt";default->"m1";};
        String expression="9007199254740993.0001..9007199254740993.0002";
        String sort=report.equals("gl/trial-balance")?"styleCode":report.startsWith("fa/")?"code":null;
        String order=sort==null?null:"desc";
        var calls=new ArrayList<Call>();var empty=new ReportTableResponse(List.of(),List.of(),Map.of(),1,500,0,0);
        org.mockito.stubbing.Answer<Object> reader=call->{
            if(call.getMethod().getReturnType()==ReportTableResponse.class){
                var options=Arrays.stream(call.getArguments()).filter(FinanceReportColumnOptions.class::isInstance)
                        .map(FinanceReportColumnOptions.class::cast).findFirst().orElseThrow();
                calls.add(new Call(call.getMethod().getName(),options));return empty;
            }
            return org.mockito.Answers.RETURNS_DEFAULTS.answer(call);
        };
        var gl=mock(GlReportService.class,reader);var assets=mock(FixedAssetService.class,reader);
        var settings=mock(SystemSettingsService.class);when(settings.readInt(SystemSettingKey.EXPORT_MAX_ROWS)).thenReturn(2000);
        var service=new FinanceReportService(mock(EntityManager.class),FinanceReportTestAccess.company(),settings,
                mock(FinanceStatementService.class),mock(FinanceCostService.class),gl,assets,mock(PartyMonthlySummaryService.class));
        var parameters=Map.of("dateFrom","2026-10-01","dateTo","2026-10-31","year","2026","month","10","f.search."+key,expression);
        var expected=new FinanceReportColumnOptions(Map.of("search."+key,expression),sort,order);
        service.export(report,parameters,sort,order);
        assertThat(calls).singleElement().satisfies(call->assertThat(call.options()).isEqualTo(expected));
        assertThat(calls.getFirst().method()).isNotEqualTo("exportInCurrentSnapshot");calls.clear();
        try(var sink=ExportPageSink.open(page->{})){service.export(report,parameters,sort,order);}
        assertThat(calls).singleElement().satisfies(call->assertThat(call.options()).isEqualTo(expected));
        if(report.startsWith("gl/")&&!report.equals("gl/trial-balance"))assertThat(calls.getFirst().method()).isEqualTo("exportInCurrentSnapshot");
    }
}
