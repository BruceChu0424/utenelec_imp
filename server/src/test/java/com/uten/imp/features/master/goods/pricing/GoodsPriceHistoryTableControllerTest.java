package com.uten.imp.features.master.goods.pricing;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditDetailViewRecorder;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.*;
import static com.uten.imp.features.master.goods.pricing.GoodsPriceContracts.*;
import static com.uten.imp.features.master.goods.pricing.GoodsPriceHistoryTableContracts.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

class GoodsPriceHistoryTableControllerTest {
    @Test void actualGetBindingPreservesIsoDatesRawNumericFilterAndPage() throws Exception {
        UUID goods=UUID.randomUUID();var service=mock(GoodsPriceHistoryTableService.class);var audit=mock(AuditDetailViewRecorder.class);
        when(service.table(any())).thenReturn(new TablePage(List.of(),2,50,51,2,Map.of(),Map.of(),Map.of(),Map.of(),200,OffsetDateTime.now()));
        var mvc=MockMvcBuilders.standaloneSetup(new GoodsPriceHistoryTableController(service,new ObjectMapper(),audit)).build();
        mvc.perform(get("/api/master/goods/{goodsId}/price-analysis/history/table",goods).param("kind","PURCHASE")
                .param("from","2026-01-02").param("to","2026-10-13").param("page","2").param("size","50")
                .param("sort","unitPrice").param("ascending","true").param("filters","{\"unitPrice\":\"0.00000000000000000001\",\"colorName\":\"__null__\"}"))
                .andExpect(status().isOk());
        var query=ArgumentCaptor.forClass(TableQuery.class);verify(service).table(query.capture());
        assertThat(query.getValue().from()).isEqualTo(LocalDate.of(2026,1,2));assertThat(query.getValue().to()).isEqualTo(LocalDate.of(2026,10,13));
        assertThat(query.getValue().context().goodsId()).isEqualTo(goods);assertThat(query.getValue().context().kind()).isEqualTo(Kind.PURCHASE);
        assertThat(query.getValue().filters()).containsEntry("unitPrice","0.00000000000000000001");assertThat(query.getValue().page()).isEqualTo(2);
        verify(audit).record("view_goods_price_analysis_history","goods",goods,null,null,"货品价格历史");
    }
    @Test void facetEndpointBindsItsOwnPaginationAndSearchWithoutChangingTheTableContext() throws Exception {
        UUID goods=UUID.randomUUID();var service=mock(GoodsPriceHistoryTableService.class);
        when(service.facets(any())).thenReturn(new FacetPage("sourceNo",List.of(),1,50,0,0,0,false,OffsetDateTime.now()));
        var mvc=MockMvcBuilders.standaloneSetup(new GoodsPriceHistoryTableController(service,new ObjectMapper(),mock(AuditDetailViewRecorder.class))).build();
        mvc.perform(get("/api/master/goods/{goodsId}/price-analysis/history/table/facets",goods).param("kind","SALES").param("column","sourceNo")
                .param("search","S%_literal").param("from","2026-01-01").param("page","3").param("size","50"))
                .andExpect(status().isOk());
        var query=ArgumentCaptor.forClass(FacetQuery.class);verify(service).facets(query.capture());
        assertThat(query.getValue().search()).isEqualTo("S%_literal");assertThat(query.getValue().page()).isEqualTo(3);
        assertThat(query.getValue().table().page()).isNull();assertThat(query.getValue().table().from()).isEqualTo(LocalDate.of(2026,1,1));
    }
}
