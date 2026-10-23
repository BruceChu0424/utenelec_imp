package com.uten.imp.features.admin.disasterrecovery;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.sun.net.httpserver.HttpServer;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TrustedRequestOriginPolicy;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class DisasterRecoveryEnrollmentControllerTest {
    @TempDir Path directory;

    @Test
    void localSuperAdminIsBoundToIndependentBrokerWithoutForwardingErpSession() throws Exception {
        var current = mock(SecurityContextCurrentUser.class);
        var origins = mock(TrustedRequestOriginPolicy.class);
        var user = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "admin", Set.of(), false, true, true);
        when(current.get()).thenReturn(Optional.of(user));
        when(origins.current()).thenReturn(TrustedRequestOriginPolicy.Origin.LOCAL);
        Path credential = directory.resolve("broker.token");
        Files.writeString(credential, "B".repeat(64));
        if (credential.getFileSystem().supportedFileAttributeViews().contains("posix")) {
            // Real systemd LoadCredential may report an ACL mask of 0440.
            Files.setPosixFilePermissions(credential, Set.of(
                    java.nio.file.attribute.PosixFilePermission.OWNER_READ,
                    java.nio.file.attribute.PosixFilePermission.GROUP_READ));
        }
        AtomicInteger calls = new AtomicInteger();
        var server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/v1/broker/enrollments", exchange -> {
            assertEquals("Bearer " + "B".repeat(64), exchange.getRequestHeaders().getFirst("Authorization"));
            assertNull(exchange.getRequestHeaders().getFirst("Cookie"));
            var body = new ObjectMapper().readTree(exchange.getRequestBody());
            assertEquals(user.getId().toString(), body.path("subject").asText());
            assertTrue(body.path("stepUpVerified").asBoolean());
            calls.incrementAndGet();
            byte[] response = ("{\"enrollmentToken\":\"" + "A".repeat(64) + "\",\"expiresAt\":\"2026-10-23T21:00:00Z\"}")
                    .getBytes(StandardCharsets.UTF_8);
            exchange.sendResponseHeaders(200, response.length);
            exchange.getResponseBody().write(response);
            exchange.close();
        });
        server.start();
        try {
            var controller = new DisasterRecoveryEnrollmentController(current, origins, new ObjectMapper(),
                    "http://127.0.0.1:" + server.getAddress().getPort(), credential.toString());
            assertEquals("A".repeat(64), controller.enroll().get("enrollmentToken"));
            assertEquals(1, calls.get());
            when(origins.current()).thenReturn(TrustedRequestOriginPolicy.Origin.REMOTE);
            assertThrows(ApiException.class, controller::enroll);
            assertEquals(1, calls.get());
        } finally {
            server.stop(0);
        }
    }

    @Test
    void ordinaryAdminAndArbitraryBrokerTargetsAreRefused() throws Exception {
        var current = mock(SecurityContextCurrentUser.class);
        var origins = mock(TrustedRequestOriginPolicy.class);
        when(origins.current()).thenReturn(TrustedRequestOriginPolicy.Origin.LOCAL);
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), UUID.randomUUID(),
                "ordinary", Set.of("authorization:manage"), false, true, false)));
        var controller = new DisasterRecoveryEnrollmentController(current, origins, new ObjectMapper(),
                "http://169.254.169.254", directory.resolve("absent").toString());
        assertThrows(ApiException.class, controller::enroll);
        when(current.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(), UUID.randomUUID(),
                "admin", Set.of(), false, true, true)));
        assertThrows(ApiException.class, controller::enroll);
    }
}
