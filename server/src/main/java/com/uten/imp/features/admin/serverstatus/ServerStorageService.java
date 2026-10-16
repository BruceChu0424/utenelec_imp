package com.uten.imp.features.admin.serverstatus;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.admin.serveroperations.HostOperationsClient;
import com.uten.imp.features.admin.serveroperations.HostOperationsException;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.audit.AuditService;
import org.springframework.stereotype.Service;
import javax.sql.DataSource;
import java.lang.management.ManagementFactory;
import java.sql.Connection;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import static com.uten.imp.features.admin.serverstatus.ServerStorageView.*;
import static com.uten.imp.features.admin.serveroperations.HostOperationsClient.Operation.*;

@Service
public class ServerStorageService {
    private final HostOperationsClient host;
    private final SecurityContextCurrentUser currentUser;
    private final ObjectMapper mapper;
    private final DataSource dataSource;
    private final AuditService audit;
    private final Map<UUID,String> auditedResults = new java.util.LinkedHashMap<>();
    private volatile BusinessFootprint footprint;

    public ServerStorageService(HostOperationsClient host, SecurityContextCurrentUser currentUser,
                                ObjectMapper mapper, DataSource dataSource, AuditService audit) {
        this.host = host; this.currentUser = currentUser; this.dataSource = dataSource;
        this.audit = audit;
        this.mapper = mapper.copy().disable(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES);
    }

    public Summary summary() {
        AuthUser user = require(false);
        Summary raw;
        try { raw = read(STORAGE_SUMMARY, Map.of(), user.getId(), Summary.class, null); }
        catch (ApiException unavailable) {
            // Host inventory is optional in Windows development; database/self metrics
            // stay useful and unknown host numbers are never replaced with zero.
            raw = new Summary(Instant.now(), "UNKNOWN", null,
                    new Capabilities(false, false, "当前环境未提供受控主机存储助手。"),
                    List.of(), List.of(), null, null, null);
        }
        var heap = ManagementFactory.getMemoryMXBean().getHeapMemoryUsage();
        Long resident = ProcessMemoryProbe.residentBytes();
        var process = new ProcessMemory(resident, heap.getUsed(), heap.getMax(), resident == null
                ? "当前环境不提供进程常驻内存；Java 堆内存单独显示。"
                : "当前后端进程实际常驻内存，包含 Java 堆、线程和本地内存；不包含独立子进程。" );
        BusinessFootprint business = footprint();
        Capabilities capability = raw.capabilities() == null ? new Capabilities(false, false, "主机助手尚未提供存储能力。")
                : new Capabilities(raw.capabilities().available(), raw.capabilities().canCleanup() && canCleanup(user),
                raw.capabilities().unavailableReason());
        return new Summary(raw.sampledAt(), raw.status(), raw.revision(), capability,
                raw.volumes() == null ? List.of() : raw.volumes(), raw.categories() == null ? List.of() : raw.categories(),
                process, business.database(), business.uploads());
    }

    public Resources resources(Kind kind, String cursor, int limit) {
        AuthUser user = require(false);
        if (kind == null || limit < 1 || limit > 100 || cursor != null && cursor.length() > 80)
            throw new ApiException(ErrorCode.VALIDATION_FAILED);
        return read(STORAGE_LIST, cursor == null ? Map.of("kind", kind.name(), "limit", limit)
                : Map.of("kind", kind.name(), "cursor", cursor, "limit", limit), user.getId(), Resources.class, null);
    }

    public Preview preview(PreviewRequest request) {
        AuthUser user = require(true);
        if (request == null || request.resourceIds() == null || request.resourceIds().isEmpty()
                || request.resourceIds().size() > 50 || request.resourceIds().stream().anyMatch(v -> v == null || !v.matches("[a-f0-9]{64}"))
                || request.resourceIds().stream().distinct().count() != request.resourceIds().size())
            throw new ApiException(ErrorCode.VALIDATION_FAILED);
        return read(STORAGE_PREVIEW_DELETE, Map.of("resourceIds", request.resourceIds()), user.getId(), Preview.class, null);
    }

    public Result delete(DeleteRequest request) {
        AuthUser user = require(true);
        if (request == null || request.previewId() == null || request.requestId() == null)
            throw new ApiException(ErrorCode.VALIDATION_FAILED);
        Result result = read(STORAGE_DELETE, Map.of("previewId", request.previewId().toString(), "requestId", request.requestId().toString()),
                user.getId(), Result.class, request.requestId());
        auditResult(user, result);
        return result;
    }

    public Result result(UUID requestId) {
        AuthUser user = require(true);
        if (requestId == null) throw new ApiException(ErrorCode.VALIDATION_FAILED);
        Result result = read(STORAGE_RESULT, Map.of("requestId", requestId.toString()), user.getId(), Result.class, requestId);
        auditResult(user, result);
        return result;
    }

