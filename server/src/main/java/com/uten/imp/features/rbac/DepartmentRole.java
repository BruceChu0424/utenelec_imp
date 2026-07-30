package com.uten.imp.features.rbac;

import jakarta.persistence.EmbeddedId;
import jakarta.persistence.Entity;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

/** 部门 ↔ 默认角色（M:N，部门直属员工自动获得这些角色的权限，不含子部门）。 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "department_roles")
public class DepartmentRole {

    @EmbeddedId
    private DepartmentRoleId id;
}
