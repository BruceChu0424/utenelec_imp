package com.uten.imp.features.admin.serveroperations;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import com.uten.imp.security.PublicMaintenanceRequest;
import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

class PublicMaintenanceControllerTest {
    @TempDir Path directory;
    private final ObjectMapper mapper = new ObjectMapper();
    private final Clock clock = Clock.fixed(Instant.parse("2026-10-26T12:00:00Z"), ZoneOffset.UTC);

    @Test void projectsOnlySafeFieldsAndUsesCurrentServerTime() throws Exception {
        Path status = directory.resolve("maintenance.json");
        Files.writeString(status, """
                {"schemaVersion":1,"state":"scheduled","noticeId":"00000000-0000-0000-0000-000000000001",
                 "serverTime":"2026-10-26T11:00:00Z","startsAt":"2026-10-26T12:10:00Z","targetVersion":"v2.5.32",
                 "actorId":"private","backupPath":"/private/backup","accessKeySecret":"private"}
                """);
        var mvc = MockMvcBuilders.standaloneSetup(new PublicMaintenanceController(mapper, status, clock)).build();
        mvc.perform(get("/api/system/maintenance").header("Authorization", "Bearer expired"))
                .andExpect(status().isOk()).andExpect(header().string("Cache-Control", "no-store"))
                .andExpect(jsonPath("$.state").value("scheduled"))
                .andExpect(jsonPath("$.serverTime").value("2026-10-26T12:00Z"))
                .andExpect(jsonPath("$.retryAfterSeconds").value(10))
                .andExpect(jsonPath("$.actorId").doesNotExist())
                .andExpect(jsonPath("$.backupPath").doesNotExist())
                .andExpect(jsonPath("$.accessKeySecret").doesNotExist());
    }

    @Test void unknownOrMalformedStateIsUnavailableWithoutFabricatingMaintenance() throws Exception {
        Path status = directory.resolve("maintenance.json");
        var controller = new PublicMaintenanceController(mapper, status, clock);
        assertThat(controller.current().getStatusCode().value()).isEqualTo(503);
        for (String document : new String[]{"[]", "{}", "{" + "\"schemaVersion\":1,\"state\":\"scheduled\"}",
                "{\"schemaVersion\":1,\"state\":\"scheduled\",\"noticeId\":\"00000000-0000-0000-0000-000000000001\",\"startsAt\":\"bad\"}",
                "x".repeat(4097)}) {
            Files.writeString(status, document);
            var response = controller.current();
            assertThat(response.getStatusCode().value()).isEqualTo(503);
            assertThat(response.getHeaders().getCacheControl()).isEqualTo("no-store");
            assertThat(response.getBody()).isNull();
        }
    }

    @Test void anonymousExemptionIsExactlyOneReadOnlyRoute() {
        assertThat(PublicMaintenanceRequest.matches(new MockHttpServletRequest("GET", "/api/system/maintenance"))).isTrue();
        assertThat(PublicMaintenanceRequest.matches(new MockHttpServletRequest("POST", "/api/system/maintenance"))).isFalse();
        assertThat(PublicMaintenanceRequest.matches(new MockHttpServletRequest("GET", "/api/system/maintenance/secret"))).isFalse();
        assertThat(PublicMaintenanceRequest.matches(new MockHttpServletRequest("GET", "/api/admin/server-operations/status"))).isFalse();
    }
}
