package com.uten.imp.features.sales.report;

import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.order.SalesPriceMasker;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class SalesReportPriceReadPlanTest {
    @Test void hiddenPriceHeaderRejectsBeforeParsingAndBeforeReadingDataOrMetadata(){
        var fixture=fixture();
        for(String key:List.of("price","discount","amount","billedLocalAmount","billedLocalTotal","totalAmount","machiningPrice")) {
            org.assertj.core.api.Assertions.assertThatThrownBy(()->fixture.service().orderDetail(null,null,(Short)null,null,null,null,
                    Map.of("search."+key,"invalid-numeric-probe"),1,50,null,null))
                    .isInstanceOf(com.uten.imp.common.web.ApiException.class)
                    .satisfies(error->assertThat(((com.uten.imp.common.web.ApiException)error).getCode()).isEqualTo(com.uten.imp.common.web.ErrorCode.FORBIDDEN));
        }
        assertThat(fixture.sql()).isEmpty();
        var result=fixture.service().orderDetail(null,null,(Short)null,null,null,null,Map.of(),1,50,null,null);
        assertThat(result.columnSearchKeys()).contains("billDate","goodsName","pendingQty").doesNotContain("price","discount","amount","totalAmount");
    }
    private record Fixture(SalesReportService service, List<String> sql) { }

    private Fixture fixture() {
        var em = mock(EntityManager.class);var query = mock(Query.class);var sql = new ArrayList<String>();
        when(em.createNativeQuery(anyString())).thenAnswer(call -> { sql.add(call.getArgument(0));return query; });
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());when(query.getSingleResult()).thenReturn(0L);
        var access = mock(SalesDocumentAccessPolicy.class);
        when(access.nativeReadScope(anyString(), anyString())).thenReturn(new SalesDocumentAccessPolicy.NativeReadScope("1=1", null, Set.of()));
        var prices = mock(SalesPriceMasker.class);when(prices.canView()).thenReturn(false);
        return new Fixture(new SalesReportService(em, mock(SystemSettingsService.class), prices, access), sql);
    }

    @Test void hiddenOrderPricesCannotDriveTheSortOrAnyMetadataPredicate() {
        var fixture = fixture();
        fixture.service().orderDetail(null,null,(Short)null,null,null,null,Map.of(),1,50,"price","desc");
        assertThat(fixture.sql().getFirst()).contains("ORDER BY i.bill_date DESC, i.bill_no, i.line_no NULLS LAST, i.id")
                .doesNotContain("ORDER BY \"price\"");
        assertThat(fixture.sql()).noneMatch(sql -> sql.contains("SUM(t.\"amount\")")||sql.contains("SUM(t.\"billedLocalAmount\")"));
        fixture.sql().clear();
        fixture.service().orderSummary(null,null,null,null,null,null,Map.of(),1,50,"totalAmount","desc");
        assertThat(fixture.sql().getFirst()).contains("ORDER BY \"clientName\", t.\"__clientId\", t.\"__currencyId\"")
                .doesNotContain("ORDER BY \"totalAmount\"");
        assertThat(fixture.sql()).noneMatch(sql -> sql.contains("SUM(t.\"totalAmount\")"));
    }

    @Test void otherSalesDocumentFamiliesKeepTheirOwnExistingPriceAuthority() {
        var fixture = fixture();
        fixture.service().shipmentDetail(null,null,null,null,null,null,Map.of(),1,50,"price","desc");
        assertThat(fixture.sql().getFirst()).contains("ORDER BY \"price\" DESC");
    }
}
