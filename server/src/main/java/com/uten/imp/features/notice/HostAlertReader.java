package com.uten.imp.features.notice;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.time.Instant;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.UUID;

/** Reads the bounded root-owned local queue without network calls or shell execution. */
@Component
public class HostAlertReader {
    private static final int MAX_BYTES = 65536;
    private final ObjectMapper mapper;
    private final String filename;

    public HostAlertReader(ObjectMapper mapper,
            @Value("${uten.server-status.host-alert-file:}") String filename) {
        this.mapper = mapper;
        this.filename = filename;
    }

    public record Event(UUID id, String severity, String title, Instant occurredAt) {}

    List<Event> read(Instant now) throws IOException {
        if (filename == null || filename.isBlank()) return List.of();
        Path path = Path.of(filename);
        if (!Files.exists(path, LinkOption.NOFOLLOW_LINKS)) return List.of();
        if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)) throw new IOException("Invalid host alert file");
        byte[] bytes;
        try (var input = Files.newInputStream(path, LinkOption.NOFOLLOW_LINKS)) {
            bytes = input.readNBytes(MAX_BYTES + 1);
        }
        if (bytes.length > MAX_BYTES) throw new IOException("Host alert file exceeds limit");
        var document = mapper.readTree(bytes);
        if (document == null || !"uten-host-alerts-v1".equals(document.path("format").asText())
                || !document.path("events").isArray() || document.path("events").size() > 128)
            throw new IOException("Invalid host alert format");
        var result = new ArrayList<Event>();
        var ids = new HashSet<UUID>();
        for (var item : document.path("events")) {
            try {
                UUID id = UUID.fromString(item.path("id").asText());
                String severity = item.path("severity").asText();
                String title = item.path("title").asText();
                if (!ids.add(id) || !("WARNING".equals(severity) || "CRITICAL".equals(severity))
                        || title.isBlank() || title.length() > 120 || title.chars().anyMatch(Character::isISOControl)
                        || !item.path("occurredAt").isIntegralNumber()
                        || !item.path("occurredAt").canConvertToLong())
                    throw new IllegalArgumentException();
                Instant occurredAt = Instant.ofEpochSecond(item.path("occurredAt").longValue());
                if (occurredAt.isAfter(now.plusSeconds(60))) throw new IllegalArgumentException();
                if (!occurredAt.isBefore(now.minusSeconds(7 * 86400)))
                    result.add(new Event(id, severity, title, occurredAt));
            } catch (RuntimeException invalid) {
                throw new IOException("Invalid host alert entry");
            }
        }
        return List.copyOf(result);
    }
}
