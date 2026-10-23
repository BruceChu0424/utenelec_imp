package com.uten.imp.features.clientupdates;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.GlobalExceptionHandler;
import java.io.ByteArrayInputStream;
import java.io.InputStream;
import java.time.Instant;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

class ClientUpdateControllerTest {
    private final ClientReleaseService service = mock(ClientReleaseService.class);
    private final UUID id = UUID.randomUUID();
    private MockMvc mvc;

    @BeforeEach void setUp() {
        mvc = MockMvcBuilders.standaloneSetup(new ClientUpdateController(service), new ClientReleaseAdminController(service))
                .setControllerAdvice(new GlobalExceptionHandler()).build();
    }

    @Test void checkReturnsRawContractAndDisablesCaching() throws Exception {
        when(service.check("android", "arm64", 27)).thenReturn(new ClientReleaseDto.Check(true, release("PUBLISHED"), 300));
        mvc.perform(get("/api/client-updates/check").param("platform", "android").param("architecture", "arm64").param("currentBuildNumber", "27"))
                .andExpect(status().isOk()).andExpect(header().string("Cache-Control", "private, no-store"))
                .andExpect(jsonPath("$.updateAvailable").value(true)).andExpect(jsonPath("$.release.buildNumber").value(28))
                .andExpect(jsonPath("$.release.downloadUrl").value("/api/client-updates/" + id + "/download"));
    }

    @Test void uploadIsRawStreamingAndCreateListPublishWithdrawUseReleaseObjects() throws Exception {
        var draft = release("DRAFT");
        when(service.list()).thenReturn(List.of(draft));
        mvc.perform(get("/api/admin/client-releases")).andExpect(status().isOk()).andExpect(jsonPath("$[0].id").value(id.toString()));
        var request = new ClientReleaseDto.Create(id, "android", "arm64", "2.5.28", 28, "", false, "uten.apk", "a".repeat(64), null);
        when(service.create(any())).thenReturn(draft);
        mvc.perform(post("/api/admin/client-releases").contentType(MediaType.APPLICATION_JSON).content(new ObjectMapper().writeValueAsBytes(request)))
                .andExpect(status().isCreated()).andExpect(jsonPath("$.id").value(id.toString()));
        byte[] bytes = {1, 2, 3, 4};
        when(service.upload(eq(id), any(InputStream.class), anyLong())).thenAnswer(invocation -> {
            assertThat(((InputStream) invocation.getArgument(1)).readAllBytes()).isEqualTo(bytes);
            assertThat((long) invocation.getArgument(2)).isEqualTo(4);
            return draft;
        });
        mvc.perform(put("/api/admin/client-releases/{id}/package", id).contentType(MediaType.APPLICATION_OCTET_STREAM).content(bytes))
                .andExpect(status().isOk()).andExpect(jsonPath("$.state").value("DRAFT"));
        when(service.publish(id)).thenReturn(release("PUBLISHED"));
        mvc.perform(post("/api/admin/client-releases/{id}/publish", id)).andExpect(status().isOk()).andExpect(jsonPath("$.state").value("PUBLISHED"));
        when(service.withdraw(id)).thenReturn(release("WITHDRAWN"));
        mvc.perform(post("/api/admin/client-releases/{id}/withdraw", id)).andExpect(status().isOk()).andExpect(jsonPath("$.state").value("WITHDRAWN"));
    }

    @Test void downloadCarriesExactLengthHashAndPrivateHeadersAndWithdrawalIs404() throws Exception {
        byte[] bytes = {1, 2, 3, 4};
        when(service.download(id)).thenReturn(new ClientReleaseService.Download(release("PUBLISHED"), new ByteArrayInputStream(bytes)));
        mvc.perform(get("/api/client-updates/{id}/download", id)).andExpect(status().isOk())
                .andExpect(header().string("Content-Length", "4"))
                .andExpect(header().string("X-Checksum-Sha256", "a".repeat(64)))
                .andExpect(header().string("Cache-Control", "private, no-store"))
                .andExpect(header().string("X-Content-Type-Options", "nosniff"))
                .andExpect(content().bytes(bytes));
        when(service.download(id)).thenThrow(new ApiException(ErrorCode.NOT_FOUND));
        mvc.perform(get("/api/client-updates/{id}/download", id)).andExpect(status().isNotFound());
    }

    private ClientReleaseDto.Release release(String state) {
        return new ClientReleaseDto.Release(id, "android", "arm64", "2.5.28", 28, "", false, "uten.apk",
                "a".repeat(64), "a".repeat(64), 4, "android_package", null, "/api/client-updates/" + id + "/download",
                state, Instant.parse("2026-10-22T00:00:00Z"), "DRAFT".equals(state) ? null : Instant.parse("2026-10-22T00:00:00Z"));
    }
}
