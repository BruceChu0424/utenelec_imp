package com.uten.imp.features.admin.serveroperations;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.GlobalExceptionHandler;
import com.uten.imp.features.admin.serverstatus.ServerStorageService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import java.nio.file.Path;
import java.time.Duration;
import java.util.Arrays;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import javax.sql.DataSource;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;

/** Real local transport through method authorization, status, badges and storage; no database needed. */
class ServerOperationsPlatformAvailabilityTest {
    @Configuration @EnableMethodSecurity static class Config {
        @Bean ObjectMapper mapper() { return new ObjectMapper().findAndRegisterModules(); }
        @Bean HostOperationsClient client(ObjectMapper mapper) {
            return spy(new UnixSocketHostOperationsClient(mapper,Path.of("/run/uten-imp-operations/control.sock"),Duration.ofSeconds(5),false));
        }
        @Bean SecurityContextCurrentUser current() { return new SecurityContextCurrentUser(); }
        @Bean AuditService audit() { return mock(AuditService.class); }
        @Bean ServerOperationsRuntimeBinding binding() { return mock(ServerOperationsRuntimeBinding.class); }
        @Bean ServerOperationsService service(HostOperationsClient client,SecurityContextCurrentUser current,
                ObjectMapper mapper,AuditService audit,ServerOperationsRuntimeBinding binding) {
            return new ServerOperationsService(client,current,mapper,audit,binding);
        }
        @Bean ServerOperationsController controller(ServerOperationsService service) { return new ServerOperationsController(service); }
    }

    @AfterEach void clear() { SecurityContextHolder.clearContext(); }

    @Test void unsupportedPlatformRetainsCapabilitiesButHasNoHostFactsOrUpdateTaskForAnyAuthorizedReader() {
        try (var context=new AnnotationConfigApplicationContext(Config.class)) {
            var controller=context.getBean(ServerOperationsController.class);
            var source=new ServerOperationsWorkbenchBadgeSources(controller).sources().getFirst();
            for (var permissions:java.util.List.of(Set.of("server:update"),Set.of("server_status:view"),Set.of("server:cleanup"),
                    Set.of("server:update","server:cleanup","authorization:manage"))) {
                boolean admin=permissions.contains("authorization:manage");
                login(permissions,admin);
                var view=controller.status();
                assertThat(view.available()).isFalse();
                assertThat(view.failure().code()).isEqualTo("HOST_PLATFORM_UNSUPPORTED");
                assertThat(view.failure().retrySafe()).isFalse();
                assertThat(view.canUpdate()).isEqualTo(admin || permissions.contains("server:update"));
                assertThat(view.canCleanup()).isEqualTo(admin || permissions.contains("server:cleanup"));
                assertThat(view.canConfigureSource()).isEqualTo(admin);
                assertThat(Arrays.asList(view.manualOnly(),view.timerActive(),view.timerEnabled(),view.currentVersion(),
                        view.sourceRevision(),view.sourceConfigured(),view.latestJob(),view.latestVersion(),view.lastCheckedAt(),
                        view.updateAvailable(),view.serverTimeZone(),view.serverTime())).containsOnlyNulls();
                assertThat(source.reader().get()).containsExactlyEntriesOf(Map.of("updates",0L));
            }
            verifyNoInteractions(context.getBean(ServerOperationsRuntimeBinding.class),context.getBean(AuditService.class));
        }
    }

