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

/** department_permissions 复合主键（department_id + permission_id）。 */
@Embeddable
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@EqualsAndHashCode
public class DepartmentPermissionId implements Serializable {

    @Column(name = "department_id")
    private UUID departmentId;

    @Column(name = "permission_id")
    private UUID permissionId;
}
