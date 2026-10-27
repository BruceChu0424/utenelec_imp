package com.uten.imp.features.clientupdates;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.GlobalExceptionHandler;
import com.uten.imp.config.props.StorageProperties;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/** Real HTTP controllers, method authorization, service, package inspection and durable file catalog. */
class ClientReleasePublicationFlowTest {
    @TempDir Path directory;

    @Configuration
    @EnableMethodSecurity
    static class Config {
        @Bean ObjectMapper mapper() { return new ObjectMapper().findAndRegisterModules(); }
        @Bean AuditService audit() { return mock(AuditService.class); }
        @Bean SecurityContextCurrentUser users() { return new SecurityContextCurrentUser(); }
        @Bean ClientReleaseCatalog catalog(ClientUpdateProperties properties, ObjectMapper mapper) {
            return new ClientReleaseCatalog(properties, new StorageProperties(), mapper);
        }
        @Bean ClientPackageInspector inspector(ObjectMapper mapper) { return new ClientPackageInspector(mapper); }
        @Bean ClientReleaseService service(ClientReleaseCatalog catalog, ClientPackageInspector inspector,
                                          ClientUpdateProperties properties, SecurityContextCurrentUser users, AuditService audit) {
            return new ClientReleaseService(catalog, inspector, properties, users, audit);
        }
        @Bean ClientReleaseAdminController admin(ClientReleaseService service) { return new ClientReleaseAdminController(service); }
        @Bean ClientUpdateController client(ClientReleaseService service) { return new ClientUpdateController(service); }
    }

    @AfterEach void clearSession() { SecurityContextHolder.clearContext(); }

    @Test
    void employeeGrantPublishDiscoverDownloadRevokeAndWithdrawUseRealReleaseChain() throws Exception {
        var properties = new ClientUpdateProperties();
        properties.setDirectory(directory.toString());
        try (var context = new AnnotationConfigApplicationContext()) {
            context.registerBean(ClientUpdateProperties.class, () -> properties);
            context.register(Config.class);
            context.refresh();
            var mapper = context.getBean(ObjectMapper.class);
            MockMvc mvc = MockMvcBuilders.standaloneSetup(context.getBean(ClientReleaseAdminController.class),
                            context.getBean(ClientUpdateController.class))
                    .setControllerAdvice(new GlobalExceptionHandler()).build();
            UUID publisher = UUID.randomUUID(), employee = UUID.randomUUID(), release = UUID.randomUUID();
            byte[] zip = windowsPackage(mapper, 2532);
            String hash = sha256(zip);
            var legacyRequest = mapper.valueToTree(new ClientReleaseDto.Create(release, "windows", "x64", "2.5.32", 2532,
                    "客户端更新测试", false, "uten-imp-2.5.32-windows-x64.zip", hash, null));
            ((com.fasterxml.jackson.databind.node.ObjectNode) legacyRequest).remove("packageKind");
            byte[] request = mapper.writeValueAsBytes(legacyRequest);

            login(publisher, Set.of("authorization:manage", "server:update"));
            mvc.perform(post("/api/admin/client-releases").contentType("application/json").content(request))
                    .andExpect(status().isForbidden());
            assertThat(Files.exists(directory.resolve(release.toString()))).isFalse();

            login(publisher, Set.of(ClientReleaseService.PUBLISH_PERMISSION));
            mvc.perform(post("/api/admin/client-releases").contentType("application/json").content(request))
                    .andExpect(status().isCreated()).andExpect(jsonPath("$.state").value("DRAFT"))
                    .andExpect(jsonPath("$.packageKind").value("update"));
            mvc.perform(put("/api/admin/client-releases/{id}/package", release).contentType("application/octet-stream").content(zip))
                    .andExpect(status().isOk()).andExpect(jsonPath("$.state").value("DRAFT"))
                    .andExpect(jsonPath("$.sha256").value(hash)).andExpect(jsonPath("$.sizeBytes").value(zip.length));
            assertThat(Files.readAllBytes(directory.resolve(release.toString()).resolve("package.bin"))).isEqualTo(zip);

            login(employee, Set.of());
            check(mvc, "x64", 2531, false);
            mvc.perform(get("/api/client-updates/{id}/download", release)).andExpect(status().isNotFound());
            mvc.perform(post("/api/admin/client-releases/{id}/publish", release)).andExpect(status().isForbidden());

            login(publisher, Set.of(ClientReleaseService.PUBLISH_PERMISSION));
            mvc.perform(post("/api/admin/client-releases/{id}/publish", release))
                    .andExpect(status().isOk()).andExpect(jsonPath("$.state").value("PUBLISHED"));
            verify(context.getBean(AuditService.class)).logExplicit(publisher, "release-employee", "client_release_publish",
                    "client_release", release.toString(), "success");

            login(employee, Set.of());
            check(mvc, "x64", 2531, true);
            check(mvc, "arm64", 2531, false);
            check(mvc, "x64", 2532, false);
            mvc.perform(get("/api/client-updates/{id}/download", release)).andExpect(status().isOk())
                    .andExpect(header().string("X-Checksum-Sha256", hash))
                    .andExpect(header().string("Content-Length", Integer.toString(zip.length)))
                    .andExpect(content().bytes(zip));

            // Rebuilding the next authenticated request reflects the same account's revoked capability.
            login(publisher, Set.of());
            mvc.perform(get("/api/admin/client-releases")).andExpect(status().isForbidden());
            mvc.perform(post("/api/admin/client-releases/{id}/withdraw", release)).andExpect(status().isForbidden());
            check(mvc, "x64", 2531, true);

            login(publisher, Set.of(ClientReleaseService.PUBLISH_PERMISSION));
            mvc.perform(post("/api/admin/client-releases/{id}/withdraw", release))
                    .andExpect(status().isOk()).andExpect(jsonPath("$.state").value("WITHDRAWN"));
            login(employee, Set.of());
            check(mvc, "x64", 2531, false);
            mvc.perform(get("/api/client-updates/{id}/download", release)).andExpect(status().isNotFound());
        }
    }

