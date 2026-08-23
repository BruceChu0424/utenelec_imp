package com.uten.imp.features.rbac;

import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Lock;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

import jakarta.persistence.LockModeType;
import java.util.Collection;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface ManagerPermissionDelegationRepository extends
        JpaRepository<ManagerPermissionDelegation, ManagerPermissionDelegationId> {

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("""
            SELECT delegation
            FROM ManagerPermissionDelegation delegation
            WHERE delegation.id = :id
            """)
    Optional<ManagerPermissionDelegation> findByIdForUpdate(
            @Param("id") ManagerPermissionDelegationId id);

    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("""
            SELECT delegation
            FROM ManagerPermissionDelegation delegation
            WHERE delegation.id IN :ids
            ORDER BY delegation.id.userId,
                     delegation.id.departmentId,
                     delegation.id.permissionId
            """)
    List<ManagerPermissionDelegation> findAllByIdForUpdate(
            @Param("ids") Collection<ManagerPermissionDelegationId> ids);

    @Query("""
            SELECT delegation
            FROM ManagerPermissionDelegation delegation
            WHERE delegation.id.userId = :userId
              AND delegation.id.departmentId = :departmentId
            """)
    List<ManagerPermissionDelegation> findForEmployeePanel(
            @Param("userId") UUID userId,
            @Param("departmentId") UUID departmentId);

    /** Minimal candidate row; PermissionResolver performs every dynamic eligibility check. */
    interface EnabledDelegationCandidate {
        String getPermissionCode();
        UUID getPermissionId();
        UUID getDepartmentId();
        UUID getGrantorUserId();
        String getSurfaceKey();
        long getTargetUserGeneration();
        long getTargetEmployeeGeneration();
        long getTargetDepartmentGeneration();
        long getGrantorUserGeneration();
        Long getGrantorEmployeeGeneration();
        long getGrantorAuthVersion();
        long getGrantorAuthorizationEpoch();
        String getScopeSource();
        UUID getScopeDepartmentId();
        Long getScopeGeneration();
        UUID getScopeAssignmentId();
        Long getScopeAssignmentVersion();
    }

    @Query(value = """
            SELECT permission.code AS "permissionCode",
                   delegation.permission_id AS "permissionId",
                   delegation.department_id AS "departmentId",
                   delegation.granted_by_user_id AS "grantorUserId",
                   delegation.surface_key AS "surfaceKey",
                   delegation.target_user_generation AS "targetUserGeneration",
                   delegation.target_employee_generation AS "targetEmployeeGeneration",
                   delegation.target_department_generation AS "targetDepartmentGeneration",
                   delegation.grantor_user_generation AS "grantorUserGeneration",
                   delegation.grantor_employee_generation AS "grantorEmployeeGeneration",
                   delegation.grantor_auth_version AS "grantorAuthVersion",
                   delegation.grantor_authorization_epoch AS "grantorAuthorizationEpoch",
                   delegation.scope_source AS "scopeSource",
                   delegation.scope_department_id AS "scopeDepartmentId",
                   delegation.scope_generation AS "scopeGeneration",
                   delegation.scope_assignment_id AS "scopeAssignmentId",
                   delegation.scope_assignment_version AS "scopeAssignmentVersion"
            FROM manager_permission_delegations delegation
            JOIN permissions permission ON permission.id = delegation.permission_id
            WHERE delegation.user_id = :userId
              AND delegation.enabled = TRUE
              AND permission.active = TRUE
            """, nativeQuery = true)
    List<EnabledDelegationCandidate> findEnabledCandidatesByUserId(
            @Param("userId") UUID userId);

    /** Serialize grants with shared department/catalog authorization changes. */
    @Query(value = """
            SELECT epoch
            FROM authorization_state
            WHERE singleton_id = 1
            FOR UPDATE
            """, nativeQuery = true)
    long lockAuthorizationEpoch();

    @Query(value = """
            SELECT epoch
            FROM authorization_state
            WHERE singleton_id = 1
            """, nativeQuery = true)
    long currentAuthorizationEpoch();
}