    @Test void authorizedHttpReadsExplainThePlatformAndMutationFailsWithoutAnAuditOrPermissionBypass() throws Exception {
        try (var context=new AnnotationConfigApplicationContext(Config.class)) {
            var client=context.getBean(HostOperationsClient.class);
            var mapper=context.getBean(ObjectMapper.class);
            var http=MockMvcBuilders.standaloneSetup(context.getBean(ServerOperationsController.class))
                    .setControllerAdvice(new GlobalExceptionHandler()).build();
            login(Set.of("rd_task:view"),false);
            assertThat(http.perform(get("/api/admin/server-operations/status")).andReturn().getResponse().getStatus()).isEqualTo(403);
            verifyNoInteractions(client);

            login(Set.of("server_status:view"),false);
            var response=http.perform(get("/api/admin/server-operations/status")).andReturn().getResponse();
            assertThat(response.getStatus()).isEqualTo(200);
            var status=mapper.readTree(response.getContentAsString(java.nio.charset.StandardCharsets.UTF_8));
            assertThat(status.path("failure").path("code").asText()).isEqualTo("HOST_PLATFORM_UNSUPPORTED");
            assertThat(status.path("canUpdate").asBoolean()).isFalse();
            String request=mapper.writeValueAsString(Map.of("requestId",UUID.randomUUID(),"expectedSourceRevision","rev"));
            assertThat(http.perform(post("/api/admin/server-operations/updates/check").contentType("application/json").content(request))
                    .andReturn().getResponse().getStatus()).isEqualTo(403);
            verify(client,never()).call(eq(HostOperationsClient.Operation.UPDATE_START),anyMap(),any(),any());

            login(Set.of("server:update"),false);
            response=http.perform(post("/api/admin/server-operations/updates/check").contentType("application/json").content(request))
                    .andReturn().getResponse();
            assertThat(response.getStatus()).isEqualTo(503);
            var error=mapper.readTree(response.getContentAsString(java.nio.charset.StandardCharsets.UTF_8));
            assertThat(error.path("code").asText()).isEqualTo("SERVER_OPERATIONS_UNAVAILABLE");
            assertThat(error.path("message").asText()).contains("Linux", "本地开发环境");
            verifyNoInteractions(context.getBean(AuditService.class),context.getBean(ServerOperationsRuntimeBinding.class));
        }
    }

    @Test void linuxHelperFailureStillMakesTheBadgeStaleAndMissingReleaseConfigurationIsASeparateFact() {
        var mapper=new ObjectMapper().findAndRegisterModules();
        login(Set.of("server:update"),false);
        var client=new UnixSocketHostOperationsClient(mapper,Path.of("missing-operations-socket"),Duration.ofSeconds(5),true);
        var service=new ServerOperationsService(client,new SecurityContextCurrentUser(),mapper,mock(AuditService.class),mock(ServerOperationsRuntimeBinding.class));
        assertThat(service.status().failure().code()).isEqualTo("HOST_HELPER_UNAVAILABLE");
        var source=new ServerOperationsWorkbenchBadgeSources(new ServerOperationsController(service)).sources().getFirst();
        assertThatThrownBy(()->source.reader().get()).isInstanceOf(ApiException.class);

        var configuredClient=mock(HostOperationsClient.class);
        when(configuredClient.call(any(),anyMap(),any(),any())).thenReturn(mapper.createObjectNode()
                .put("available",true).put("manualOnly",true).put("timerActive",false).put("timerEnabled",false)
                .put("sourceConfigured",false));
        var unconfigured=new ServerOperationsService(configuredClient,new SecurityContextCurrentUser(),mapper,mock(AuditService.class),mock(ServerOperationsRuntimeBinding.class));
        var status=unconfigured.status();
        assertThat(status.available()).isTrue();assertThat(status.sourceConfigured()).isFalse();assertThat(status.failure()).isNull();
        assertThat(new ServerOperationsWorkbenchBadgeSources(new ServerOperationsController(unconfigured)).sources().getFirst().reader().get())
                .containsExactlyEntriesOf(Map.of("updates",0L));
    }

    @Test void unsupportedStorageRetainsApplicationFactsAndDoesNotInventHostCapacity() {
        try (var context=new AnnotationConfigApplicationContext(Config.class)) {
            login(Set.of("server:cleanup"),false);
            var storage=new ServerStorageService(context.getBean(HostOperationsClient.class),context.getBean(SecurityContextCurrentUser.class),
                    context.getBean(ObjectMapper.class),mock(DataSource.class),context.getBean(AuditService.class));
            var view=storage.summary();
            assertThat(view.capabilities().available()).isFalse();assertThat(view.capabilities().canCleanup()).isFalse();
            assertThat(view.capabilities().unavailableCode()).isEqualTo("HOST_PLATFORM_UNSUPPORTED");
            assertThat(view.capabilities().unavailableReason()).contains("Linux", "本地开发环境");
            assertThat(view.volumes()).isEmpty();assertThat(view.categories()).isEmpty();
            assertThat(view.process().heapUsedBytes()).isPositive();
            assertThat(view.database().sizeBytes()).isNull();assertThat(view.uploads().count()).isNull();
        }
    }

    private static void login(Set<String> permissions,boolean admin) {
        var actor=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"operator",permissions,false,true,admin);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(actor,null,actor.getAuthorities()));
    }
}
