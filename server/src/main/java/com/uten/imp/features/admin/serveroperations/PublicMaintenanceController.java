package com.uten.imp.features.admin.serveroperations;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.time.Clock;
import java.time.DateTimeException;
import java.time.OffsetDateTime;
import java.util.Set;
import java.util.UUID;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.CacheControl;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/** Same safe contract as nginx's fixed static alias, including direct native/dev connections. */
@RestController
public class PublicMaintenanceController {
    private static final Set<String> STATES = Set.of("available", "scheduled", "updating", "recovery_required");
    private final ObjectMapper mapper;
    private final Path statusFile;
    private final Clock clock;

    @Autowired
    public PublicMaintenanceController(ObjectMapper mapper) {
        this(mapper, Path.of("/var/lib/uten-imp-public/maintenance.json"), Clock.systemUTC());
    }

    PublicMaintenanceController(ObjectMapper mapper, Path statusFile, Clock clock) {
        this.mapper = mapper;
        this.statusFile = statusFile;
        this.clock = clock;
    }

    @GetMapping("/api/system/maintenance")
    public ResponseEntity<Snapshot> current() {
        try {
            var attributes = Files.readAttributes(statusFile, BasicFileAttributes.class, LinkOption.NOFOLLOW_LINKS);
            if (!attributes.isRegularFile() || attributes.size() > 4096) {
                return unavailable();
            }
            JsonNode data;
            try (InputStream input = Files.newInputStream(statusFile, StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS)) {
                byte[] bytes = input.readNBytes(4097);
                if (bytes.length > 4096) {
                    return unavailable();
                }
                data = mapper.readTree(bytes);
            }
            if (data == null || !data.isObject() || !data.path("schemaVersion").isInt()
                    || data.path("schemaVersion").intValue() != 1) {
                return unavailable();
            }
            String state = text(data, "state", 32);
            if (!STATES.contains(state == null ? "" : state)) {
                return unavailable();
            }
            String noticeId = text(data, "noticeId", 36);
            if (noticeId != null && !UUID.fromString(noticeId).toString().equals(noticeId)
                    || !"available".equals(state) && noticeId == null) {
                return unavailable();
            }
            String startsAt = text(data, "startsAt", 80);
            if (startsAt != null) {
                OffsetDateTime.parse(startsAt);
            } else if ("scheduled".equals(state)) {
                return unavailable();
            }
            String version = text(data, "targetVersion", 32);
            if (version != null && !version.matches("v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)")) {
                return unavailable();
            }
            // Construct a new record rather than returning the root helper's
            // object. Extra private fields can never leak through this endpoint.
            return ResponseEntity.ok().cacheControl(CacheControl.noStore()).body(new Snapshot(
                    1, state, noticeId, OffsetDateTime.now(clock).toString(), startsAt, version, 10));
        } catch (IOException | IllegalArgumentException | DateTimeException invalid) {
            // A missing/unreadable helper is unknown availability, never a
            // fabricated update. Clients retain inputs and use normal recovery.
            return unavailable();
        }
    }

    private static String text(JsonNode data, String key, int limit) {
        JsonNode value = data.get(key);
        if (value == null || value.isNull()) {
            return null;
        }
        if (!value.isTextual() || value.textValue().length() > limit) {
            throw new IllegalArgumentException("Invalid maintenance projection");
        }
        return value.textValue();
    }

    private static ResponseEntity<Snapshot> unavailable() {
        return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).cacheControl(CacheControl.noStore()).build();
    }

    public record Snapshot(int schemaVersion, String state, String noticeId, String serverTime,
            String startsAt, String targetVersion, int retryAfterSeconds) {}
}
