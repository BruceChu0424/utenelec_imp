package com.uten.imp.common.export;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.features.reporting.export.*;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import java.nio.file.Path;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

class OutputSelectionCapabilitiesTest {
    @Test void realCapabilityResponseAdvertisesSelectionEvenWhenTaskStorageIsDisabled()throws Exception{
        var service=mock(ReportExportService.class);
        var controller=new ReportExportController(service,mock(WorkbookDownloadService.class),mock(AuditService.class),mock(SecurityContextCurrentUser.class));
        var http=MockMvcBuilders.standaloneSetup(controller).build();
        for(boolean available:new boolean[]{false,true}){
            when(service.available()).thenReturn(available);
            http.perform(get("/api/report-export-jobs/capabilities")).andExpect(status().isOk())
                    .andExpect(jsonPath("$.available").value(available)).andExpect(jsonPath("$.selectionVersion").value(1));
        }
    }
    @Test void serverVersionAndSharedJavaNativeHandshakeExamplesUseTheSameContract()throws Exception{
        var fixture=new ObjectMapper().readTree(Path.of("..","contracts","table-output-selection","v1.json").toFile());
        assertThat(fixture.get("selectionVersion").intValue()).isEqualTo(OutputSelectionProtocol.VERSION);
        for(var sample:fixture.get("handshakeCases")){
            var body=sample.get("body");
            if(!body.isNull()&&body.has("selectionVersion")&&body.get("selectionVersion").intValue()==OutputSelectionProtocol.VERSION){
                assertThat(OutputSelectionProtocol.capabilities(sample.get("available").booleanValue()))
                        .isEqualTo(new ObjectMapper().convertValue(body,Map.class));
                assertThat(sample.get("selectionAllowed").booleanValue()).isTrue();
            }
        }
    }
}
