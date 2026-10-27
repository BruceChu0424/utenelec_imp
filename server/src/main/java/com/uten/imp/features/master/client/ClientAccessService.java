package com.uten.imp.features.master.client;

import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.util.KeywordSearch;
import com.uten.imp.common.util.TaskKeywordSearch;
import com.uten.imp.common.validation.RequestLimits;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.master.client.dto.ClientAccessCandidate;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.client.dto.ClientAccessBatchUpdateRequest;
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
        String keyword = KeywordSearch.phrase(normalizedSearch);
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
                  AND
                """ + TaskKeywordSearch.conditionParameter("keyword", "employee.full_name", "employee.code", "department.name");
        Number totalValue = (Number) em.createNativeQuery("SELECT count(*) " + fromWhere)
                .setParameter("keyword", keyword)
                .getSingleResult();
        List<Object[]> rows = NativeQueryResults.objectArrayRows(em.createNativeQuery("""
                        SELECT employee.id, employee.full_name, employee.code,
                               department.name, employee.status, TRUE, employee.department_id
                        """ + fromWhere + " ORDER BY "
                        + TaskKeywordSearch.rankNamesFirstParameter("keyword", new String[]{"employee.full_name"},
                                new String[]{}, new String[]{"employee.full_name", "employee.code", "department.name"}) + """
                        , employee.full_name, employee.code, employee.id
                        LIMIT :limit OFFSET :offset
                        """)
                .setParameter("keyword", keyword)
                .setParameter("limit", safeSize)
                .setParameter("offset", offset));
        List<ClientAccessCandidate> items = rows.stream()
                .map(row -> new ClientAccessCandidate(
                        (UUID) row[0], Objects.toString(row[1], ""),
                        Objects.toString(row[2], ""),
                        (UUID) row[6],
                        row[3] == null ? null : row[3].toString(),
                        Objects.toString(row[4], ""), Boolean.TRUE.equals(row[5]),
                        // The original candidate predicate requires an active, non-deleted account.
                        "active"))
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
        return applyValidated(clientId, validateRequest(request));
    }

    /**
     * Batch owner/viewer maintenance for a multi-selected customer list.
     *
     * <p>Client ids are applied in sorted order so two concurrent batches take
     * the per-customer write locks in the same sequence and cannot deadlock.
     * Each customer contributes its own current access version (the operator
     * picked rows, not revisions) and its own untouched dimension: a null
     * owner keeps that customer's owner, a null viewer list keeps its viewers.
     * One transaction: a rejected customer (missing owner,离职 assignee,
     * 越权) rolls the whole batch back rather than leaving half of it applied.
     */
    @Transactional
    public List<ClientAccessDetail> updateBatch(ClientAccessBatchUpdateRequest request) {
        tx.bind();
        if (request == null || request.clientIds() == null || request.clientIds().isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请先选择要设置的客户");
        }
        if (request.ownerEmployeeId() == null && request.ownerEmployeeIds() == null && request.viewerEmployeeIds() == null) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED, "请至少设置负责人或可见人其中一项");
        }
        if (request.clientIds().size() > RequestLimits.BATCH_IDS) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "一次最多设置 "
                    + RequestLimits.BATCH_IDS + " 个客户");
        }
        List<UUID> clientIds = new LinkedHashSet<>(request.clientIds()).stream()
                .sorted()
                .toList();
        List<ClientAccessDetail> results = new ArrayList<>(clientIds.size());
        for (UUID clientId : clientIds) {
            Client snapshot = requireClient(clientId);
            requireAccessAdministration(snapshot);
            List<UUID> owners = request.ownerEmployeeIds() != null ? request.ownerEmployeeIds()
                    : request.ownerEmployeeId() != null ? List.of(request.ownerEmployeeId()) : activeOwnerIds(snapshot);
            if (owners.isEmpty()) {
                throw new ApiException(
                        ErrorCode.VALIDATION_FAILED,
                        "客户「" + clientLabel(snapshot) + "」还没有负责人，本次批量必须同时指定负责人");
            }
            List<UUID> viewerIds = request.viewerEmployeeIds() != null
                    ? request.viewerEmployeeIds()
                    : activeViewerIds(clientId);
            results.add(applyValidated(clientId, validateRequest(new ClientAccessUpdateRequest(
                    owners.isEmpty() ? null : owners.getFirst(),
                    viewerIds,
                    snapshot.getAccessVersion(),
                    request.reason(), owners))));
        }
        return List.copyOf(results);
    }

    private static String clientLabel(Client client) {
        String name = client.getName();
        if (name != null && !name.isBlank()) return name;
        String code = client.getCode();
        return code == null || code.isBlank() ? client.getId().toString() : code;
    }

    private ClientAccessDetail applyValidated(UUID clientId, ValidatedRequest validated) {
        Client snapshot = requireClient(clientId);
        requireAccessAdministration(snapshot);
        if (snapshot.getAccessVersion() != validated.expectedAccessVersion()) {
            throw new ApiException(
                    ErrorCode.CONFLICT,
                    "客户归属或可见人已被其他人修改，请刷新后重试");
        }

        Set<UUID> requestedEmployees = new LinkedHashSet<>(validated.viewerEmployeeIds());
        requestedEmployees.addAll(validated.ownerEmployeeIds());
        Set<UUID> lockedEmployees = new LinkedHashSet<>(requestedEmployees);
        List<UUID> previousOwnerIds = activeOwnerIds(snapshot);
        lockedEmployees.addAll(previousOwnerIds);
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
        for (UUID ownerId : validated.ownerEmployeeIds())
            requireCurrentEmployee(ownerId, employees.get(ownerId), activeAccountEmployees, "客户负责人");
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
        var effectiveViewers = new LinkedHashSet<>(effectiveViewerIds);
        for (UUID oldOwnerId : previousOwnerIds) {
            EmployeeReference oldOwner = employees.get(oldOwnerId);
            if (!validated.ownerEmployeeIds().contains(oldOwnerId) && oldOwner != null && !oldOwner.deleted()
                    && CurrentEmployeeStatusPolicy.isCurrentEmployee(oldOwner.status())
                    && activeAccountEmployees.contains(oldOwnerId)) effectiveViewers.add(oldOwnerId);
        }
        effectiveViewers.removeAll(validated.ownerEmployeeIds());
        if (effectiveViewers.size() > RequestLimits.ADMIN_SCOPE_OWNERS)
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "可见人含前负责人数量超过上限");
        effectiveViewerIds = effectiveViewers.stream().sorted().toList();

        UUID actorUserId = currentUser.requireId();
        List<UUID> previousViewerIds = activeViewerIds(clientId);

        replaceViewers(clientId, effectiveViewerIds, actorUserId);
        client.setOwnerEmployeeId(owner.id());
        client.setEmpId(owner.legacyId() == null ? null : owner.legacyId().toString());
        replaceCoOwners(clientId, validated.ownerEmployeeIds());
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
                actorUserId, previousOwnerIds, validated.ownerEmployeeIds());
        return toDetail(client);
    }

    private ValidatedRequest validateRequest(ClientAccessUpdateRequest request) {
        if (request == null) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "客户负责人必填");
        }
        List<UUID> rawOwners = request.ownerEmployeeIds() == null
                ? request.ownerEmployeeId() == null ? List.of() : List.of(request.ownerEmployeeId())
                : request.ownerEmployeeIds();
        if (rawOwners.isEmpty() || rawOwners.size() > RequestLimits.ADMIN_SCOPE_OWNERS || rawOwners.stream().anyMatch(Objects::isNull))
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "客户负责人必填且不能超过上限");
        List<UUID> owners = List.copyOf(new LinkedHashSet<>(rawOwners));
        if (request.ownerEmployeeIds() != null && request.ownerEmployeeId() != null
                && !request.ownerEmployeeId().equals(owners.getFirst()))
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "主负责人与负责人列表首项不一致");
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
            if (!owners.contains(viewerId)) normalized.add(viewerId);
        }
        List<UUID> sorted = normalized.stream().sorted().toList();
        return new ValidatedRequest(
                owners.getFirst(),
                sorted,
                request.expectedAccessVersion(),
                reason, owners);
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
        return employeeReferences(employeeIds, true);
    }
    private Map<UUID, EmployeeReference> employeeReferences(Collection<UUID> employeeIds, boolean lock) {
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
                        """ + (lock ? " FOR SHARE OF employee" : ""))
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

    private List<UUID> activeOwnerIds(Client client) {
        var owners = new LinkedHashSet<UUID>();
        if (client.getOwnerEmployeeId() == null) return List.of();
        owners.add(client.getOwnerEmployeeId());
        owners.addAll(NativeQueryResults.typedRows(em.createNativeQuery("""
                SELECT employee_id FROM client_co_owners WHERE client_id=:clientId
                ORDER BY sort_order, employee_id
                """).setParameter("clientId", client.getId()), UUID.class));
        return List.copyOf(owners);
    }

    private void replaceCoOwners(UUID clientId, List<UUID> owners) {
        em.createNativeQuery("DELETE FROM client_co_owners WHERE client_id=:clientId")
                .setParameter("clientId", clientId).executeUpdate();
        for (int i=1; i<owners.size(); i++) em.createNativeQuery("""
                INSERT INTO client_co_owners(client_id,employee_id,sort_order)
                VALUES(:clientId,:employeeId,:sortOrder)
                """).setParameter("clientId", clientId).setParameter("employeeId", owners.get(i))
                .setParameter("sortOrder", i).executeUpdate();
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
            UUID actorUserId, List<UUID> previousOwnerIds, List<UUID> newOwnerIds) {
        em.createNativeQuery("""
                        INSERT INTO client_access_change_events
                            (client_id, previous_owner_employee_id, new_owner_employee_id,
                             previous_viewer_ids, new_viewer_ids, resulting_access_version,
                             reason, actor_user_id, previous_owner_ids, new_owner_ids)
                        VALUES (:clientId, :previousOwnerId, :newOwnerId,
                                CAST(:previousViewerIds AS UUID[]), CAST(:newViewerIds AS UUID[]),
                                :resultingAccessVersion, :reason, :actorUserId,
                                CAST(:previousOwnerIds AS UUID[]), CAST(:newOwnerIds AS UUID[]))
                        """)
                .setParameter("clientId", clientId)
                .setParameter("previousOwnerId", previousOwnerId)
                .setParameter("newOwnerId", newOwnerId)
                .setParameter("previousViewerIds", uuidArrayLiteral(previousViewerIds))
                .setParameter("newViewerIds", uuidArrayLiteral(newViewerIds))
                .setParameter("resultingAccessVersion", resultingAccessVersion)
                .setParameter("reason", reason)
                .setParameter("actorUserId", actorUserId)
                .setParameter("previousOwnerIds", uuidArrayLiteral(previousOwnerIds))
                .setParameter("newOwnerIds", uuidArrayLiteral(newOwnerIds))
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
        var ownerIds = activeOwnerIds(client);
        var refs = employeeReferences(ownerIds, false);
        List<ClientAccessViewer> owners = ownerIds.stream().map(id -> {
            var employee = refs.get(id);
            return new ClientAccessViewer(id, employee == null ? "未命名员工" : employee.name(),
                    employee == null ? "" : employee.code(), employee == null ? null : employee.departmentName());
        }).toList();
        return new ClientAccessDetail(
                client.getId(),
                client.getOwnerEmployeeId(),
                ownerName,
                client.getAccessVersion(),
                List.copyOf(viewers), owners);
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
            String reason, List<UUID> ownerEmployeeIds) {
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
