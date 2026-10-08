package com.uten.imp.features.notice;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;

class HostAlertReaderTest {
    @TempDir Path directory;
    final ObjectMapper mapper = new ObjectMapper();
    final Instant now = Instant.parse("2026-10-08T00:00:00Z");

    @Test void acceptsFreshEventsAndSkipsExpiredEvents() throws Exception {
        var current = event(now.minusSeconds(30));
        write(List.of(current, event(now.minusSeconds(8 * 86400))));
        assertThat(reader().read(now)).singleElement().satisfies(value -> {
            assertThat(value.id().toString()).isEqualTo(current.get("id"));
            assertThat(value.title()).isEqualTo("备份失败");
        });
    }

    @Test void invalidMemberRejectsEntireFileInsteadOfReturningPartialAlerts() throws Exception {
        write(List.of(event(now), Map.of("id", "bad")));
        assertThatThrownBy(() -> reader().read(now)).isInstanceOf(IOException.class);
    }

    @Test void rejectsDuplicatesFutureEventsAndOversize() throws Exception {
        var event = event(now);
        write(List.of(event, event));
        assertThatThrownBy(() -> reader().read(now)).isInstanceOf(IOException.class);
        write(List.of(event(now.plusSeconds(61))));
        assertThatThrownBy(() -> reader().read(now)).isInstanceOf(IOException.class);
        var oversizedTime = new java.util.HashMap<>(event);
        oversizedTime.put("occurredAt", new java.math.BigInteger("184467440737095516160"));
        write(List.of(oversizedTime));
        assertThatThrownBy(() -> reader().read(now)).isInstanceOf(IOException.class);
        Files.writeString(directory.resolve("events.json"), " ".repeat(65537));
        assertThatThrownBy(() -> reader().read(now)).isInstanceOf(IOException.class);
    }

    @Test void disabledOrNotInstalledIsEmpty() throws Exception {
        assertThat(new HostAlertReader(mapper, "").read(now)).isEmpty();
        assertThat(reader().read(now)).isEmpty();
    }

    Map<String, Object> event(Instant time) {
        return Map.of("id", UUID.randomUUID().toString(), "severity", "CRITICAL",
                "title", "备份失败", "occurredAt", time.getEpochSecond());
    }
    void write(List<?> events) throws Exception {
        mapper.writeValue(directory.resolve("events.json").toFile(),
                Map.of("format", "uten-host-alerts-v1", "events", events));
    }
    HostAlertReader reader() { return new HostAlertReader(mapper, directory.resolve("events.json").toString()); }
}
