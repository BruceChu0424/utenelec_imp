package com.uten.imp.config;

import com.uten.imp.config.props.DeploymentProperties;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.boot.tomcat.servlet.TomcatServletWebServerFactory;
import org.springframework.boot.web.server.WebServer;
import org.springframework.core.io.InputStreamResource;
import org.springframework.http.MediaType;
import org.springframework.http.converter.ResourceHttpMessageConverter;
import org.springframework.http.server.ServletServerHttpResponse;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.*;

/** Real kernel backpressure and real ResourceHttpMessageConverter; no mocked socket or output stream. */
class RemoteIngressSlowReceiverTomcatTest {
    private static final long SIZE = 32L * 1024 * 1024;
    @TempDir static Path directory;
    private static Path payload;
    private static String checksum;

    @BeforeAll static void payload() throws Exception {
        payload = directory.resolve("resource.bin");
        byte[] block = new byte[64 * 1024];
        new java.util.Random(2539).nextBytes(block);
        try (var output = Files.newOutputStream(payload)) {
            for (int i = 0; i < SIZE / block.length; i++) output.write(block);
        }
        var digest = MessageDigest.getInstance("SHA-256");
        try (var input = Files.newInputStream(payload)) {
            byte[] buffer = new byte[64 * 1024];
            for (int count; (count = input.read(buffer)) != -1;) digest.update(buffer, 0, count);
        }
        checksum = HexFormat.of().formatHex(digest.digest());
    }

    @Test
    void remoteSynchronousResourceSurvivesTwelveSecondReceiverPause() throws Exception {
        try (Harness harness = server()) {
            Read result = receive(harness.remotePort(), 12_000);
            record("remote", result, harness.failure());
            assertAll(() -> assertEquals(200, result.status()),
                    () -> assertEquals(Long.toString(SIZE), result.headers().get("content-length")),
                    () -> assertNull(result.headers().get("content-encoding")),
                    () -> assertEquals(SIZE, result.bytes(), "A valid slow receiver must receive the entire declared file"),
                    () -> assertEquals(checksum, result.sha256()),
                    () -> assertNull(result.failure()),
                    () -> assertNull(harness.failure().get()));
        }
    }

    @Test
    void primaryLanResourceKeepsTheSameSlowReceiverBehavior() throws Exception {
        try (Harness harness = server()) {
            Read result = receive(harness.server().getPort(), 12_000);
            record("primary", result, harness.failure());
            assertAll(() -> assertEquals(SIZE, result.bytes()),
                    () -> assertEquals(checksum, result.sha256()),
                    () -> assertNull(result.failure()),
                    () -> assertNull(harness.failure().get()));
        }
    }

    @Test
    void remotePartialHeadersStillExpireAtTheOriginalTenSecondReadBudget() throws Exception {
        try (Harness harness = server(); Socket socket = new Socket()) {
            socket.connect(new java.net.InetSocketAddress("127.0.0.1", harness.remotePort()));
            socket.setSoTimeout(17_000);
            socket.getOutputStream().write("GET /resource HTTP/1.1\r\nHost: localhost\r\nX-Incomplete:"
                    .getBytes(StandardCharsets.US_ASCII));
            socket.getOutputStream().flush();
            long start = System.nanoTime();
            int first = socket.getInputStream().read();
            long elapsed = (System.nanoTime() - start) / 1_000_000;
            System.out.println("REMOTE_PARTIAL_HEADER elapsedMillis=" + elapsed + " firstByte=" + first);
            assertTrue(first == -1 || first == 'H', "Tomcat may close or return HTTP408 for incomplete headers");
            assertTrue(elapsed >= 8_000 && elapsed < 16_000, "The original10s read budget must remain bounded");
        }
    }

    @Test
    void configuredRemoteWriteBudgetStillRejectsANonProgressingReceiver() throws Exception {
        var properties = new DeploymentProperties();
        properties.setRemoteWriteTimeout(java.time.Duration.ofSeconds(1));
        try (Harness harness = server(properties)) {
            Read result = receive(harness.remotePort(), 2_000);
            record("finite-remote-write", result, harness.failure());
            assertTrue(result.bytes() < SIZE, "A finite configured write budget must still abort a stalled receiver");
            assertNotNull(harness.failure().get());
            Throwable cause = harness.failure().get();
            while (cause.getCause() != null) cause = cause.getCause();
            assertInstanceOf(java.net.SocketTimeoutException.class, cause);
        }
    }

    private static Harness server() throws Exception {
        return server(new DeploymentProperties());
    }