    private void auditResult(AuthUser actor, Result result) {
        if ("RUNNING".equals(result.status())) return;
        synchronized (auditedResults) {
            if (result.status().equals(auditedResults.get(result.requestId()))) return;
            auditedResults.put(result.requestId(), result.status());
            if (auditedResults.size() > 1024) auditedResults.remove(auditedResults.keySet().iterator().next());
        }
        try {
            // Root durable receipt is authoritative. Only a request UUID and state
            // enter application audit, never filenames, helper DTOs or credentials.
            audit.logExplicit(actor.getId(), actor.getLoginAccount(), "server_cleanup", "server_operations",
                    result.requestId().toString(), result.status());
        } catch (RuntimeException unavailable) {
            synchronized (auditedResults) { auditedResults.remove(result.requestId()); }
            org.slf4j.LoggerFactory.getLogger(ServerStorageService.class)
                    .warn("Server cleanup audit unavailable ({})", unavailable.getClass().getSimpleName());
        }
    }

    private <T> T read(HostOperationsClient.Operation operation, Map<String,Object> payload, UUID actor, Class<T> type, UUID requestId) {
        try {
            JsonNode response = host.call(operation, payload, actor, requestId == null ? UUID.randomUUID() : requestId);
            validateResponse(response, operation, requestId);
            return mapper.treeToValue(response, type);
        } catch (HostOperationsException safe) { throw safe.toApiException(); }
        catch (JsonProcessingException | IllegalArgumentException malformed) {
            throw new ApiException(ErrorCode.SERVER_OPERATIONS_UNAVAILABLE, "主机存储信息不完整，请联系服务器管理员。");
        }
    }

    private static void validateResponse(JsonNode response, HostOperationsClient.Operation operation, UUID requestId) {
        boolean valid = response != null && response.isObject();
        if (valid) {
            valid = switch (operation) {
                case STORAGE_SUMMARY -> response.path("capabilities").isObject()
                        && response.path("capabilities").path("available").isBoolean()
                        && response.path("capabilities").path("canCleanup").isBoolean()
                        && response.path("volumes").isArray() && response.path("categories").isArray()
                        && response.path("sampledAt").isTextual() && response.path("status").isTextual();
                case STORAGE_LIST -> response.path("sampledAt").isTextual() && response.path("revision").isTextual()
                        && response.path("kind").isTextual() && response.path("items").isArray()
                        && response.path("total").canConvertToLong() && response.path("total").longValue() >= 0;
                case STORAGE_PREVIEW_DELETE -> response.path("previewId").isTextual() && response.path("expiresAt").isTextual()
                        && response.path("resources").isArray() && !response.path("resources").isEmpty()
                        && response.path("warnings").isArray() && response.path("revision").isTextual();
                case STORAGE_DELETE, STORAGE_RESULT -> requestId != null && requestId.toString().equals(response.path("requestId").asText())
                        && List.of("SUCCEEDED", "PARTIAL", "FAILED", "RUNNING", "RECOVERY_REQUIRED").contains(response.path("status").asText())
                        && response.path("deletedCount").canConvertToInt() && response.path("deletedCount").intValue() >= 0
                        && response.path("reclaimedBytes").canConvertToLong() && response.path("reclaimedBytes").longValue() >= 0;
                default -> false;
            };
        }
        if (!valid) throw new HostOperationsException("INVALID_RESPONSE", operation.outcomeMayChangeState());
    }

    private AuthUser require(boolean write) {
        AuthUser user = currentUser.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (user.isVisitor() || user.isMustChangePassword() || write && user.getImpersonatedBy() != null
                || !(user.isSuperAdmin() || (write ? canCleanup(user) : user.getPermissions().stream()
                .anyMatch(p -> List.of("server_status:view", "server:update", "server:cleanup").contains(p)))))
            throw new ApiException(ErrorCode.FORBIDDEN);
        return user;
    }

    private boolean canCleanup(AuthUser user) {
        return !user.isVisitor() && !user.isMustChangePassword() && user.getImpersonatedBy() == null
                && (user.isSuperAdmin() || user.getPermissions().contains("server:cleanup"));
    }

    private synchronized BusinessFootprint footprint() {
        Instant now = Instant.now();
        if (footprint != null && Duration.between(footprint.at(), now).getSeconds() < 60) return footprint;
        Database database = new Database(null, "UNKNOWN");
        Uploads uploads = new Uploads(null, null, null, "UNKNOWN", "暂未读取到附件登记量。" );
        try (Connection connection = dataSource.getConnection()) {
            try (var query = connection.prepareStatement("SELECT pg_database_size(current_database())")) {
                query.setQueryTimeout(2);
                try (var rows = query.executeQuery()) {
                    if (rows.next()) database = new Database(rows.getLong(1), "NORMAL");
                }
            }
            try (var query = connection.prepareStatement("SELECT count(*), COALESCE(SUM(size_bytes),0), COALESCE(SUM(COALESCE(stored_size_bytes,size_bytes)),0) FROM attachments")) {
                query.setQueryTimeout(2);
                try (var rows = query.executeQuery()) {
                    if (rows.next()) uploads = new Uploads(rows.getLong(1), rows.getLong(2), rows.getLong(3), "NORMAL",
                            "全部附件登记，包含保留历史；不等于去重后的磁盘实占，也不含独立私有文档和临时文件。" );
                }
            }
        } catch (Exception unavailable) { /* safe UNKNOWN, no SQL or credentials in response */ }
        footprint = new BusinessFootprint(now, database, uploads);
        return footprint;
    }
    private record BusinessFootprint(Instant at, Database database, Uploads uploads) {}
}
