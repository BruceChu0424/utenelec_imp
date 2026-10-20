package com.uten.imp.features.admin.serveroperations;

import com.fasterxml.jackson.databind.ObjectMapper;
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
    @SuppressWarnings("removal")
    @Test void bucketRootPrefixIsAcceptedByHttpAndCredentialsBindOnlyIntoTheWriteCommand() throws Exception {
        var service=mock(ServerOperationsService.class);
        when(service.saveSource(any())).thenReturn(new ServerOperationsDto.SourceView("rev2","oss-cn-hangzhou.aliyuncs.com",
                "bucket","",true,"key…id",null,null,null,true));
        // standalone MockMvc 不吃 Spring 容器里的兼容 ObjectMapper；databind 2.21 起
        // 缺失的构造参 null→boolean 默认翻严，这里显式挂与生产同调校的转换器。
        var mvc=MockMvcBuilders.standaloneSetup(new ServerOperationsController(service))
                .setMessageConverters(new org.springframework.http.converter.json.MappingJackson2HttpMessageConverter(
                        com.uten.imp.config.Jackson2ObjectMapperAutoConfiguration.domainObjectMapper()))
                .build();
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
        assertThat(request.getValue().accessKeySecret()).isEqualTo("test-secret");
        assertThat(new ObjectMapper().writeValueAsString(request.getValue())).doesNotContain("test-secret","test-id");
    }
    @Test void nullPrefixIsRejectedBeforeItCanBecomeAnImplicitDifferentStorageLocation() throws Exception {
        var service=mock(ServerOperationsService.class);var mvc=MockMvcBuilders.standaloneSetup(new ServerOperationsController(service)).build();
        mvc.perform(put("/api/admin/server-operations/source").contentType(MediaType.APPLICATION_JSON)
                .content(new ObjectMapper().writeValueAsString(Map.of("requestId",UUID.randomUUID().toString(),
                        "expectedRevision","rev1","endpoint","oss-cn-hangzhou.aliyuncs.com","bucket","bucket"))))
                .andExpect(status().isBadRequest());
        verifyNoInteractions(service);
    }
}
