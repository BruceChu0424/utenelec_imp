package com.uten.imp.features.rbac;

import jakarta.persistence.Column;
import jakarta.persistence.EmbeddedId;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.Instant;
import java.util.UUID;

/**
 * Page-context permission contributed by an authorized organization leader.
 *
 * <p>This is a separate source from {@link UserPermissionOverride}; central
 * personal revokes therefore keep precedence and cannot be overwritten here.
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "manager_permission_delegations")
public class ManagerPermissionDelegation {

    @EmbeddedId
    private ManagerPermissionDelegationId id;

    @Column(nullable = false)
    private boolean enabled;

    @Column(name = "surface_key", nullable = false, length = 128)
    private String surfaceKey;

    @Column(name = "granted_by_user_id", nullable = false)
    private UUID grantedByUserId;

    @Column(name = "target_user_generation", nullable = false)
    private long targetUserGeneration;

    @Column(name = "target_employee_generation", nullable = false)
    private long targetEmployeeGeneration;

    @Column(name = "target_department_generation", nullable = false)
    private long targetDepartmentGeneration;

    @Column(name = "grantor_user_generation", nullable = false)
    private long grantorUserGeneration;

    @Column(name = "grantor_employee_generation")
    private Long grantorEmployeeGeneration;

    @Column(name = "grantor_auth_version", nullable = false)
    private long grantorAuthVersion;

    @Column(name = "grantor_authorization_epoch", nullable = false)
    private long grantorAuthorizationEpoch;

    @Column(name = "scope_source", nullable = false)
    private String scopeSource = "LEGACY_UNVERIFIED";

    @Column(name = "scope_department_id")
    private UUID scopeDepartmentId;

    @Column(name = "scope_generation")
    private Long scopeGeneration;

    @Column(name = "scope_assignment_id")
    private UUID scopeAssignmentId;

    @Column(name = "scope_assignment_version")
    private Long scopeAssignmentVersion;

    @Column(name = "row_version", nullable = false)
    private long rowVersion = 1L;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt = Instant.now();

    @Column(name = "updated_at", nullable = false)
    private Instant updatedAt = Instant.now();

    @Column(name = "created_by", updatable = false)
    private UUID createdBy;

    @Column(name = "updated_by")
    private UUID updatedBy;
}
