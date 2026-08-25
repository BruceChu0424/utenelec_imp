package com.uten.imp.responsibility;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/** Writes append-only customer access evidence alongside owner handover and offboarding cleanup. */
@Component
@RequiredArgsConstructor
class ClientHandoverEventRecorder {

    private final EntityManager em;

    TransferOutcome transfer(
            UUID sourceEmployeeId,
            UUID targetEmployeeId,
            Integer targetLegacyId,
            UUID actorUserId,
            String reason,
            boolean retainSourceViewer) {
        List<ClientSnapshot> snapshots = lockOwnedSnapshots(sourceEmployeeId);
        int scopeDelegationCount = snapshots.isEmpty()
                ? 0 : clientScopeDelegationCount(sourceEmployeeId);
        List<UUID> scopeRecipients = snapshots.isEmpty()
                ? List.of()
                : eligibleClientScopeRecipients(sourceEmployeeId, targetEmployeeId);
        requireReason(reason, snapshots.size() + scopeDelegationCount);
        int changed = em.createNativeQuery("""
                        UPDATE clients
                        SET owner_employee_id=:target,
                            emp_id=:legacy,
                            version=version+1,
                            access_version=access_version+1,
                            updated_at=now(),
                            updated_by=:actor
                        WHERE owner_employee_id=:source AND is_deleted=false
                        """)
                .setParameter("target", targetEmployeeId)
                .setParameter("legacy", targetLegacyId == null ? null : targetLegacyId.toString())
                .setParameter("actor", actorUserId)
                .setParameter("source", sourceEmployeeId)
                .executeUpdate();
        for (ClientSnapshot snapshot : snapshots) {
            for (UUID recipientId : scopeRecipients) {
                upsertViewer(snapshot.clientId(), recipientId, actorUserId);
            }
            if (retainSourceViewer) {
                upsertViewer(snapshot.clientId(), sourceEmployeeId, actorUserId);
            } else {
                deactivateViewer(snapshot.clientId(), sourceEmployeeId, actorUserId);
            }
            deactivateViewer(snapshot.clientId(), targetEmployeeId, actorUserId);
            List<UUID> resultingViewers = activeViewerIds(snapshot.clientId());
            insertEvent(snapshot.clientId(), sourceEmployeeId, targetEmployeeId,
                    snapshot.viewerIds(), resultingViewers,
                    snapshot.accessVersion() + 1, reason, actorUserId);
        }
        int deletedScopes = snapshots.isEmpty() ? 0 : em.createNativeQuery("""
                        DELETE FROM user_data_scopes data_scope
                        USING users recipient
                        WHERE recipient.id=data_scope.user_id
                          AND data_scope.owner_employee_id=:source
                          AND data_scope.scope='client'
                          AND recipient.employee_id<>:source
                          AND data_scope.owner_employment_generation=(
                              SELECT count(*) FROM employment_history history
                              WHERE history.employee_id=data_scope.owner_employee_id
                                AND history.event_type='rehire')
                        """)
                .setParameter("source", sourceEmployeeId)
                .executeUpdate();
        if (deletedScopes != scopeDelegationCount) {
            throw new ApiException(
                    ErrorCode.CONFLICT, "客户整人查看授权在交接期间已变化，请刷新后重试");
        }
        return new TransferOutcome(changed, deletedScopes);
    }

    /** Locks every customer whose active viewer set contains the departing employee. */
    void lockViewerClients(UUID employeeId) {
        em.createNativeQuery("""
                        SELECT client.id
                        FROM clients client
                        JOIN client_visibility_grants grant_row
                          ON grant_row.client_id=client.id
                         AND grant_row.grantee_employee_id=:employeeId
                         AND grant_row.active=true
                        ORDER BY client.id
                        FOR UPDATE OF client
                        """)
                .setParameter("employeeId", employeeId)
                .getResultList();
    }

