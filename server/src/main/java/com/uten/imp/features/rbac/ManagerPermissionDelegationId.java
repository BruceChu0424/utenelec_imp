package com.uten.imp.features.rbac;

import jakarta.persistence.Column;
import jakarta.persistence.Embeddable;
import lombok.AllArgsConstructor;
import lombok.EqualsAndHashCode;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.io.Serializable;
import java.util.UUID;

/** Composite identity for one target user, permission and target department. */
@Embeddable
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@EqualsAndHashCode
public class ManagerPermissionDelegationId implements Serializable {

    @Column(name = "user_id")
    private UUID userId;

    @Column(name = "permission_id")
    private UUID permissionId;

    @Column(name = "department_id")
    private UUID departmentId;
}