    private static Harness server(DeploymentProperties properties) throws Exception {
        properties.setRemoteIngressEnabled(true);
        int remotePort;
        try (var reservation = new ServerSocket(0, 1, InetAddress.getLoopbackAddress())) {
            remotePort = reservation.getLocalPort();
        }
        properties.setRemoteIngressPort(remotePort);
        var factory = new TomcatServletWebServerFactory(0);
        factory.setAddress(InetAddress.getLoopbackAddress());
        factory.setBaseDirectory(Files.createTempDirectory(directory, "tomcat-").toFile());
        new RemoteIngressConnectorConfiguration().remoteIngressConnector(properties, 0, 20).customize(factory);
        var failure = new AtomicReference<IOException>();
        var server = factory.getWebServer(context -> context.addServlet("resource", new jakarta.servlet.http.HttpServlet() {
            @Override protected void doGet(jakarta.servlet.http.HttpServletRequest request,
                    jakarta.servlet.http.HttpServletResponse response) throws IOException {
                if (!"/resource".equals(request.getRequestURI())) { response.sendError(404); return; }
                var output = new ServletServerHttpResponse(response);
                output.getHeaders().setContentLength(SIZE);
                output.getHeaders().setContentType(MediaType.APPLICATION_OCTET_STREAM);
                try {
                    // Same synchronous converter, stream type and explicit length as ClientUpdateController.
                    new ResourceHttpMessageConverter().write(new InputStreamResource(
                            Files.newInputStream(payload, LinkOption.NOFOLLOW_LINKS)), MediaType.APPLICATION_OCTET_STREAM, output);
                } catch (IOException expectedTransportFailure) {
                    failure.compareAndSet(null, expectedTransportFailure);
                }
            }
        }).addMapping("/resource"));
        server.start();
        return new Harness(server, remotePort, failure);
    }

    private static Read receive(int port, long pauseMillis) throws Exception {
        var digest = MessageDigest.getInstance("SHA-256");
        long started = System.nanoTime(), count = 0;
        IOException failure = null;
        int status;
        var headers = new LinkedHashMap<String, String>();
        try (Socket socket = new Socket()) {
            socket.setReceiveBufferSize(1024);
            socket.setSoTimeout(25_000);
            socket.connect(new java.net.InetSocketAddress("127.0.0.1", port));
            socket.getOutputStream().write("GET /resource HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n"
                    .getBytes(StandardCharsets.US_ASCII));
            socket.getOutputStream().flush();
            var header = new ByteArrayOutputStream();
            while (header.size() < 16_384) {
                int value = socket.getInputStream().read();
                if (value == -1) throw new IOException("EOF before response headers");
                header.write(value);
                byte[] bytes = header.toByteArray();
                int n = bytes.length;
                if (n >= 4 && bytes[n-4] == '\r' && bytes[n-3] == '\n' && bytes[n-2] == '\r' && bytes[n-1] == '\n') break;
            }
            String[] lines = header.toString(StandardCharsets.US_ASCII).split("\r\n");
            status = Integer.parseInt(lines[0].split(" ")[1]);
            for (int i = 1; i < lines.length; i++) {
                int colon = lines[i].indexOf(':');
                if (colon > 0) headers.put(lines[i].substring(0, colon).toLowerCase(java.util.Locale.ROOT), lines[i].substring(colon+1).trim());
            }
            Thread.sleep(pauseMillis);
            socket.setReceiveBufferSize(1024 * 1024);
            byte[] buffer = new byte[64 * 1024];
            try {
                while (count < SIZE) {
                    int read = socket.getInputStream().read(buffer);
                    if (read == -1) break;
                    digest.update(buffer, 0, read); count += read;
                }
            } catch (IOException transportFailure) { failure = transportFailure; }
        }
        return new Read(status, Map.copyOf(headers), count, HexFormat.of().formatHex(digest.digest()),
                (System.nanoTime()-started)/1_000_000, failure);
    }

    private static void record(String target, Read result, AtomicReference<IOException> failure) {
        System.out.println("REMOTE_RESOURCE target=" + target + " bytes=" + result.bytes() + " expected=" + SIZE
                + " elapsedMillis=" + result.elapsedMillis() + " sha256=" + result.sha256()
                + " serverFailure=" + (failure.get() == null ? "none" : failure.get().getClass().getName()));
    }
    private record Harness(WebServer server, int remotePort, AtomicReference<IOException> failure) implements AutoCloseable {
        @Override public void close() { server.stop(); }
    }
    private record Read(int status, Map<String,String> headers, long bytes, String sha256, long elapsedMillis, IOException failure) {}
}