    int revokeViewerForOffboarding(
            UUID employeeId, UUID actorUserId, String reason) {
        List<ClientSnapshot> snapshots = lockViewerSnapshots(employeeId);
        requireReason(reason, snapshots.size());
        int changed = 0;
        for (ClientSnapshot snapshot : snapshots) {
            int revoked = deactivateViewer(snapshot.clientId(), employeeId, actorUserId);
            if (revoked == 0) continue;
            int versioned = em.createNativeQuery("""
                            UPDATE clients
                            SET version=version+1,
                                access_version=access_version+1,
                                updated_at=now(), updated_by=:actor
                            WHERE id=:clientId
                            """)
                    .setParameter("actor", actorUserId)
                    .setParameter("clientId", snapshot.clientId())
                    .executeUpdate();
            if (versioned != 1) {
                throw new ApiException(ErrorCode.CONFLICT, "客户权限清理期间客户状态已变化");
            }
            List<UUID> resultingViewers = snapshot.viewerIds().stream()
                    .filter(viewer -> !viewer.equals(employeeId))
                    .toList();
            insertEvent(snapshot.clientId(), snapshot.ownerEmployeeId(),
                    snapshot.ownerEmployeeId(), snapshot.viewerIds(), resultingViewers,
                    snapshot.accessVersion() + 1, reason, actorUserId);
            changed++;
        }
        return changed;
    }

