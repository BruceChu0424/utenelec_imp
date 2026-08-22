package com.uten.imp.features.auth.model;

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
 * 登录账号（与 Employee 1:1）。登录账号默认 = 手机号（历史曾用工号）。
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

    /**
     * 管理员设置的临时密码有效期截止时间（V297）。仅 admin reset-password 流程写入
     * （now + 72h）；入职/补开账号的初始密码不设置。登录时若 mustChangePassword 且已过期
     * 则拒绝登录；员工改密成功后清空。NULL = 无有效期限制。
     */
    @Column(name = "temp_password_expires_at")
    private OffsetDateTime tempPasswordExpiresAt;

    /**
     * 超级管理员标记。TRUE 时：
     *  - 鉴权层绕过 role_permissions 映射，直接拿到全量权限（即便将来新增的 permission 也按"已有"处理）
     *  - 该账号不被"职务 / 岗位"语义绑定——admin 不需要 role 也能 work
     * 默认 false。
     */
    @Column(name = "is_super_admin", nullable = false)
    private boolean superAdmin = false;

    /**
     * 是否允许云端（外网）访问。云端实例（uten.deployment.site=cloud）的门禁依据：
     * 仅 remote_access=TRUE 的账号可在云端访问。变更由触发器即时 bump auth_version，
     * 旧 access token 失效。默认 false。仅超管可改（AdminUserController）。
     */
    @Column(name = "remote_access", nullable = false)
    private boolean remoteAccess = false;

    /**
     * Authorization snapshot version maintained by database triggers.
     *
     * <p>Read-only in JPA so a stale entity save can never overwrite a trigger
     * increment. The value is copied into access JWTs and compared on every
     * request.
     */
    @Column(name = "auth_version", nullable = false, insertable = false, updatable = false)
    private long authVersion;

    /** Permanent contextual-delegation eligibility generation (V322). */
    @Column(
            name = "permission_delegation_generation",
            nullable = false,
            insertable = false,
            updatable = false)
    private long permissionDelegationGeneration;
}
