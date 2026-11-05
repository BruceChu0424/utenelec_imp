package com.uten.imp.features.finance.gl;

import com.uten.imp.common.export.*;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.report.FinanceReportColumnOptions;
import com.uten.imp.security.AuthUser;
import jakarta.persistence.*;
import org.junit.jupiter.api.*;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import java.math.BigDecimal;
import java.util.*;
import java.util.concurrent.CancellationException;
import java.util.stream.IntStream;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Owns fixed original-template output and ExportPageSink boundaries. Dynamic
 * stock-COGS classification belongs to its own reader, never this 90-row table. */
class GlOperatingPlStreamingTest {
    private static final BigDecimal COST=new BigDecimal("0.123456789012345678901234");
    private final List<String> sql=new ArrayList<>();
    @AfterEach void clear(){TransactionSynchronizationManager.clear();SecurityContextHolder.clearContext();Thread.interrupted();}

    private GlReportService service(boolean configured){
        EntityManager em=mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call->{
            String statement=call.getArgument(0);sql.add(statement);Query query=mock(Query.class);
            when(query.setParameter(anyString(),any())).thenReturn(query);
            when(query.getSingleResult()).thenReturn(false);
            when(query.getResultList()).thenAnswer(read->{
                if(statement.contains("SELECT line_key,false FROM candidates"))return Collections.singletonList(new Object[]{"PL_1",false});
                if(statement.contains("SUM(e.direction*e.amount*CASE"))return IntStream.rangeClosed(1,10).mapToObj(month->new Object[]{"PL_1",month,new BigDecimal("1000")}).toList();
                if(statement.contains("finance_expense_analysis_periods"))return IntStream.rangeClosed(1,10).boxed().toList();
                if(statement.contains("FROM finance_operating_report_notes"))return Collections.singletonList(new Object[]{"OP_MATERIAL_4","原备注","原差异依据",7L});
                return List.of();
            });return query;
        });
        GlReportLineSource lines=mock(GlReportLineSource.class);Map<String,List<String>> names=new LinkedHashMap<>();
        if(configured)GlReportLine.operatingLines().forEach(line->names.put(line.key(),List.of("匿名已明确的原表取数")));
        when(lines.bindings(anyCollection())).thenReturn(new GlReportLineSource.Bindings(names));
        BigDecimal[] months=new BigDecimal[13];Arrays.fill(months,1,13,COST);
        when(lines.styleMonthly(anyCollection(),anyString(),any(),any())).thenReturn(Map.of("OP_MATERIAL_4",months));
        when(lines.payrollMonthly(anyCollection(),anyInt(),any())).thenReturn(Map.of());
        when(lines.depreciationMonthly(anyCollection(),anyString(),anyString(),anyString())).thenReturn(Map.of());
        return new GlReportService(em,lines,com.uten.imp.support.FinanceReportTestAccess.company());
    }
    private void context(){
        TransactionSynchronizationManager.setActualTransactionActive(true);TransactionSynchronizationManager.setCurrentTransactionReadOnly(true);
        TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(java.sql.Connection.TRANSACTION_REPEATABLE_READ);
        var user=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"gl-export",Set.of("finance_report:view","finance_report:export","finance:view:all"),false,true,false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,null,user.getAuthorities()));
    }
    private static Map<String,Object> row(List<Map<String,Object>> rows,String key){return rows.stream().filter(value->key.equals(value.get("__lineKey"))).findFirst().orElseThrow();}

    @Test void originalNinetyRowsAndThirtyColumnsKeepExactMoneyNotesAndTheSameOrderAcrossPagesAndStreaming(){
        var service=service(true);var first=service.operatingPlPage(2026,10,1,50);var second=service.operatingPlPage(2026,10,2,50);
        var all=new ArrayList<>(first.rows());all.addAll(second.rows());assertThat(first.total()).isEqualTo(90);assertThat(first.rows()).hasSize(50);assertThat(second.rows()).hasSize(40);
        assertThat(all.stream().map(value->value.get("__sourceRow"))).containsExactlyElementsOf(IntStream.rangeClosed(3,92).boxed().toList());
        assertThat(first.columns()).hasSize(30);assertThat(first.columns().stream().map(column->column.label()).toList()).startsWith("项目分类","分项","具体项目").endsWith("1-10月平均值占销售比","备注","差异原因");
        assertThat(row(all,"OP_MATERIAL_4")).containsEntry("category","材料费").containsEntry("sub","主材").containsEntry("item","玻璃").containsEntry("remark","原备注").containsEntry("varianceReason","原差异依据");
        assertThat((BigDecimal)row(all,"OP_MATERIAL_4").get("m10")).isEqualByComparingTo(COST);
        assertThat((BigDecimal)row(all,"OP_COST_TOTAL").get("m10")).isEqualByComparingTo(COST);
        assertThat((BigDecimal)row(all,"OP_PROFIT").get("m10")).isEqualByComparingTo(new BigDecimal("1000").subtract(COST));
        assertThat(row(all,"OP_MATERIAL_4").get("m11")).isNull();assertThat(row(all,"OP_MATERIAL_4").get("r11")).isNull();
        assertThat(service.operatingPlPage(2026,10,3,50).rows()).isEmpty();
        context();var pages=new ArrayList<ExportPayload>();
        try(var sink=ExportPageSink.open(pages::add)){var result=service.exportInCurrentSnapshot("gl/operating-pl",null,2026,10,90);assertThat(result.rows()).isEmpty();assertThat(result.total()).isEqualTo(90);}
        assertThat(pages).hasSize(1);assertThat(pages.getFirst().columns()).hasSize(30);assertThat(pages.getFirst().rows()).containsExactlyElementsOf(all);
        assertThat(sql).noneMatch(statement->statement.contains("v_stock_actual_cogs_postings"));
    }

    @Test void aBudgetBelowTheOriginalNinetyRowsCannotPublishAPartialCalculatedReport(){
        var service=service(true);context();var pages=new ArrayList<ExportPayload>();
        try(var sink=ExportPageSink.open(pages::add)){assertThatThrownBy(()->service.exportInCurrentSnapshot("gl/operating-pl",null,2026,10,89)).isInstanceOf(ApiException.class).hasMessageContaining("89");}
        assertThat(pages).isEmpty();assertThat(ExportPageSink.current()).isNull();
    }

    @Test void unconfiguredOriginalDetailsAndDependentTotalsStayUnknownAcrossEveryMonthAndBothOutputs(){
        var service=service(false);var result=service.operatingPlPage(2026,10,1,100);
        for(String key:List.of("OP_MATERIAL_4","OP_LABOR_TOTAL","OP_ADMIN_TOTAL","OP_COST_TOTAL","OP_PROFIT")){
            var value=row(result.rows(),key);assertThat(value.get("__pending")).isEqualTo(true);
            for(int month=1;month<=10;month++){assertThat(value.get("m"+month)).as(key+" month "+month).isNull();assertThat(value.get("r"+month)).isNull();}
            assertThat(value.get("averageRatio")).isNull();
        }
        var laborDetail=row(result.rows(),"LABOR_DIRECT");
        assertThat(laborDetail.get("m10")).isNull();
        assertThat(laborDetail.get("__basis")).isEqualTo("待配置取数或确认无业务");
        context();var pages=new ArrayList<ExportPayload>();try(var sink=ExportPageSink.open(pages::add)){service.exportInCurrentSnapshot("gl/operating-pl",null,2026,10,90);}
        assertThat(pages.getFirst().rows()).containsExactlyElementsOf(result.rows());
    }

    @Test void itemAndMonthHeaderFiltersRetainOriginalFullTableSubtotalContextBeforePagingAndExport(){
        var service=service(true);var options=new FinanceReportColumnOptions(Map.of("search.item","玻璃","search.m10",COST.toPlainString()),null,null);
        var first=service.operatingPlPage(2026,10,1,1,options);var all=new ArrayList<Map<String,Object>>();
        assertThat(first.total()).isEqualTo(5);for(int page=1;page<=5;page++)all.addAll(service.operatingPlPage(2026,10,page,1,options).rows());
        assertThat(all.stream().map(value->value.get("__lineKey"))).containsExactly("OP_MATERIAL_4","OP_PRIMARY_TOTAL","OP_MATERIAL_TOTAL","OP_COST_TOTAL","OP_PROFIT");
        assertThat((BigDecimal)row(all,"OP_COST_TOTAL").get("m10")).isEqualByComparingTo(COST);
        assertThat(first.columnSearchKeys()).hasSize(30).contains("item","m10","r10","averageRatio","remark","varianceReason");
        assertThat(service.operatingPlPage(2026,10,6,1,options).rows()).isEmpty();
        assertThat(service.operatingPlPage(2026,10,1,10,new FinanceReportColumnOptions(Map.of("search.item","OP-unmatched","search.m10","!=0"),null,null)).total()).isZero();
        context();var pages=new ArrayList<ExportPayload>();try(var sink=ExportPageSink.open(pages::add)){assertThat(service.exportInCurrentSnapshot("gl/operating-pl",null,2026,10,90,options).total()).isEqualTo(5);}
        assertThat(pages.getFirst().rows()).containsExactlyElementsOf(all);
    }

    @Test void exportRequiresTheOwningSinkAndReadonlyRepeatableReadContext(){
        var service=service(true);assertThatThrownBy(()->service.exportInCurrentSnapshot("gl/operating-pl",null,2026,10,90)).isInstanceOf(IllegalStateException.class);
        try(var sink=ExportPageSink.open(page->{})){
            assertThatThrownBy(()->service.exportInCurrentSnapshot("gl/operating-pl",null,2026,10,90)).isInstanceOf(IllegalStateException.class);
            context();TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(java.sql.Connection.TRANSACTION_READ_COMMITTED);
            assertThatThrownBy(()->service.exportInCurrentSnapshot("gl/operating-pl",null,2026,10,90)).isInstanceOf(IllegalStateException.class);
            TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(java.sql.Connection.TRANSACTION_REPEATABLE_READ);TransactionSynchronizationManager.setCurrentTransactionReadOnly(false);
            assertThatThrownBy(()->service.exportInCurrentSnapshot("gl/operating-pl",null,2026,10,90)).isInstanceOf(IllegalStateException.class);
        }
        assertThat(sql).isEmpty();
    }

    @Test void subcategoryFilterKeepsTheOriginalProfitTailAcrossPagingAndExport(){
        var service=service(true);
        var options=new FinanceReportColumnOptions(Map.of("search.sub","利润额"),null,null);
        var first=service.operatingPlPage(2026,10,1,1,options);
        assertThat(first.total()).isEqualTo(1);
        assertThat(first.rows().getFirst()).containsEntry("sub","利润额").containsEntry("__lineKey","OP_PROFIT");
        assertThat(service.operatingPlPage(2026,10,2,1,options).rows()).isEmpty();
        context();var pages=new ArrayList<ExportPayload>();
        try(var sink=ExportPageSink.open(pages::add)){
            assertThat(service.exportInCurrentSnapshot("gl/operating-pl",null,2026,10,90,options).total()).isEqualTo(1);
        }
        assertThat(pages.stream().flatMap(page->page.rows().stream())).containsExactly(first.rows().getFirst());
    }

    @Test void interruptedCalculatedExportCannotPublishItsOriginalTableBuffer(){
        var service=service(true);context();var pages=new ArrayList<ExportPayload>();
        try(var sink=ExportPageSink.open(pages::add)){Thread.currentThread().interrupt();assertThatThrownBy(()->service.exportInCurrentSnapshot("gl/operating-pl",null,2026,10,90)).isInstanceOf(CancellationException.class);}
        assertThat(pages).isEmpty();
    }
}
