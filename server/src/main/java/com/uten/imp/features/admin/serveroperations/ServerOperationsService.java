package com.uten.imp.features.admin.serveroperations;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.audit.AuditService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import java.time.OffsetDateTime;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;

/** Root owns configuration/jobs; this service owns HTTP capabilities and typed safe projections. */
@Service
@RequiredArgsConstructor
@Slf4j
public class ServerOperationsService {
    private final HostOperationsClient client;
    private final SecurityContextCurrentUser currentUser;
    private final ObjectMapper mapper;
    private final AuditService audit;
    private final ServerOperationsRuntimeBinding runtimeBinding;

    @PreAuthorize(ServerOperationsPermissions.READ_EXPRESSION)
    public ServerOperationsDto.Status status() {
        AuthUser actor = actor();
        return snapshot(actor.getId(), can(actor, ServerOperationsPermissions.UPDATE),
                can(actor, ServerOperationsPermissions.CLEANUP), canConfigure(actor));
    }

    /** Internal local-file status only. This never checks OSS or starts a worker. */
    public ServerOperationsDto.Status localSnapshot() {
        return snapshot(new UUID(0, 0), false, false, false);
    }

    private ServerOperationsDto.Status snapshot(UUID actor, boolean update, boolean cleanup, boolean configure) {
        try {
            JsonNode data = client.call(HostOperationsClient.Operation.STATUS, Map.of(), actor, UUID.randomUUID());
            if (!data.path("available").isBoolean() || !data.path("manualOnly").isBoolean()
                    || !data.path("timerActive").isBoolean() || !data.path("timerEnabled").isBoolean()) {
                throw new HostOperationsException("INVALID_RESPONSE");
            }
            var failure = data.path("available").booleanValue() ? null : ServerOperationFailures.unavailable(
                    data.path("failure").path("code").asText());
            return new ServerOperationsDto.Status(data.path("available").booleanValue(),
                    data.path("manualOnly").booleanValue(), data.path("timerActive").booleanValue(),
                    data.path("timerEnabled").booleanValue(), text(data, "currentVersion", 32),
                    text(data, "sourceRevision", 128), bool(data, "sourceConfigured"), job(data.get("latestJob")),
                    text(data, "latestVersion", 32), instant(data, "lastCheckedAt"), bool(data, "updateAvailable"),
                    text(data, "serverTimeZone", 128), instant(data, "serverTime"),
                    failure == null ? null : ServerOperationFailures.message(failure), update, cleanup, configure, failure);
        } catch (HostOperationsException unavailable) {
            var failure = unavailable.availabilityFailure();
            return new ServerOperationsDto.Status(false, null, null, null, null, null, null, null,
                    null, null, null, null, null,
                    ServerOperationFailures.message(failure), update, cleanup, configure, failure);
        }
    }

    @PreAuthorize(ServerOperationsPermissions.SOURCE_EXPRESSION)
    public ServerOperationsDto.SourceView source() {
        return sourceView(call(HostOperationsClient.Operation.CONFIG_READ, Map.of(), UUID.randomUUID()), false);
    }

    @PreAuthorize(ServerOperationsPermissions.SOURCE_EXPRESSION)
    public ServerOperationsDto.SourceView saveSource(ServerOperationsDto.SourceSave request) {
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("expectedRevision", request.expectedRevision());
        payload.put("endpoint", request.endpoint());
        payload.put("bucket", request.bucket());
        payload.put("objectPrefix", request.objectPrefix());
        if (request.accessKeyId() != null) payload.put("accessKeyId", request.accessKeyId());
        if (request.accessKeySecret() != null) payload.put("accessKeySecret", request.accessKeySecret());
        payload.put("clearCredentials", request.clearCredentials());
        if (request.signingPublicKey() != null) payload.put("signingPublicKey", request.signingPublicKey());
        var result = sourceView(call(HostOperationsClient.Operation.CONFIG_SAVE, payload, request.requestId()), true);
        record("server_source_save", request.requestId());
        return result;
    }

    @PreAuthorize(ServerOperationsPermissions.UPDATE_EXPRESSION)
    public ServerOperationsDto.Job check(ServerOperationsDto.Check request) {
        return startJob("CHECK_ONLY", request.requestId(), request.expectedSourceRevision(),
                request.expectedCurrentVersion(), null, null);
    }

    @PreAuthorize(ServerOperationsPermissions.UPDATE_EXPRESSION)
    public ServerOperationsDto.Job start(ServerOperationsDto.UpdateStart request) {
        if (request.mode() == null || !Set.of("CHECK_AND_UPDATE", "SCHEDULE_UPDATE").contains(request.mode())
                || ("SCHEDULE_UPDATE".equals(request.mode())
                    && (request.scheduledAt() == null || request.targetVersion() == null || request.targetVersion().isBlank()))
                || (!"SCHEDULE_UPDATE".equals(request.mode()) && request.scheduledAt() != null)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择立即更新或有效的预约时间与版本");
        }
        return startJob(request.mode(), request.requestId(), request.expectedSourceRevision(),
                request.expectedCurrentVersion(), request.targetVersion(), request.scheduledAt());
    }

