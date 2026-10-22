package com.uten.imp.features.admin.serveroperations;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.GlobalExceptionHandler;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

/** Actual JSON binding + Bean Validation; method-security/step-up gates are separately proxied tests. */
class ServerOperationsSourceHttpContractTest {
    @Test void bucketRootPrefixIsAcceptedByHttpAndCredentialsBindOnlyIntoTheWriteCommand() throws Exception {
        var service=mock(ServerOperationsService.class);
        when(service.saveSource(any())).thenReturn(new ServerOperationsDto.SourceView("rev2","oss-cn-hangzhou.aliyuncs.com",
                "bucket","",true,"key…id",null,null,null,true));
        var mvc=mvc(service);
        var body=Map.of("requestId",UUID.randomUUID().toString(),"expectedRevision","rev1",
                "endpoint","oss-cn-hangzhou.aliyuncs.com","bucket","bucket","objectPrefix","",
                "accessKeyId","test-id","accessKeySecret","test-secret");
        mvc.perform(put("/api/admin/server-operations/source").contentType(MediaType.APPLICATION_JSON)
                .content(new ObjectMapper().writeValueAsString(body)))
                .andExpect(status().isOk()).andExpect(jsonPath("objectPrefix").value(""))
                .andExpect(jsonPath("applied").value(true)).andExpect(jsonPath("accessKeySecret").doesNotExist())
                .andExpect(jsonPath("accessKeyId").doesNotExist());
        var request=ArgumentCaptor.forClass(ServerOperationsDto.SourceSave.class);verify(service).saveSource(request.capture());
        assertThat(request.getValue().objectPrefix()).isEmpty();
        assertThat(request.getValue().clearCredentials()).isFalse();
        assertThat(request.getValue().accessKeySecret()).isEqualTo("test-secret");
        assertThat(new ObjectMapper().writeValueAsString(request.getValue())).doesNotContain("test-secret","test-id");
    }
    @Test void nullPrefixIsRejectedBeforeItCanBecomeAnImplicitDifferentStorageLocation() throws Exception {
        var service=mock(ServerOperationsService.class);var mvc=mvc(service);
        for (boolean explicitNull : new boolean[]{false,true}) {
            var body=new java.util.LinkedHashMap<String,Object>(Map.of("requestId",UUID.randomUUID().toString(),
                    "expectedRevision","rev1","endpoint","oss-cn-hangzhou.aliyuncs.com","bucket","bucket"));
            if (explicitNull) body.put("objectPrefix",null);
            // Omitted clearCredentials must use production's false default;
            // this rejection must come from the prefix constraint, not JSON parsing.
            mvc.perform(put("/api/admin/server-operations/source").contentType(MediaType.APPLICATION_JSON)
                    .content(new ObjectMapper().writeValueAsString(body)))
                    .andExpect(status().is(422))
                    .andExpect(jsonPath("$.status").value(422))
                    .andExpect(jsonPath("$.code").value("VALIDATION_FAILED"))
                    .andExpect(jsonPath("$.message").value("填写的内容有误，请检查后重试"))
                    .andExpect(jsonPath("$.fieldErrors.length()").value(1))
                    .andExpect(jsonPath("$.fieldErrors[0].field").value("objectPrefix"));
        }
        verifyNoInteractions(service);
    }

    @SuppressWarnings("removal")
    private static org.springframework.test.web.servlet.MockMvc mvc(ServerOperationsService service) {
        // Standalone fixtures need the same primitive defaults and error adapter
        // as production, including in negative Bean Validation scenarios.
        return MockMvcBuilders.standaloneSetup(new ServerOperationsController(service))
                .setControllerAdvice(new GlobalExceptionHandler())
                .setMessageConverters(new org.springframework.http.converter.json.MappingJackson2HttpMessageConverter(
                        com.uten.imp.config.Jackson2ObjectMapperAutoConfiguration.domainObjectMapper()))
                .build();
    }
}
