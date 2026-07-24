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
 * 部门 ↔ 直配权限点（M:N，部门直属员工自动获得这些权限，不含子部门）。
 * 审计列为手工赋值（复合主键实体不走 AuditableEntity 监听），createdBy 由服务层写入。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "department_permissions")
public class DepartmentPermission {

    @EmbeddedId
    private DepartmentPermissionId id;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt = Instant.now();

    @Column(name = "created_by")
    private UUID createdBy;
}