    private ServerOperationsDto.Job startJob(String mode, UUID requestId, String revision, String version,
            String targetVersion, OffsetDateTime scheduledAt) {
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("mode", mode);
        payload.put("expectedSourceRevision", revision);
        payload.put("expectedCurrentVersion", version);
        if (!"CHECK_ONLY".equals(mode)) payload.put("runtimeBinding", runtimeBinding.capture());
        if (targetVersion != null) payload.put("targetVersion", targetVersion);
        if (scheduledAt != null) payload.put("scheduledAt", scheduledAt.toInstant().toString());
        ServerOperationsDto.Job result = projectJob(call(HostOperationsClient.Operation.UPDATE_START, payload, requestId), true);
        if (result == null || !requestId.equals(result.id()) || !requestId.equals(result.requestId()) || !actor().getId().equals(result.actorId())
                || !mode.equals(result.mode())) throw new HostOperationsException("INVALID_RESPONSE", true).toApiException();
        record("CHECK_ONLY".equals(mode) ? "server_update_check" : "server_update_start", requestId);
        return result;
    }

    @PreAuthorize(ServerOperationsPermissions.UPDATE_EXPRESSION)
    public ServerOperationsDto.ScheduleSlot schedulePreview(ServerOperationsDto.SchedulePreview request) {
        if (request.hour() == null || (request.hour() != 2 && request.hour() != 3)) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择服务器当地凌晨 2 点或 3 点");
        }
        JsonNode data = call(HostOperationsClient.Operation.SCHEDULE_PREVIEW,
                Map.of("localDate", request.localDate().toString(), "hour", request.hour()), UUID.randomUUID());
        try {
            OffsetDateTime instant = instant(data, "scheduledAt");
            String zone = text(data, "serverTimeZone", 128);
            String label = text(data, "displayLocalTime", 128);
            if (instant == null || zone == null || label == null) throw new HostOperationsException("INVALID_RESPONSE");
            return new ServerOperationsDto.ScheduleSlot(instant, zone, label);
        } catch (HostOperationsException safe) { throw safe.toApiException(); }
    }

    @PreAuthorize(ServerOperationsPermissions.UPDATE_EXPRESSION)
    public ServerOperationsDto.Job cancel(UUID id, ServerOperationsDto.Cancel request) {
        ServerOperationsDto.Job existing = byId(id);
        if (!actor().isSuperAdmin() && !actor().getId().equals(existing.actorId())) {
            throw new ApiException(ErrorCode.FORBIDDEN, "仅预约人或超级管理员可以取消预约");
        }
        ServerOperationsDto.Job result = projectJob(call(HostOperationsClient.Operation.UPDATE_CANCEL,
                Map.of("jobId", id.toString(), "reason", "USER_REQUEST"), request.requestId()), true);
        if (result == null || !id.equals(result.id()) || !"CANCELLED".equals(result.state())) {
            throw new HostOperationsException("INVALID_RESPONSE", true).toApiException();
        }
        record("server_update_cancel", request.requestId());
        return result;
    }

    @PreAuthorize(ServerOperationsPermissions.READ_EXPRESSION)
    public ServerOperationsDto.LatestJob latest() {
        return new ServerOperationsDto.LatestJob(projectJob(call(HostOperationsClient.Operation.UPDATE_JOB, Map.of(), UUID.randomUUID()), false));
    }

    @PreAuthorize(ServerOperationsPermissions.READ_EXPRESSION)
    public ServerOperationsDto.Job byId(UUID id) {
        ServerOperationsDto.Job result = projectJob(call(HostOperationsClient.Operation.UPDATE_JOB,
                Map.of("jobId", id.toString()), UUID.randomUUID()), false);
        if (result == null) throw new ApiException(ErrorCode.NOT_FOUND);
        if (!id.equals(result.id())) throw new HostOperationsException("INVALID_RESPONSE").toApiException();
        return result;
    }

    private JsonNode call(HostOperationsClient.Operation operation, Map<String, Object> payload, UUID requestId) {
        try { return client.call(operation, payload, actor().getId(), requestId); }
        catch (HostOperationsException safe) { throw safe.toApiException(); }
    }

    private ServerOperationsDto.SourceView sourceView(JsonNode data, boolean uncertainOnInvalid) {
        try {
            String revision = text(data, "revision", 128);
            if (revision == null || !data.path("accessKeyConfigured").isBoolean()) throw new HostOperationsException("INVALID_RESPONSE");
            return new ServerOperationsDto.SourceView(revision, text(data, "endpoint", 128),
                    text(data, "bucket", 63), text(data, "objectPrefix", 256),
                    data.path("accessKeyConfigured").booleanValue(), text(data, "accessKeyIdHint", 64),
                    text(data, "signingPublicKey", 1024), text(data, "signingKeyFingerprint", 128),
                    text(data, "sourceUrl", 512), true);
        } catch (HostOperationsException invalid) { throw new HostOperationsException("INVALID_RESPONSE", uncertainOnInvalid).toApiException(); }
    }

    private ServerOperationsDto.Job projectJob(JsonNode data, boolean uncertainOnInvalid) {
        try { return job(data); }
        catch (HostOperationsException invalid) { throw new HostOperationsException("INVALID_RESPONSE", uncertainOnInvalid).toApiException(); }
    }

    private ServerOperationsDto.Job job(JsonNode data) {
        if (data == null || data.isNull()) return null;
        try {
            if (!data.isObject()) throw new HostOperationsException("INVALID_RESPONSE");
            JsonNode rawFailure = data.get("failure");
            var safe = ((com.fasterxml.jackson.databind.node.ObjectNode) data).deepCopy();
            safe.remove("failure");
            // A structured failure replaces legacy free text, even if the helper
            // sends malformed/oversized text. Only our curated catalog is public.
            if (rawFailure != null && !rawFailure.isNull()) safe.remove("message");
            ServerOperationsDto.Job result = mapper.treeToValue(safe, ServerOperationsDto.Job.class);
            if (result.id() == null || result.requestId() == null || result.actorId() == null
                    || !Set.of("CHECK_ONLY", "CHECK_AND_UPDATE", "SCHEDULE_UPDATE").contains(result.mode())
                    || !Set.of("SCHEDULED", "QUEUED", "RUNNING", "SUCCEEDED", "FAILED", "RECOVERY_REQUIRED", "CANCELLED").contains(result.state())
                    || !Set.of("CHECKING", "DOWNLOADING", "BACKING_UP", "MIGRATING", "ACTIVATING", "HEALTH_CHECK", "DONE").contains(result.phase())
                    || ("SCHEDULED".equals(result.state()) && result.scheduledAt() == null)
                    || (result.message() != null && result.message().length() > 1000)) throw new HostOperationsException("INVALID_RESPONSE");
            var failure = ServerOperationFailures.project(rawFailure, result.state(), result.phase());
            if (failure == null) return result;
            return new ServerOperationsDto.Job(result.id(), result.requestId(), result.actorId(), result.mode(),
                    failure.recoveryRequired() ? "RECOVERY_REQUIRED" : result.state(), result.phase(),
                    result.startedAt(), result.finishedAt(), result.currentVersion(), result.targetVersion(),
                    ServerOperationFailures.message(failure), result.backupPath(), result.migrationRequired(), result.health(),
                    result.scheduledAt(), result.displayLocalTime(), failure);
        } catch (JsonProcessingException | IllegalArgumentException | NullPointerException invalid) {
            throw new HostOperationsException("INVALID_RESPONSE");
        }
    }

    private static OffsetDateTime instant(JsonNode node, String key) {
        String value = text(node, key, 80);
        try { return value == null ? null : OffsetDateTime.parse(value); }
        catch (RuntimeException invalid) { throw new HostOperationsException("INVALID_RESPONSE"); }
    }

    private static String text(JsonNode node, String key, int limit) {
        JsonNode value = node.get(key);
        if (value == null || value.isNull()) return null;
        if (!value.isTextual() || value.textValue().length() > limit) throw new HostOperationsException("INVALID_RESPONSE");
        return value.textValue();
    }

    private static Boolean bool(JsonNode node, String key) {
        JsonNode value = node.get(key);
        if (value == null || value.isNull()) return null;
        if (!value.isBoolean()) throw new HostOperationsException("INVALID_RESPONSE");
        return value.booleanValue();
    }

    private AuthUser actor() { return currentUser.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED)); }
    private void record(String action, UUID requestId) {
        try {
            AuthUser actor = actor();
            // Only operation identity is audited. Never pass a request/DTO/source value to the audit sink.
            audit.logExplicit(actor.getId(), actor.getLoginAccount(), action, "server_operations", requestId.toString(), "success");
        } catch (RuntimeException unavailable) {
            // Host receipts remain authoritative; the existing request interceptor retries semantic metadata.
            log.warn("服务器运维审计元数据暂未保存: {}", unavailable.getClass().getSimpleName());
        }
    }
    private static boolean can(AuthUser actor, String permission) {
        return !actor.isVisitor() && !actor.isMustChangePassword() && actor.getImpersonatedBy() == null
                && (actor.isSuperAdmin() || actor.getPermissions().contains(permission));
    }
    private static boolean canConfigure(AuthUser actor) { return can(actor, "authorization:manage") && actor.isSuperAdmin(); }
}
