package com.uten.imp.features.rbac;

import com.uten.imp.common.domain.SoftDeletableEntity;
import com.uten.imp.features.org.employee.Employee;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.FetchType;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.OneToOne;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * 登录账号（与 Employee 1:1）。登录账号默认 = 工号。
 * employeeId 为具体字段（鉴权链路需直接读取，避免 LAZY 加载）；employee 为只读关联便于取姓名/部门。
 */
@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "users")
public class UserAccount extends SoftDeletableEntity {

    @Column(name = "employee_id", nullable = false, unique = true)
    private UUID employeeId;

    @OneToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "employee_id", insertable = false, updatable = false)
    private Employee employee;

    @Column(nullable = false, unique = true)
    private String loginAccount;

    @Column(name = "password_hash", nullable = false)
    private String passwordHash;

    @Column(name = "must_change_password", nullable = false)
    private boolean mustChangePassword = true;

    @Column(nullable = false)
    private String status = "active";   // active / locked / disabled

    @Column(name = "failed_attempts", nullable = false)
    private int failedAttempts = 0;

    @Column(name = "locked_until")
    private OffsetDateTime lockedUntil;

    @Column(name = "last_login_at")
    private OffsetDateTime lastLoginAt;

    @Column(name = "last_password_changed_at")
    private OffsetDateTime lastPasswordChangedAt;
}
