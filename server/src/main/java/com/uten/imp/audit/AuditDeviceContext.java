package com.uten.imp.audit;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.servlet.http.HttpServletRequest;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Component;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.Base64;
import java.util.HexFormat;
import java.util.List;
import java.util.Set;
import java.util.UUID;

/**
 * Parses the versioned audit-device header once and exposes only a strict,
 * bounded allow-list to audit persistence.
 */
@Component
public class AuditDeviceContext {

    public static final String HEADER_CLIENT_EVENT_ID = "X-Uten-Operation-Id";
    public static final String HEADER_DEVICE_CONTEXT = "X-Uten-Audit-Context";
    public static final String ATTRIBUTE =
            AuditDeviceContext.class.getName() + ".evidence";

    private static final int MAX_ENCODED_HEADER = 4_096;
    private static final Set<String> PLATFORMS =
            Set.of("android", "ios", "windows", "macos", "linux", "web", "unknown");
    private static final Set<String> FORM_FACTORS =
            Set.of("mobile", "desktop", "web", "unknown");
    private static final Duration MAX_PAST_CLOCK_SKEW = Duration.ofDays(7);
    private static final Duration MAX_FUTURE_CLOCK_SKEW = Duration.ofDays(1);

    private final ObjectMapper objectMapper;
    private final Clock clock;

    @Autowired
    public AuditDeviceContext(ObjectMapper objectMapper) {
        this(objectMapper, Clock.systemUTC());
    }

    AuditDeviceContext(ObjectMapper objectMapper, Clock clock) {
        this.objectMapper = objectMapper;
        this.clock = clock;
    }

    public AuditDeviceEvidence ensure(HttpServletRequest request) {
        Object existing = request.getAttribute(ATTRIBUTE);
        if (existing instanceof AuditDeviceEvidence evidence) {
            return evidence;
        }
        AuditDeviceEvidence evidence = parse(request);
        request.setAttribute(ATTRIBUTE, evidence);
        return evidence;
    }

    public String sessionJson(HttpServletRequest request) {
        try {
            return objectMapper.writeValueAsString(ensure(request).toSessionMap());
        } catch (Exception ignored) {
            return "{\"captureStatus\":\"invalid\"}";
        }
    }

    private AuditDeviceEvidence parse(HttpServletRequest request) {
        String eventHeader = request.getHeader(HEADER_CLIENT_EVENT_ID);
        UUID clientEventId = uuid(eventHeader);
        boolean invalidEventId = eventHeader != null
                && !eventHeader.isBlank()
                && clientEventId == null;
        String encoded = request.getHeader(HEADER_DEVICE_CONTEXT);
        if (encoded == null || encoded.isBlank()) {
            return empty(
                    clientEventId,
                    invalidEventId ? "invalid" : clientEventId == null ? "missing" : "partial");
        }
        if (encoded.length() > MAX_ENCODED_HEADER) {
            return empty(clientEventId, "invalid");
        }

        try {
            byte[] decoded = Base64.getUrlDecoder().decode(encoded);
            if (decoded.length > MAX_ENCODED_HEADER) {
                return empty(clientEventId, "invalid");
            }
            JsonNode root = objectMapper.readTree(new String(decoded, StandardCharsets.UTF_8));
            if (root == null || !root.isObject() || root.path("version").asInt(-1) != 1) {
                return empty(clientEventId, "invalid");
            }

            String installationText = text(root, "installationId", 64);
            UUID installationId = uuid(installationText);
            String deviceName = text(root, "deviceName", 200);
            String manufacturer = text(root, "manufacturer", 120);
            String model = text(root, "model", 160);
            String platformText = text(root, "platform", 32);
            String platform = enumText(root, "platform", 32, PLATFORMS);
            String osVersion = text(root, "osVersion", 200);
            String appVersion = text(root, "appVersion", 64);
            String appBuild = text(root, "appBuild", 64);
            String formFactorText = text(root, "formFactor", 32);
            String formFactor = enumText(root, "formFactor", 32, FORM_FACTORS);
            String browserName = text(root, "browserName", 80);
            String locale = text(root, "locale", 64);
            String timeZone = text(root, "timeZone", 80);
            JsonNode offsetNode = root.get("timeZoneOffsetMinutes");
            Integer offset = boundedInt(offsetNode, -840, 840);
            JsonNode physicalNode = root.get("isPhysicalDevice");
            Boolean physical = physicalNode != null
                    && physicalNode.isBoolean()
                    ? physicalNode.booleanValue()
                    : null;
            String clientEventAtText = text(root, "clientEventAt", 80);
            OffsetDateTime clientEventAt = offsetDateTime(clientEventAtText);

            boolean invalidField = invalidEventId
                    || installationText != null && installationId == null
                    || platformText != null && platform == null
                    || formFactorText != null && formFactor == null
                    || offsetNode != null && offset == null
                    || physicalNode != null && !physicalNode.isBoolean()
                    || clientEventAtText != null && clientEventAt == null;

            boolean primaryComplete = !invalidField
                    && clientEventId != null
                    && installationId != null
                    && platform != null
                    && appVersion != null
                    && clientEventAt != null;
            String status = invalidField
                    ? "invalid"
                    : primaryComplete ? "present" : "partial";
            String profileHash = installationId == null
                    ? null
                    : hash(List.of(
                            installationId.toString(),
                            safe(deviceName),
                            safe(manufacturer),
                            safe(model),
                            safe(platform),
                            safe(osVersion),
                            safe(appVersion),
                            safe(appBuild),
                            safe(formFactor),
                            safe(browserName),
                            safe(locale),
                            safe(timeZone),
                            safe(offset),
                            safe(physical)));
            return new AuditDeviceEvidence(
                    clientEventId,
                    installationId,
                    deviceName,
                    manufacturer,
                    model,
                    platform,
                    osVersion,
                    appVersion,
                    appBuild,
                    formFactor,
                    browserName,
                    locale,
                    timeZone,
                    offset,
                    physical,
                    clientEventAt,
                    status,
                    profileHash,
                    true);
        } catch (Exception ignored) {
            // Never log the malformed header: it may be attacker-controlled.
            return empty(clientEventId, "invalid");
        }
    }