    @Test
    void completeWindowsInstallerUsesSharedPublicationCatalogAndEmployeeDownloadWithoutEnteringUpdateChannel() throws Exception {
        var properties = new ClientUpdateProperties();
        properties.setDirectory(directory.toString());
        try (var context = new AnnotationConfigApplicationContext()) {
            context.registerBean(ClientUpdateProperties.class, () -> properties);
            context.register(Config.class);
            context.refresh();
            var mapper = context.getBean(ObjectMapper.class);
            MockMvc mvc = MockMvcBuilders.standaloneSetup(context.getBean(ClientReleaseAdminController.class),
                            context.getBean(ClientUpdateController.class))
                    .setControllerAdvice(new GlobalExceptionHandler()).build();
            UUID publisher = UUID.randomUUID(), employee = UUID.randomUUID(), first = UUID.randomUUID();
            byte[] firstZip = WindowsSetupFixture.bytes(2532, "x64", "2.5.32");

            login(employee, Set.of());
            mvc.perform(get("/api/client-updates/downloads")).andExpect(status().isOk()).andExpect(content().json("[]"));
            login(publisher, Set.of(ClientReleaseService.PUBLISH_PERMISSION));
            createAndUpload(mvc, mapper, first, 2532, "x64", "installer", firstZip);
            login(employee, Set.of());
            mvc.perform(get("/api/client-updates/downloads")).andExpect(status().isOk()).andExpect(content().json("[]"));
            mvc.perform(get("/api/client-updates/{id}/download", first)).andExpect(status().isNotFound());
            login(publisher, Set.of(ClientReleaseService.PUBLISH_PERMISSION));
            mvc.perform(post("/api/admin/client-releases/{id}/publish", first)).andExpect(status().isOk())
                    .andExpect(jsonPath("$.packageKind").value("installer"))
                    .andExpect(jsonPath("$.installMode").value("windows_setup"));

            login(employee, Set.of());
            mvc.perform(get("/api/client-updates/downloads")).andExpect(status().isOk())
                    .andExpect(header().string("Cache-Control", "private, no-store"))
                    .andExpect(jsonPath("$.length()").value(1)).andExpect(jsonPath("$[0].id").value(first.toString()));
            check(mvc, "x64", 2531, false);
            mvc.perform(get("/api/client-updates/{id}/download", first)).andExpect(status().isOk())
                    .andExpect(header().string("X-Checksum-Sha256", sha256(firstZip)))
                    .andExpect(content().bytes(firstZip));

            var unboundAdministrator = new AuthUser(UUID.randomUUID(), null, "administrator", Set.of(), false, true, true);
            SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(
                    unboundAdministrator, null, unboundAdministrator.getAuthorities()));
            mvc.perform(get("/api/client-updates/downloads")).andExpect(status().isOk())
                    .andExpect(jsonPath("$[0].id").value(first.toString()));
            mvc.perform(get("/api/client-updates/{id}/download", first)).andExpect(status().isOk())
                    .andExpect(content().bytes(firstZip));

            var visitor = AuthUser.visitor(UUID.randomUUID(), "visitor", "V1", Set.of());
            var changePassword = new AuthUser(employee, employee, "release-employee", Set.of(), true, true, false);
            var unboundEmployee = new AuthUser(UUID.randomUUID(), null, "unbound", Set.of(), false, true, false);
            for (AuthUser denied : List.of(visitor, changePassword, unboundEmployee)) {
                SecurityContextHolder.getContext().setAuthentication(
                        new UsernamePasswordAuthenticationToken(denied, null, denied.getAuthorities()));
                mvc.perform(get("/api/client-updates/downloads")).andExpect(status().isForbidden());
                mvc.perform(get("/api/client-updates/{id}/download", first)).andExpect(status().isForbidden());
            }
            SecurityContextHolder.clearContext();
            mvc.perform(get("/api/client-updates/downloads")).andExpect(status().is4xxClientError());
            mvc.perform(get("/api/client-updates/{id}/download", first)).andExpect(status().is4xxClientError());

            login(publisher, Set.of(ClientReleaseService.PUBLISH_PERMISSION));
            UUID update = UUID.randomUUID(), latest = UUID.randomUUID(), arm = UUID.randomUUID();
            byte[] updateZip = windowsPackage(mapper, 2533);
            createAndUpload(mvc, mapper, update, 2533, "x64", "update", updateZip);
            mvc.perform(post("/api/admin/client-releases/{id}/publish", update)).andExpect(status().isOk());
            assertThat(directory.resolve(first.toString()).resolve("package.bin")).isRegularFile();
            createAndUpload(mvc, mapper, latest, 2533, "x64", "installer", WindowsSetupFixture.bytes(2533, "x64", "2.5.32"));
            mvc.perform(post("/api/admin/client-releases/{id}/publish", latest)).andExpect(status().isOk());
            assertThat(directory.resolve(first.toString()).resolve("package.bin")).doesNotExist();
            var retired = mapper.readTree(Files.readString(directory.resolve(first.toString()).resolve("release.json")));
            assertThat(retired.path("state").asText()).isEqualTo("WITHDRAWN");
            assertThat(retired.path("sha256").isNull()).isTrue();
            assertThat(retired.path("sizeBytes").asLong(-1)).isZero();
            assertThat(retired.path("expectedSha256").asText()).isEqualTo(sha256(firstZip));
            assertThat(retired.path("publishedAt").isNull()).isFalse();
            createAndUpload(mvc, mapper, arm, 2530, "arm64", "installer", WindowsSetupFixture.bytes(2530, "arm64", "2.5.32"));
            mvc.perform(post("/api/admin/client-releases/{id}/publish", arm)).andExpect(status().isOk());

            login(employee, Set.of());
            check(mvc, "x64", 2532, true);
            mvc.perform(get("/api/client-updates/downloads")).andExpect(status().isOk())
                    .andExpect(jsonPath("$.length()").value(2))
                    .andExpect(jsonPath("$[0].id").value(arm.toString()))
                    .andExpect(jsonPath("$[1].id").value(latest.toString()));
            mvc.perform(get("/api/client-updates/{id}/download", first)).andExpect(status().isNotFound());
            mvc.perform(get("/api/client-updates/{id}/download", update)).andExpect(status().isOk())
                    .andExpect(header().string("X-Checksum-Sha256", sha256(updateZip))).andExpect(content().bytes(updateZip));

            login(publisher, Set.of(ClientReleaseService.PUBLISH_PERMISSION));
            mvc.perform(post("/api/admin/client-releases/{id}/withdraw", latest)).andExpect(status().isOk());
            login(employee, Set.of());
            mvc.perform(get("/api/client-updates/downloads")).andExpect(status().isOk())
                    .andExpect(jsonPath("$.length()").value(1)).andExpect(jsonPath("$[0].id").value(arm.toString()));
            mvc.perform(get("/api/client-updates/{id}/download", first)).andExpect(status().isNotFound());
            mvc.perform(get("/api/client-updates/{id}/download", latest)).andExpect(status().isNotFound());
            mvc.perform(get("/api/client-updates/{id}/download", update)).andExpect(status().isOk()).andExpect(content().bytes(updateZip));
            login(publisher, Set.of(ClientReleaseService.PUBLISH_PERMISSION));
            mvc.perform(post("/api/admin/client-releases/{id}/withdraw", first)).andExpect(status().isOk());
            mvc.perform(post("/api/admin/client-releases/{id}/withdraw", arm)).andExpect(status().isOk());
            login(employee, Set.of());
            mvc.perform(get("/api/client-updates/downloads")).andExpect(status().isOk()).andExpect(content().json("[]"));
            check(mvc, "x64", 2532, true);
        }
    }

    private static void createAndUpload(MockMvc mvc, ObjectMapper mapper, UUID id, long build, String architecture,
                                        String kind, byte[] zip) throws Exception {
        byte[] request = mapper.writeValueAsBytes(new ClientReleaseDto.Create(id, "windows", architecture, "2.5.32", build,
                "软件发布测试", false, "installer".equals(kind) ? "UtenIMPSetup.exe" : "uten-windows.zip", sha256(zip), null, kind));
        mvc.perform(post("/api/admin/client-releases").contentType("application/json").content(request))
                .andExpect(status().isCreated()).andExpect(jsonPath("$.state").value("DRAFT"));
        mvc.perform(put("/api/admin/client-releases/{id}/package", id).contentType("application/octet-stream").content(zip))
                .andExpect(status().isOk()).andExpect(jsonPath("$.state").value("DRAFT"))
                .andExpect(jsonPath("$.sha256").value(sha256(zip)));
    }

    private static void check(MockMvc mvc, String architecture, long currentBuild, boolean available) throws Exception {
        mvc.perform(get("/api/client-updates/check").param("platform", "windows").param("architecture", architecture)
                        .param("currentBuildNumber", Long.toString(currentBuild)))
                .andExpect(status().isOk()).andExpect(jsonPath("$.updateAvailable").value(available));
    }

    private static void login(UUID user, Set<String> permissions) {
        var principal = new AuthUser(user, user, "release-employee", permissions, false, true, false);
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(principal, null, principal.getAuthorities()));
    }

    private static byte[] windowsPackage(ObjectMapper mapper, long build) throws Exception {
        return windowsPackage(mapper, build, "x64", "update");
    }

    private static byte[] windowsPackage(ObjectMapper mapper, long build, String architecture, String kind) throws Exception {
        Map<String, byte[]> files = new LinkedHashMap<>();
        for (String name : List.of("uten_imp.exe", "flutter_windows.dll", "data/app.so", "data/icudtl.dat", "data/flutter_assets/AssetManifest.bin")) {
            files.put(name, ("fixture:" + name).getBytes(StandardCharsets.UTF_8));
        }
        if ("installer".equals(kind)) files.put("client_updater/client_updater.ps1", "trusted bootstrap updater".getBytes(StandardCharsets.UTF_8));
        List<Map<String, Object>> entries = new ArrayList<>();
        files.forEach((name, bytes) -> entries.add(Map.of("path", name, "size", bytes.length, "sha256", sha256(bytes))));
        Map<String, Object> manifest = new LinkedHashMap<>(Map.of("schemaVersion", 1, "platform", "windows",
                "architecture", architecture, "buildNumber", build, "executable", "uten_imp.exe", "files", entries));
        if ("installer".equals(kind)) manifest.put("packageKind", "installer");
        files.put("uten-client-manifest.json", mapper.writeValueAsBytes(manifest));
        var output = new ByteArrayOutputStream();
        try (var zip = new ZipOutputStream(output)) {
            for (var file : files.entrySet()) {
                zip.putNextEntry(new ZipEntry(file.getKey()));
                zip.write(file.getValue());
                zip.closeEntry();
            }
        }
        return output.toByteArray();
    }

    private static String sha256(byte[] bytes) {
        return HexFormat.of().formatHex(ClientPackageInspector.digest().digest(bytes));
    }
}