    private List<ClientSnapshot> lockOwnedSnapshots(UUID sourceEmployeeId) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT id, owner_employee_id, access_version
                        FROM clients
                        WHERE owner_employee_id=:source AND is_deleted=false
                        ORDER BY id
                        FOR UPDATE
                        """)
                .setParameter("source", sourceEmployeeId)
                .getResultList();
        return snapshots(rows);
    }

    private List<ClientSnapshot> lockViewerSnapshots(UUID employeeId) {
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT client.id, client.owner_employee_id, client.access_version
                        FROM clients client
                        JOIN client_visibility_grants grant_row
                          ON grant_row.client_id=client.id
                         AND grant_row.grantee_employee_id=:employeeId
                         AND grant_row.active=true
                        ORDER BY client.id
                        FOR UPDATE OF client
                        """)
                .setParameter("employeeId", employeeId)
                .getResultList();
        return snapshots(rows);
    }

    private List<ClientSnapshot> snapshots(List<Object[]> clientRows) {
        List<ClientSnapshot> snapshots = new ArrayList<>(clientRows.size());
        for (Object[] row : clientRows) {
            UUID clientId = uuid(row[0]);
            UUID ownerId = uuid(row[1]);
            if (ownerId == null) {
                throw new ApiException(
                        ErrorCode.CONFLICT, "客户可见权限存在但负责人为空，请先修复客户归属");
            }
            snapshots.add(new ClientSnapshot(
                    clientId, ownerId, ((Number) row[2]).longValue(),
                    activeViewerIds(clientId)));
        }
        return snapshots;
    }

    private int clientScopeDelegationCount(UUID sourceEmployeeId) {
        return ((Number) em.createNativeQuery("""
                        SELECT count(*) FROM user_data_scopes data_scope
                        JOIN users recipient ON recipient.id=data_scope.user_id
                        WHERE data_scope.owner_employee_id=:source
                          AND data_scope.scope='client'
                          AND recipient.employee_id<>:source
                          AND data_scope.owner_employment_generation=(
                              SELECT count(*) FROM employment_history history
                              WHERE history.employee_id=data_scope.owner_employee_id
                                AND history.event_type='rehire')
                        """)
                .setParameter("source", sourceEmployeeId)
                .getSingleResult()).intValue();
    }

    private List<UUID> eligibleClientScopeRecipients(
            UUID sourceEmployeeId, UUID targetEmployeeId) {
        @SuppressWarnings("unchecked")
        List<Object> rows = em.createNativeQuery("""
                        SELECT DISTINCT recipient.employee_id
                        FROM user_data_scopes data_scope
                        JOIN users recipient ON recipient.id=data_scope.user_id
                        JOIN employees recipient_employee
                          ON recipient_employee.id=recipient.employee_id
                        WHERE data_scope.owner_employee_id=:source
                          AND data_scope.scope='client'
                          AND recipient.employee_id NOT IN (:source,:target)
                          AND data_scope.owner_employment_generation=(
                              SELECT count(*) FROM employment_history history
                              WHERE history.employee_id=data_scope.owner_employee_id
                                AND history.event_type='rehire')
                          AND recipient.status='active'
                          AND recipient.is_deleted=false
                          AND recipient_employee.status IN ('active','probation','onLeave')
                          AND recipient_employee.is_deleted=false
                        ORDER BY recipient.employee_id
                        """)
                .setParameter("source", sourceEmployeeId)
                .setParameter("target", targetEmployeeId)
                .getResultList();
        return rows.stream().map(ClientHandoverEventRecorder::uuid).toList();
    }

    private void upsertViewer(UUID clientId, UUID employeeId, UUID actorUserId) {
        em.createNativeQuery("""
                        INSERT INTO client_visibility_grants(
                            client_id, grantee_employee_id, active, row_version,
                            granted_by_user_id, revoked_by_user_id, revoked_at)
                        VALUES (:clientId, :employeeId, true, 1, :actor, NULL, NULL)
                        ON CONFLICT (client_id,grantee_employee_id) DO UPDATE
                        SET active=true,
                            row_version=client_visibility_grants.row_version+1,
                            granted_by_user_id=EXCLUDED.granted_by_user_id,
                            revoked_by_user_id=NULL,
                            revoked_at=NULL
                        WHERE client_visibility_grants.active=false
                        """)
                .setParameter("clientId", clientId)
                .setParameter("employeeId", employeeId)
                .setParameter("actor", actorUserId)
                .executeUpdate();
    }

    private List<UUID> activeViewerIds(UUID clientId) {
        @SuppressWarnings("unchecked")
        List<Object> rows = em.createNativeQuery("""
                        SELECT grantee_employee_id
                        FROM client_visibility_grants
                        WHERE client_id=:clientId AND active=true
                        ORDER BY grantee_employee_id
                        """)
                .setParameter("clientId", clientId)
                .getResultList();
        return rows.stream().map(ClientHandoverEventRecorder::uuid).toList();
    }

    private int deactivateViewer(UUID clientId, UUID employeeId, UUID actorUserId) {
        return em.createNativeQuery("""
                        UPDATE client_visibility_grants
                        SET active=false, row_version=row_version+1,
                            revoked_by_user_id=:actor, revoked_at=now()
                        WHERE client_id=:clientId
                          AND grantee_employee_id=:employeeId
                          AND active=true
                        """)
                .setParameter("actor", actorUserId)
                .setParameter("clientId", clientId)
                .setParameter("employeeId", employeeId)
                .executeUpdate();
    }

    private void insertEvent(
            UUID clientId,
            UUID previousOwnerId,
            UUID newOwnerId,
            List<UUID> previousViewers,
            List<UUID> newViewers,
            long resultingVersion,
            String reason,
            UUID actorUserId) {
        em.createNativeQuery("""
                        INSERT INTO client_access_change_events
                            (client_id, previous_owner_employee_id, new_owner_employee_id,
                             previous_viewer_ids, new_viewer_ids, resulting_access_version,
                             reason, actor_user_id)
                        VALUES
                            (:clientId, :previousOwner, :newOwner,
                             CAST(:previousViewers AS UUID[]), CAST(:newViewers AS UUID[]),
                             :version, :reason, :actor)
                        """)
                .setParameter("clientId", clientId)
                .setParameter("previousOwner", previousOwnerId)
                .setParameter("newOwner", newOwnerId)
                .setParameter("previousViewers", uuidArrayLiteral(previousViewers))
                .setParameter("newViewers", uuidArrayLiteral(newViewers))
                .setParameter("version", resultingVersion)
                .setParameter("reason", reason)
                .setParameter("actor", actorUserId)
                .executeUpdate();
    }

    private static void requireReason(String reason, int affectedCount) {
        if (affectedCount > 0
                && (reason == null || reason.isBlank() || reason.length() > 2000)) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED, "客户权限交接原因须为 1–2000 个字符");
        }
    }

    private static String uuidArrayLiteral(List<UUID> ids) {
        if (ids == null || ids.isEmpty()) return "{}";
        return "{" + String.join(",", ids.stream().map(UUID::toString).toList()) + "}";
    }

    private static UUID uuid(Object value) {
        if (value == null) return null;
        return value instanceof UUID id ? id : UUID.fromString(value.toString());
    }

    record TransferOutcome(int clientOwnerCount, int scopeDelegationCount) {
    }

    private record ClientSnapshot(
            UUID clientId,
            UUID ownerEmployeeId,
            long accessVersion,
            List<UUID> viewerIds) {
    }
}
