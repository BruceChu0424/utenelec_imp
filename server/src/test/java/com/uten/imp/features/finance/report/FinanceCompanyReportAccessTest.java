package com.uten.imp.features.finance.report;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.GlobalExceptionHandler;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.cost.FinanceCostController;
import com.uten.imp.features.finance.cost.FinanceCostService;
import com.uten.imp.features.finance.statement.FinanceStatementController;
import com.uten.imp.features.finance.statement.FinanceStatementService;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import jakarta.persistence.EntityManager;
import java.time.LocalDate;
import java.util.Map;
import java.util.Set;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

/** Company-level interactive routes cannot bypass the same authority required by their export. */
class FinanceCompanyReportAccessTest {
    private static final LocalDate DATE=LocalDate.of(2026,10,1);
    private static final FinanceReportColumnOptions MALFORMED=new FinanceReportColumnOptions(Map.of("search.price","NaN","search.__private","probe"),"price","desc");
    @ParameterizedTest @ValueSource(strings={"subcontract","supplier","client","other-receivable","product","sales-summary","copper-fee","copper-pickling","plastic","issue","return","finished"})
    void legacyAndTypedServiceEntriesDenyBeforeSyntaxOrAnySql(String kind){
        EntityManager em=mock(EntityManager.class);var access=restricted();
        var statements=new FinanceStatementService(em,access);var costs=new FinanceCostService(em,access);
        for(FinanceReportColumnOptions options:new FinanceReportColumnOptions[]{null,MALFORMED}){
            assertThatThrownBy(()->invoke(kind,statements,costs,options)).isInstanceOfSatisfying(ApiException.class,failure->{
                assertThat(failure.getCode()).isEqualTo(ErrorCode.FORBIDDEN);assertThat(failure.getMessage()).contains("finance:view:all");
            });
        }
        verify(access,times(2)).scope();verifyNoInteractions(em);
    }
    @ParameterizedTest @ValueSource(strings={"subcontract","supplier","client","other-receivable","product","sales-summary","copper-fee","copper-pickling","plastic","issue","return","finished"})
    void actualGetRoutesRejectRestrictedReadersBeforeHeaderProbes(String kind)throws Exception{
        EntityManager em=mock(EntityManager.class);var access=restricted();
        var mvc=MockMvcBuilders.standaloneSetup(new FinanceStatementController(new FinanceStatementService(em,access)),
                new FinanceCostController(new FinanceCostService(em,access))).setControllerAdvice(new GlobalExceptionHandler()).build();
        String endpoint=switch(kind){case "subcontract","supplier","client","other-receivable"->"/statements/"+kind;
            case "issue","return","finished"->"/cost/plastic-detail";default->"/cost/"+kind;};
        mvc.perform(get("/api/finance/reports"+endpoint).param("kind",kind).param("dateFrom",DATE.toString()).param("dateTo",DATE.toString())
                .param("f.search.price","NaN").param("f.search.__private","probe").param("sort","price"))
                .andExpect(status().isForbidden()).andExpect(jsonPath("$.code").value("FORBIDDEN"));
        verifyNoInteractions(em);verify(access).scope();
    }
    @Test void grantedCompanyScopeReachesTypedValidationWithoutInventingAnUnrestrictedFallback(){
        EntityManager em=mock(EntityManager.class);var access=mock(FinanceDocumentAccessPolicy.class);when(access.scope()).thenReturn(new OwnerScope(true,Set.of()));
        var service=new FinanceCostService(em,access);
        assertThatThrownBy(()->service.productCost(null,DATE,DATE,1,20,new FinanceReportColumnOptions(Map.of("search.actualCost","NaN"),null,null)))
                .isInstanceOfSatisfying(ApiException.class,failure->assertThat(failure.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
        verifyNoInteractions(em);verify(access).scope();
    }
    private static FinanceDocumentAccessPolicy restricted(){var access=mock(FinanceDocumentAccessPolicy.class);when(access.scope()).thenReturn(new OwnerScope(false,Set.of(java.util.UUID.randomUUID())));return access;}
    private static ReportTableResponse invoke(String kind,FinanceStatementService statements,FinanceCostService costs,FinanceReportColumnOptions options){
        if(options==null)return switch(kind){case "subcontract"->statements.subcontractStatement(null,DATE,DATE,null,1,20);
            case "supplier"->statements.supplierStatement(null,DATE,DATE,1,20);case "client"->statements.clientStatement(null,DATE,DATE,1,20);
            case "other-receivable"->statements.otherReceivableStatement(null,DATE,DATE,1,20);case "product"->costs.productCost(null,DATE,DATE,1,20);
            case "sales-summary"->costs.salesCostSummary(null,DATE,DATE,1,20);case "copper-fee"->costs.copperFee(null,DATE,DATE,1,20);
            case "copper-pickling"->costs.copperPickling(null,DATE,DATE,1,20);case "plastic"->costs.plasticUsage(null,DATE,DATE,1,20);default->costs.plasticDetail(kind,null,DATE,DATE,1,20);};
        return switch(kind){case "subcontract"->statements.subcontractStatement(null,DATE,DATE,null,1,20,options);
            case "supplier"->statements.supplierStatement(null,DATE,DATE,1,20,options);case "client"->statements.clientStatement(null,DATE,DATE,1,20,options);
            case "other-receivable"->statements.otherReceivableStatement(null,DATE,DATE,1,20,options);case "product"->costs.productCost(null,DATE,DATE,1,20,options);
            case "sales-summary"->costs.salesCostSummary(null,DATE,DATE,1,20,options);case "copper-fee"->costs.copperFee(null,DATE,DATE,1,20,options);
            case "copper-pickling"->costs.copperPickling(null,DATE,DATE,1,20,options);case "plastic"->costs.plasticUsage(null,DATE,DATE,1,20,options);default->costs.plasticDetail(kind,null,DATE,DATE,1,20,options);};
    }
}
