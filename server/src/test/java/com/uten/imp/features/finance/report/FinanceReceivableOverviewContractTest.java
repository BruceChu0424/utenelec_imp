package com.uten.imp.features.finance.report;

import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.finance.asset.FixedAssetService;
import com.uten.imp.features.finance.cost.FinanceCostService;
import com.uten.imp.features.finance.gl.GlReportService;
import com.uten.imp.features.finance.statement.FinanceStatementService;
import com.uten.imp.common.web.ApiException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.time.LocalDate;
import java.util.*;
import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class FinanceReceivableOverviewContractTest {
    private static final LocalDate FROM=LocalDate.of(2026,11,1),TO=FROM.plusDays(9);
    private record Captured(String sql,Query query) { }
    private final List<Captured> queries=new ArrayList<>();
    private final FinanceReportService reports;
    FinanceReceivableOverviewContractTest() {
        var em=mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call->{
            var query=mock(Query.class);when(query.setParameter(anyString(),any())).thenReturn(query);
            when(query.getResultList()).thenReturn(List.of());when(query.getSingleResult()).thenReturn(0L);
            queries.add(new Captured(call.getArgument(0),query));return query;
        });
        var access=mock(FinanceDocumentAccessPolicy.class);when(access.hasAuthority(anyString())).thenReturn(true);
        when(access.scope()).thenReturn(new com.uten.imp.security.OwnerVisibility.OwnerScope(true,Set.of()));
        reports=new FinanceReportService(em,access,mock(SystemSettingsService.class),mock(FinanceStatementService.class),
                mock(FinanceCostService.class),mock(GlReportService.class),mock(FixedAssetService.class),mock(PartyMonthlySummaryService.class));
    }
    @Test void legacyHeadersCategoryMembershipGuardsAndMonetarySourceStaySharedWithExport() {
        UUID category=UUID.randomUUID();
        var result=reports.arApOverview(FROM,TO,"AR_ONLY","华南 客户","CLIENT",category,1,50,
                Map.of("search.balance",">=100"),"balance","desc","RECEIVABLE_SUMMARY");
        assertThat(result.columns()).extracting(ReportColumn::label).containsExactly("客户编号","客户简称","客户全称","业务员","总监","区域","所属地区",
                "铺底额","上月余额","发货金额","回款金额","退货金额","货款冲销","应收余额","超出铺底额","物料金额");
        assertThat(result.columnSearchKeys()).doesNotContain("settlement","exchangeDiff","__partyId");
        assertThat(queries).hasSizeGreaterThanOrEqualTo(4);
        for(var guard:queries.subList(0,2)) {
            assertThat(guard.sql()).contains("client_categories","party.category_id",":overviewCategoryId","party.is_deleted");
            verify(guard.query()).setParameter("overviewCategoryId",category);
            verify(guard.query(),atLeastOnce()).setParameter("kw","%华南%");
            verify(guard.query(),atLeastOnce()).setParameter("kw1","%客户%");
        }
        for(var projection:queries.subList(2,queries.size())) {
            assertThat(projection.sql()).contains("LEFT JOIN posting p","c.category_id",":overviewCategoryId",
                    "\"balance\" IS NULL OR \"balance\"<>0","report.\"balance\"", "client_categories");
            verify(projection.query()).setParameter("overviewCategoryId",category);
            verify(projection.query()).setParameter("kw","%华南%");
            verify(projection.query()).setParameter("kw1","%客户%");
        }
        var exported=reports.export("ar-ap/overview",Map.of("dateFrom",FROM.toString(),"dateTo",TO.toString(),
                "layout","RECEIVABLE_SUMMARY","categoryType","CLIENT","categoryId",category.toString(),
                "displayMode","AR_ONLY","f.search.balance",">=100"),"balance","desc");
        assertThat(exported.columns()).extracting(com.uten.imp.common.export.ExportColumn::label)
                .containsExactlyElementsOf(result.columns().stream().map(ReportColumn::label).toList());
    }
    @Test void invalidLayoutOrSupplierCannotSilentlyReturnTheOtherTable() {
        assertThatThrownBy(()->reports.arApOverview(FROM,TO,"ALL",null,"SUPPLIER",null,1,50,Map.of(),null,null,"RECEIVABLE_SUMMARY"))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(()->reports.arApOverview(FROM,TO,"ALL",null,null,null,1,50,Map.of(),null,null,"unknown"))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(()->reports.arApOverview(FROM,TO,"ALL",null,null,null,1,50,Map.of(),"settlement","asc","RECEIVABLE_SUMMARY"))
                .isInstanceOf(ApiException.class);
        assertThat(queries).isEmpty();
    }
    @Test void balanceLayoutPreservesTheOriginalSixColumns() {
        var result=reports.arApOverview(FROM,TO,"ALL",null,null,null,1,50,Map.of(),null,null,"BALANCE");
        assertThat(result.columns()).extracting(ReportColumn::key)
                .containsExactly("partyName","partyType","receivable","payable","phone","address");
    }
}
