package com.uten.imp.features.applications;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.PageResponse;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import java.util.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;
class BusinessApplicationControllerRoutingTest {
    @Test void fixedQueueRoutesDoNotCompeteWithTheUuidDetailHandler() throws Exception {
        var service=mock(BusinessApplicationService.class);var audit=mock(AuditDetailViewRecorder.class);
        when(service.list(anyString(),isNull(),isNull(),isNull(),isNull(),eq(1),eq(24))).thenReturn(new PageResponse<>(List.of(),1,24,0,0));
        var mvc=MockMvcBuilders.standaloneSetup(new BusinessApplicationController(service,audit)).build();
        for(String queue:List.of("mine","pending","history","prepayment-posting")){
            mvc.perform(get("/api/business-applications/"+queue)).andExpect(status().isOk());
            verify(service).list(queue,null,null,null,null,1,24);
        }
        verify(service,never()).detail(any());
    }
}