    private AuditDeviceEvidence empty(UUID clientEventId, String status) {
        return new AuditDeviceEvidence(
                clientEventId,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                status,
                null,
                !"missing".equals(status));
    }

    private String text(JsonNode root, String field, int maxLength) {
        JsonNode value = root.get(field);
        if (value == null || !value.isTextual()) {
            return null;
        }
        String cleaned = value.textValue()
                .replaceAll("[\\u0000-\\u001F\\u007F]", " ")
                .replaceAll("\\s+", " ")
                .trim();
        if (cleaned.isBlank()) {
            return null;
        }
        return cleaned.length() <= maxLength
                ? cleaned
                : cleaned.substring(0, maxLength);
    }

    private String enumText(
            JsonNode root,
            String field,
            int maxLength,
            Set<String> allowed) {
        String value = text(root, field, maxLength);
        return value != null && allowed.contains(value) ? value : null;
    }

    private Integer boundedInt(JsonNode value, int minimum, int maximum) {
        if (value == null || !value.canConvertToInt()) {
            return null;
        }
        int parsed = value.intValue();
        return parsed >= minimum && parsed <= maximum ? parsed : null;
    }

    private UUID uuid(String value) {
        if (value == null || value.length() != 36) {
            return null;
        }
        try {
            UUID parsed = UUID.fromString(value);
            return parsed.toString().equalsIgnoreCase(value) ? parsed : null;
        } catch (IllegalArgumentException ignored) {
            return null;
        }
    }

    private OffsetDateTime offsetDateTime(String value) {
        if (value == null) {
            return null;
        }
        try {
            OffsetDateTime parsed = OffsetDateTime.parse(value)
                    .withOffsetSameInstant(ZoneOffset.UTC);
            Instant now = clock.instant();
            Instant instant = parsed.toInstant();
            if (instant.isBefore(now.minus(MAX_PAST_CLOCK_SKEW))
                    || instant.isAfter(now.plus(MAX_FUTURE_CLOCK_SKEW))) {
                return null;
            }
            return parsed;
        } catch (RuntimeException ignored) {
            return null;
        }
    }

    private String hash(List<String> values) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        for (String value : values) {
            digest.update(value.getBytes(StandardCharsets.UTF_8));
            digest.update((byte) 0x1F);
        }
        return HexFormat.of().formatHex(digest.digest());
    }

    private String safe(Object value) {
        return value == null ? "" : value.toString();
    }
}
