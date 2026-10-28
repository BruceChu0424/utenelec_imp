package com.uten.imp.features.finance.reconciliation;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.finance.reconciliation.dto.*;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/** Exact lineage identity is converted by Spring; typed text stays separate from that UUID. */
class FinanceReconciliationHeaderControllerTest {
    @Test void mappedEndpointKeepsTheUuidAndAllOtherColumnConditions() throws Exception {
        var service=mock(FinanceReconciliationService.class);var controller=new FinanceReconciliationController(service);
        when(service.list(any(),anyInt(),anyInt(),any(),any())).thenReturn(new PageResponse<FinanceReconciliationListItem>(List.of(),1,20,0L,0));
        var mvc=MockMvcBuilders.standaloneSetup(controller).addFilters((request,response,chain)->{
            ReflectionTestUtils.setField(controller,"request",request);chain.doFilter(request,response);
        }).build();
        UUID account=UUID.randomUUID(),original=UUID.randomUUID();
        mvc.perform(get("/api/finance/reconciliations").param("accountId",account.toString())
                .param("search.billDate","2026-10").param("search.inAmount",">=12.0001")
                .param("search.reversalOfId",original.toString())).andExpect(status().isOk());
        var captured=ArgumentCaptor.forClass(FinanceReconciliationQueryFilter.class);
        verify(service).list(captured.capture(),eq(1),eq(20),isNull(),isNull());
        assertThat(captured.getValue().accountId()).isEqualTo(account);
        assertThat(captured.getValue().reversalOfId()).isEqualTo(original);
        assertThat(captured.getValue().columnSearch()).containsExactlyInAnyOrderEntriesOf(
                java.util.Map.of("billDate","2026-10","inAmount",">=12.0001"));
    }
    @Test void malformedLineageIdentityNeverReachesTheReadService() throws Exception {
        var service=mock(FinanceReconciliationService.class);var controller=new FinanceReconciliationController(service);
        var mvc=MockMvcBuilders.standaloneSetup(controller).build();
        mvc.perform(get("/api/finance/reconciliations").param("search.reversalOfId","not-a-uuid"))
                .andExpect(status().isBadRequest());verifyNoInteractions(service);
    }
}
