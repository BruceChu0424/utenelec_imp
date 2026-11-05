package com.uten.imp.common.web;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.*;
import com.uten.imp.features.reporting.export.*;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.core.MethodParameter;
import org.springframework.http.MediaType;
import org.springframework.http.converter.json.JacksonJsonHttpMessageConverter;
import org.springframework.mock.http.MockHttpInputMessage;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.web.bind.annotation.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.stream.IntStream;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

class OutputSelectionRequestBodyLimitMvcTest {
    private static String ids() {
        return IntStream.rangeClosed(1,50000).mapToObj(i->"\""+new UUID(1,i)+"\"")
                .collect(java.util.stream.Collectors.joining(",","[","]"));
    }
    @Test void realJobEndpointAcceptsFiftyThousandIdentitiesAboveOneMiBWhileOrdinaryEndpointsRemainBounded() throws Exception {
        String selected=ids();UUID id=UUID.randomUUID();
        String body=new ObjectMapper().writeValueAsString(new ReportExportRequest(id,"master","mould",
                Map.of("filter","{}","selectedIds",selected),null,null,null));
        assertThat(body.getBytes(StandardCharsets.UTF_8).length).isGreaterThan(1024*1024).isLessThan(2_200_000);
        var service=mock(ReportExportService.class);
        when(service.submit(any())).thenReturn(new ReportExportService.View(id,"master","mould","xlsx","PENDING",false,0,0,null,null,null,null));
        var controller=new ReportExportController(service,mock(WorkbookDownloadService.class),mock(AuditService.class),mock(SecurityContextCurrentUser.class));
        var mvc=MockMvcBuilders.standaloneSetup(controller,new Ordinary())
                .setControllerAdvice(new JsonRequestBodyLimitAdvice(1024*1024),new GlobalExceptionHandler()).build();
        mvc.perform(post("/api/report-export-jobs").contentType(MediaType.APPLICATION_JSON).content(body))
                .andExpect(status().isOk()).andExpect(jsonPath("$.status").value("PENDING"));
        var captured=ArgumentCaptor.forClass(ReportExportRequest.class);verify(service).submit(captured.capture());
        assertThat(SelectedExportIds.parse(captured.getValue().parameters().get("selectedIds"))).hasSize(50000);
        mvc.perform(post("/ordinary-selection-budget").contentType(MediaType.APPLICATION_JSON).content(body))
                .andExpect(status().isContentTooLarge()).andExpect(jsonPath("$.code").value("PAYLOAD_TOO_LARGE"));
        verifyNoMoreInteractions(service);
    }
    @Test void everyOriginalMasterExportReadsTheSameLargePrivateBodyWithoutWideningItsOtherEndpoints()throws Exception {
        byte[] body=("{\"selectedIds\":"+ids()+"}").getBytes(StandardCharsets.UTF_8);
        var advice=new JsonRequestBodyLimitAdvice(1024*1024);
        List<Class<?>> types=List.of(com.uten.imp.features.master.goods.GoodsController.class,
                com.uten.imp.features.master.client.ClientController.class,com.uten.imp.features.master.supplier.SupplierController.class,
                com.uten.imp.features.master.account.AccountController.class,com.uten.imp.features.master.currency.CurrencyController.class,
                com.uten.imp.features.master.color.ColorController.class,com.uten.imp.features.master.unit.UnitController.class,
                com.uten.imp.features.master.mould.MouldController.class,com.uten.imp.features.master.warehouse.WarehouseController.class,
                com.uten.imp.features.master.referencemethod.ReferenceMethodController.class);
        for(Class<?> type:types){
            var method=Arrays.stream(type.getDeclaredMethods()).filter(m->m.getName().equals("export")||m.getName().equals("exportSettlementAdmin")).findFirst().orElseThrow();
            int index=IntStream.range(0,method.getParameterCount()).filter(i->MasterExportSelectionRequest.class.isAssignableFrom(method.getParameterTypes()[i])).findFirst().orElseThrow();
            var parameter=new MethodParameter(method,index);var input=new MockHttpInputMessage(body);input.getHeaders().setContentType(MediaType.APPLICATION_JSON);
            assertThat(advice.beforeBodyRead(input,parameter,method.getParameterTypes()[index],JacksonJsonHttpMessageConverter.class)
                    .getBody().readAllBytes()).isEqualTo(body);
        }
        var ordinary=new MockHttpInputMessage(body);ordinary.getHeaders().setContentType(MediaType.APPLICATION_JSON);
        assertThatThrownBy(()->advice.beforeBodyRead(ordinary,null,Object.class,JacksonJsonHttpMessageConverter.class))
                .isInstanceOf(JsonBodyTooLargeException.class);
    }
    @RestController static class Ordinary {
        @PostMapping("/ordinary-selection-budget") public Map<String,Object> body(@RequestBody Map<String,Object> body){return body;}
    }
}
