package com.uten.imp.features.sales.order;

import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.util.UUID;

import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

class SalesOrderFinanceReadOnlyControllerTest {
    @Test
    void removedFinanceAmendmentCannotWriteAnOrder() throws Exception {
        var service = mock(SalesOrderFinanceConfirmService.class);
        var mvc = MockMvcBuilders.standaloneSetup(new SalesOrderFinanceConfirmController(service)).build();
        mvc.perform(post("/api/sales/orders/{id}/finance-confirmation/amend", UUID.randomUUID())
                .contentType(MediaType.APPLICATION_JSON)
                .content("""
                        {"expectedRevision":1,"expectedClaimId":"00000000-0000-0000-0000-000000000001",
                         "lines":[{"itemId":"00000000-0000-0000-0000-000000000002","price":"0","discount":"0.1"}]}
                        """))
                .andExpect(status().isNotFound());
        verifyNoInteractions(service);
    }
}
