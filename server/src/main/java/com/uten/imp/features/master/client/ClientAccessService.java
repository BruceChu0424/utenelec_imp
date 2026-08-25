package com.uten.imp.features.master.client;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.validation.RequestLimits;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.master.client.dto.ClientAccessCandidate;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.client.dto.ClientAccessDetail;
import com.uten.imp.features.master.client.dto.ClientAccessUpdateRequest;
import com.uten.imp.features.master.client.dto.ClientAccessViewer;
import com.uten.imp.common.identity.CurrentEmployeeStatusPolicy;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.Collection;
import java.util.Comparator;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/** Atomic customer owner and explicit read-only viewer maintenance. */
@Service
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('client:assign')")
public class ClientAccessService {

    private final EntityManager em;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;
    private final ClientAccessPolicy accessPolicy;

    /**
     * Customer-assignment-specific employee picker. It intentionally exposes no
     * HR profile/PII and does not require employee:view.
     */
    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public PageResponse<ClientAccessCandidate> candidates(
            String search, int page, int size) {
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, size), 100);
        long offset = (long) (safePage - 1) * safeSize;
        String normalizedSearch = search == null ? "" : search.trim();
        if (normalizedSearch.length() > 100) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED, "候选员工搜索关键词最长100个字符");
        }
        String keyword = normalizedSearch.toLowerCase(Locale.ROOT);
        String pattern = "%" + keyword
                .replace("\\", "\\\\")
                .replace("%", "\\%")
                .replace("_", "\\_") + "%";
        String fromWhere = """
                FROM employees employee
                LEFT JOIN departments department ON department.id = employee.department_id
                WHERE employee.is_deleted = FALSE
                  AND employee.status IN ('active','probation','onLeave')
                  AND EXISTS (
                      SELECT 1 FROM users account
                      WHERE account.employee_id = employee.id
                        AND account.is_deleted = FALSE
                        AND account.status = 'active')
                  AND (:keyword = ''
                       OR lower(employee.full_name) LIKE :pattern ESCAPE '\\'
                       OR lower(employee.code) LIKE :pattern ESCAPE '\\'
                       OR lower(COALESCE(department.name,'')) LIKE :pattern ESCAPE '\\')
                """;
        Number totalValue = (Number) em.createNativeQuery("SELECT count(*) " + fromWhere)
                .setParameter("keyword", keyword)
                .setParameter("pattern", pattern)
                .getSingleResult();
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT employee.id, employee.full_name, employee.code,
                               department.name, employee.status, TRUE
                        """ + fromWhere + """
                        ORDER BY employee.full_name, employee.code, employee.id
                        LIMIT :limit OFFSET :offset
                        """)
                .setParameter("keyword", keyword)
                .setParameter("pattern", pattern)
                .setParameter("limit", safeSize)
                .setParameter("offset", offset));
        List<ClientAccessCandidate> items = rows.stream()
                .map(row -> new ClientAccessCandidate(
                        (UUID) row[0], Objects.toString(row[1], ""),
                        Objects.toString(row[2], ""),
                        row[3] == null ? null : row[3].toString(),
                        Objects.toString(row[4], ""), Boolean.TRUE.equals(row[5])))
                .toList();
        long total = totalValue.longValue();
        int totalPages = (int) ((total + safeSize - 1) / safeSize);
        return new PageResponse<>(items, safePage, safeSize, total, totalPages);
    }

    @Transactional(readOnly = true, isolation = Isolation.REPEATABLE_READ)
    public ClientAccessDetail get(UUID clientId) {
        Client client = requireClient(clientId);
        requireAccessAdministration(client);
        return toDetail(client);
    }

    @Transactional
    public ClientAccessDetail update(UUID clientId, ClientAccessUpdateRequest request) {
        tx.bind();
        ValidatedRequest validated = validateRequest(request);
        Client snapshot = requireClient(clientId);
        requireAccessAdministration(snapshot);
        if (snapshot.getAccessVersion() != validated.expectedAccessVersion()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "客户归属或可见人已被其他人修改，请刷新后重试");
        }

        Set<UUID> requestedEmployees = new LinkedHashSet<>(validated.viewerEmployeeIds());
        requestedEmployees.add(validated.ownerEmployeeId());
        Set<UUID> lockedEmployees = new LinkedHashSet<>(requestedEmployees);
        if (snapshot.getOwnerEmployeeId() != null) {
            lockedEmployees.add(snapshot.getOwnerEmployeeId());
        }
        Map<UUID, EmployeeReference> employees = employeeReferences(lockedEmployees);

        // Global order: employees(sorted) -> customer -> users(sorted) -> grants.
        Client client = requireClientForUpdate(clientId);
        requireAccessAdministration(client);
        if (!Objects.equals(snapshot.getOwnerEmployeeId(), client.getOwnerEmployeeId())
                || client.getAccessVersion() != validated.expectedAccessVersion()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "客户归属或可见人已被其他人修改，请刷新后重试");
        }
        Set<UUID> activeAccountEmployees = activeAccountEmployeeIds(lockedEmployees);
        EmployeeReference owner = requireCurrentEmployee(
                validated.ownerEmployeeId(), employees.get(validated.ownerEmployeeId()),
                activeAccountEmployees, "客户负责人");
        for (UUID viewerId : validated.viewerEmployeeIds()) {
            requireCurrentEmployee(
                    viewerId, employees.get(viewerId), activeAccountEmployees, "客户可见人");
        }
        UUID previousOwnerId = client.getOwnerEmployeeId();
        EmployeeReference previousOwner = employees.get(previousOwnerId);
        boolean retainPreviousOwner = previousOwner != null
                && !previousOwner.deleted()
                && CurrentEmployeeStatusPolicy.isCurrentEmployee(previousOwner.status())
                && activeAccountEmployees.contains(previousOwnerId);
        List<UUID> effectiveViewerIds = effectiveViewerIds(
                previousOwnerId, validated.ownerEmployeeId(),
                validated.viewerEmployeeIds(), retainPreviousOwner);

        UUID actorUserId = currentUser.requireId();
        List<UUID> previousViewerIds = activeViewerIds(clientId);

        replaceViewers(clientId, effectiveViewerIds, actorUserId);
        client.setOwnerEmployeeId(owner.id());
        client.setEmpId(owner.legacyId() == null ? null : owner.legacyId().toString());
        client.setAccessVersion(client.getAccessVersion() + 1);
        em.flush();

        insertAccessEvent(
                clientId,
                previousOwnerId,
                owner.id(),
                previousViewerIds,
                effectiveViewerIds,
                client.getAccessVersion(),
                validated.reason(),
                actorUserId);
        return toDetail(client);
    }

    private ValidatedRequest validateRequest(ClientAccessUpdateRequest request) {
        if (request == null || request.ownerEmployeeId() == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "客户负责人必填");
        }
        if (request.expectedAccessVersion() == null || request.expectedAccessVersion() < 0) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "客户权限版本不正确");
        }
        String reason = request.reason() == null ? "" : request.reason().trim();
        if (reason.isEmpty() || reason.length() > 1000) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "变更原因须为 1–1000 个字符");
        }
        List<UUID> rawViewers = request.viewerEmployeeIds() == null
                ? List.of()
                : request.viewerEmployeeIds();
        if (rawViewers.size() > RequestLimits.ADMIN_SCOPE_OWNERS) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "客户可见人数量超过上限");
        }
        LinkedHashSet<UUID> normalized = new LinkedHashSet<>();
        for (UUID viewerId : rawViewers) {
            if (viewerId == null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "客户可见人不能为空");
            }
            if (!viewerId.equals(request.ownerEmployeeId())) normalized.add(viewerId);
        }
        List<UUID> sorted = normalized.stream().sorted().toList();
        return new ValidatedRequest(
                request.ownerEmployeeId(),
                sorted,
                request.expectedAccessVersion(),
                reason);
    }

    /**
     * Changing only the customer owner must not strand sales drafts still owned
     * by the previous salesperson. A current previous owner with an active
     * account is retained as an explicit read-only customer viewer; the response
     * and append-only event expose the effective result.
     */
    static List<UUID> effectiveViewerIds(
            UUID previousOwnerId,
            UUID newOwnerId,
            List<UUID> requestedViewerIds,
            boolean retainPreviousOwner) {
        LinkedHashSet<UUID> effective = new LinkedHashSet<>(requestedViewerIds);
        if (retainPreviousOwner
                && previousOwnerId != null
                && !previousOwnerId.equals(newOwnerId)) {
            effective.add(previousOwnerId);
        }
        if (effective.size() > RequestLimits.ADMIN_SCOPE_OWNERS) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED,
                    "变更负责人需保留前负责人查看在途单据，请先减少一名其他可见人");
        }
        return effective.stream().sorted().toList();
    }

    private Client requireClient(UUID clientId) {
        Client client = clientId == null ? null : em.find(Client.class, clientId);
        if (client == null || client.isDeleted()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "客户不存在");
        }
        return client;
    }

    private Client requireClientForUpdate(UUID clientId) {
        Client client = clientId == null ? null : em.find(Client.class, clientId);
        if (client == null || client.isDeleted()) {
            throw new ApiException(ErrorCode.NOT_FOUND, "客户不存在");
        }
        // The no-lock snapshot is already managed; refresh is required so the
        // post-lock CAS/owner recheck observes commits made while we waited.
        em.refresh(client, LockModeType.PESSIMISTIC_WRITE);
        if (client.isDeleted()) throw new ApiException(ErrorCode.NOT_FOUND, "客户不存在");
        return client;
    }

    private void requireAccessAdministration(Client client) {
        ClientAccessPolicy.ClientScope scope = accessPolicy.evaluate();
        if (!accessPolicy.canManageAccess(client, scope)) {
            throw new ApiException(ErrorCode.NOT_FOUND, "客户不存在");
        }
    }

    private Map<UUID, EmployeeReference> employeeReferences(Collection<UUID> employeeIds) {
        if (employeeIds == null || employeeIds.isEmpty()) return Map.of();
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT employee.id,
                               employee.full_name,
                               employee.code,
                               department.name,
                               employee.status,
                               employee.is_deleted,
                               employee.legacy_id
                        FROM employees employee
                        LEFT JOIN departments department ON department.id = employee.department_id
                        WHERE employee.id IN (:employeeIds)
                        ORDER BY employee.id
                        FOR SHARE OF employee
                        """)
                .setParameter("employeeIds", employeeIds));
        Map<UUID, EmployeeReference> references = new HashMap<>();
        for (Object[] row : rows) {
            EmployeeReference reference = new EmployeeReference(
                    (UUID) row[0],
                    Objects.toString(row[1], ""),
                    Objects.toString(row[2], ""),
                    row[3] == null ? null : row[3].toString(),
                    row[4] == null ? null : row[4].toString(),
                    Boolean.TRUE.equals(row[5]),
                    row[6] == null ? null : ((Number) row[6]).intValue());
            references.put(reference.id(), reference);
        }
        return references;
    }

    private Set<UUID> activeAccountEmployeeIds(Collection<UUID> employeeIds) {
        if (employeeIds == null || employeeIds.isEmpty()) return Set.of();
        return new LinkedHashSet<>(NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT account.employee_id
                        FROM users account
                        WHERE account.employee_id IN (:employeeIds)
                          AND account.is_deleted = FALSE
                          AND account.status = 'active'
                        ORDER BY account.employee_id, account.id
                        FOR SHARE OF account
                        """)
                .setParameter("employeeIds", employeeIds), UUID.class));
    }

    private static EmployeeReference requireCurrentEmployee(
            UUID id,
            EmployeeReference employee,
            Set<UUID> activeAccountEmployeeIds,
            String label) {
        if (employee == null || employee.deleted()) {
            throw new ApiException(ErrorCode.NOT_FOUND, label + "不存在");
        }
        if (!CurrentEmployeeStatusPolicy.isCurrentEmployee(employee.status())) {
            throw new ApiException(ErrorCode.CONFLICT, label + "必须是在职、试用或留职员工");
        }
        if (!activeAccountEmployeeIds.contains(id)) {
            throw new ApiException(ErrorCode.CONFLICT, label + "必须具有启用的登录账号");
        }
        return employee;
    }

    private List<UUID> activeViewerIds(UUID clientId) {
        return NativeQueryResults.typedRows(em.createNativeQuery("""
                        SELECT grant_row.grantee_employee_id
                        FROM client_visibility_grants grant_row
                        WHERE grant_row.client_id = :clientId
                          AND grant_row.active = TRUE
                        ORDER BY grant_row.grantee_employee_id
                        """)
                .setParameter("clientId", clientId), UUID.class);
    }

    private void replaceViewers(UUID clientId, List<UUID> requestedViewerIds, UUID actorUserId) {
        var revoke = requestedViewerIds.isEmpty()
                ? em.createNativeQuery("""
                        UPDATE client_visibility_grants
                        SET active = FALSE,
                            row_version = row_version + 1,
                            revoked_by_user_id = :actorUserId,
                            revoked_at = now()
                        WHERE client_id = :clientId
                          AND active = TRUE
                        """)
                : em.createNativeQuery("""
                        UPDATE client_visibility_grants
                        SET active = FALSE,
                            row_version = row_version + 1,
                            revoked_by_user_id = :actorUserId,
                            revoked_at = now()
                        WHERE client_id = :clientId
                          AND active = TRUE
                          AND grantee_employee_id NOT IN (:requestedViewerIds)
                        """).setParameter("requestedViewerIds", requestedViewerIds);
        revoke.setParameter("clientId", clientId)
                .setParameter("actorUserId", actorUserId)
                .executeUpdate();

        for (UUID viewerId : requestedViewerIds) {
            em.createNativeQuery("""
                            INSERT INTO client_visibility_grants
                                (client_id, grantee_employee_id, active, row_version,
                                 granted_by_user_id, revoked_by_user_id, revoked_at)
                            VALUES (:clientId, :viewerId, TRUE, 1, :actorUserId, NULL, NULL)
                            ON CONFLICT (client_id, grantee_employee_id) DO UPDATE
                            SET active = TRUE,
                                row_version = client_visibility_grants.row_version + 1,
                                granted_by_user_id = EXCLUDED.granted_by_user_id,
                                revoked_by_user_id = NULL,
                                revoked_at = NULL
                            """)
                    .setParameter("clientId", clientId)
                    .setParameter("viewerId", viewerId)
                    .setParameter("actorUserId", actorUserId)
                    .executeUpdate();
        }
    }

    private void insertAccessEvent(
            UUID clientId,
            UUID previousOwnerId,
            UUID newOwnerId,
            List<UUID> previousViewerIds,
            List<UUID> newViewerIds,
            long resultingAccessVersion,
            String reason,
            UUID actorUserId) {
        em.createNativeQuery("""
                        INSERT INTO client_access_change_events
                            (client_id, previous_owner_employee_id, new_owner_employee_id,
                             previous_viewer_ids, new_viewer_ids, resulting_access_version,
                             reason, actor_user_id)
                        VALUES (:clientId, :previousOwnerId, :newOwnerId,
                                CAST(:previousViewerIds AS UUID[]), CAST(:newViewerIds AS UUID[]),
                                :resultingAccessVersion, :reason, :actorUserId)
                        """)
                .setParameter("clientId", clientId)
                .setParameter("previousOwnerId", previousOwnerId)
                .setParameter("newOwnerId", newOwnerId)
                .setParameter("previousViewerIds", uuidArrayLiteral(previousViewerIds))
                .setParameter("newViewerIds", uuidArrayLiteral(newViewerIds))
                .setParameter("resultingAccessVersion", resultingAccessVersion)
                .setParameter("reason", reason)
                .setParameter("actorUserId", actorUserId)
                .executeUpdate();
    }

    private ClientAccessDetail toDetail(Client client) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT employee.id, employee.full_name, employee.code, department.name
                        FROM client_visibility_grants grant_row
                        JOIN employees employee ON employee.id = grant_row.grantee_employee_id
                        LEFT JOIN departments department ON department.id = employee.department_id
                        WHERE grant_row.client_id = :clientId
                          AND grant_row.active = TRUE
                        ORDER BY employee.full_name, employee.code, employee.id
                        """)
                .setParameter("clientId", client.getId()));
        List<ClientAccessViewer> viewers = new ArrayList<>(rows.size());
        for (Object[] row : rows) {
            viewers.add(new ClientAccessViewer(
                    (UUID) row[0],
                    Objects.toString(row[1], ""),
                    Objects.toString(row[2], ""),
                    row[3] == null ? null : row[3].toString()));
        }
        String ownerName = null;
        if (client.getOwnerEmployeeId() != null) {
            List<?> ownerNames = em.createNativeQuery("""
                            SELECT employee.full_name FROM employees employee
                            WHERE employee.id=:employeeId AND employee.is_deleted=FALSE
                            """)
                    .setParameter("employeeId", client.getOwnerEmployeeId())
                    .getResultList();
            ownerName = ownerNames.isEmpty() ? null : Objects.toString(ownerNames.getFirst(), null);
        }
        return new ClientAccessDetail(
                client.getId(),
                client.getOwnerEmployeeId(),
                ownerName,
                client.getAccessVersion(),
                List.copyOf(viewers));
    }

    private static String uuidArrayLiteral(Collection<UUID> ids) {
        if (ids == null || ids.isEmpty()) return "{}";
        return ids.stream()
                .filter(Objects::nonNull)
                .sorted(Comparator.naturalOrder())
                .map(UUID::toString)
                .collect(Collectors.joining(",", "{", "}"));
    }

    private record ValidatedRequest(
            UUID ownerEmployeeId,
            List<UUID> viewerEmployeeIds,
            long expectedAccessVersion,
            String reason) {
    }

    private record EmployeeReference(
            UUID id,
            String name,
            String code,
            String departmentName,
            String status,
            boolean deleted,
            Integer legacyId) {
    }
}
