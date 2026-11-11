package com.uten.imp.common.readsnapshot;

import org.junit.jupiter.api.Test;
import org.springframework.boot.tomcat.servlet.TomcatServletWebServerFactory;
import org.springframework.boot.web.server.Compression;
import org.springframework.util.unit.DataSize;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.net.InetAddress;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;
import java.util.zip.GZIPInputStream;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 2026-11-10 (G): the complete NDJSON streams rely on connector compression for
 * their real-transfer size, but their responses are streamed frame by frame
 * without a Content-Length. MockMvc never passes the compression filter, so
 * this test proves the transport fact on a real Tomcat connector configured
 * exactly like {@code server.compression} in application.yml: a streamed
 * application/x-ndjson response that flushes once per frame is gzip-compressed
 * for clients that offer it, and plain for clients that do not.
 */
class CompleteStreamCompressionTomcatTest {

    @Test void aStreamedNdjsonResponseWithoutContentLengthIsCompressedByTheConnector() throws Exception {
        var factory = new TomcatServletWebServerFactory(0);
        factory.setAddress(InetAddress.getLoopbackAddress());
        factory.setBaseDirectory(Files.createTempDirectory("uten-ndjson-compression-").toFile());
        // Mirror of server.compression in application.yml (2026-11-09: 64KB start).
        var compression = new Compression();
        compression.setEnabled(true);
        compression.setMimeTypes(new String[] {"application/json", "application/x-ndjson"});
        compression.setMinResponseSize(DataSize.ofKilobytes(64));
        factory.setCompression(compression);
        var server = factory.getWebServer(context -> context.addServlet("summaries",
                new jakarta.servlet.http.HttpServlet() {
            @Override protected void doGet(jakarta.servlet.http.HttpServletRequest request,
                    jakarta.servlet.http.HttpServletResponse response) throws IOException {
                response.setContentType("application/x-ndjson");
                response.setCharacterEncoding("UTF-8");
                response.setHeader("Cache-Control", "no-store");
                var output = response.getOutputStream();
                // 200 frames of ~440 bytes ≈ 88KB total: over the 64KB threshold,
                // one JSON line per flush — the complete streams' exact shape.
                for (int frame = 0; frame < 200; frame++) {
                    String line = "{\"type\":\"page\",\"frame\":" + frame + ",\"pad\":\"" + "x".repeat(400) + "\"}\n";
                    output.write(line.getBytes(StandardCharsets.UTF_8));
                    response.flushBuffer();
                }
            }
        }).addMapping("/summaries"));
        server.start();
        try {
            var client = HttpClient.newHttpClient();
            var gzip = client.send(HttpRequest.newBuilder(URI.create(
                            "http://127.0.0.1:" + server.getPort() + "/summaries"))
                    .header("Accept", "application/x-ndjson")
                    .header("Accept-Encoding", "gzip").GET().build(),
                    HttpResponse.BodyHandlers.ofByteArray());
            assertThat(gzip.statusCode()).isEqualTo(200);
            // Streamed responses are never pre-sized.
            assertThat(gzip.headers().firstValue("Content-Length")).isEmpty();
            assertThat(gzip.headers().firstValue("Content-Encoding")).contains("gzip");
            var lines = new ArrayList<String>();
            try (var decompressed = new GZIPInputStream(new ByteArrayInputStream(gzip.body()))) {
                lines.addAll(new String(decompressed.readAllBytes(), StandardCharsets.UTF_8).lines().toList());
            }
            assertThat(lines).hasSize(200);
            assertThat(lines.getFirst()).startsWith("{\"type\":\"page\",\"frame\":0,").endsWith("}");
            assertThat(lines.getLast()).startsWith("{\"type\":\"page\",\"frame\":199,").endsWith("}");

            // A client that does not offer gzip receives the identical plain stream.
            var plain = client.send(HttpRequest.newBuilder(URI.create(
                            "http://127.0.0.1:" + server.getPort() + "/summaries"))
                    .header("Accept", "application/x-ndjson").GET().build(),
                    HttpResponse.BodyHandlers.ofByteArray());
            assertThat(plain.statusCode()).isEqualTo(200);
            assertThat(plain.headers().firstValue("Content-Encoding")).isEmpty();
            assertThat(new String(plain.body(), StandardCharsets.UTF_8).lines().count()).isEqualTo(200);
            assertThat(gzip.body().length).as("gzip should carry 88KB of repetitive NDJSON much smaller")
                    .isLessThan(plain.body().length / 4);
        } finally {
            server.stop();
        }
    }
}
