package com.uten.imp.security;

import lombok.Getter;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.userdetails.UserDetails;

import java.util.Collection;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;
import java.util.stream.Stream;

/**
 * 已认证主体（放 SecurityContext）。支持两类主体：
 * <ul>
 *   <li>STAFF：员工/HR/保安/管理层（账号密码登录，users 表）</li>
 *   <li>VISITOR：访客（手机号验证码登录，visitor_accounts 表）</li>
 * </ul>
 * authorities = 功能权限 ∪ ROLE_角色；首登强制改密时仅授 CHANGE_PASSWORD。
 *
 * <p>superAdmin：TRUE 时绕过 role_permissions 缺漏，permissions 已是全量，
 * 不必依赖具体 role/rolePermission 映射。
 */
@Getter
public class AuthUser implements UserDetails {

    private final UUID id;                  // staff=users.id / visitor=visitor_accounts.id
    private final SubjectType subjectType;
    private final UUID employeeId;          // 仅 staff
    private final UUID visitorId;           // 仅 visitor
    private final String loginAccount;      // staff=登录账号 / visitor=手机号
    private final String visitorNo;         // 仅 visitor
    private final Set<String> roles;
    private final Set<String> permissions;
    private final boolean mustChangePassword;
    private final boolean accountNonLocked;
    private final boolean superAdmin;       // 超级管理员标记

    /** 员工构造（兼容既有 JwtAuthFilter 调用）。 */
    public AuthUser(UUID id, UUID employeeId, String loginAccount,
                    Set<String> roles, Set<String> permissions,
                    boolean mustChangePassword, boolean accountNonLocked) {
        this(id, SubjectType.STAFF, employeeId, null, loginAccount, null,
                roles, permissions, mustChangePassword, accountNonLocked, false);
    }

    /** 员工构造（含 superAdmin 标记）。 */
    public AuthUser(UUID id, UUID employeeId, String loginAccount,
                    Set<String> roles, Set<String> permissions,
                    boolean mustChangePassword, boolean accountNonLocked,
                    boolean superAdmin) {
        this(id, SubjectType.STAFF, employeeId, null, loginAccount, null,
                roles, permissions, mustChangePassword, accountNonLocked, superAdmin);
    }

    private AuthUser(UUID id, SubjectType subjectType, UUID employeeId, UUID visitorId,
                     String loginAccount, String visitorNo,
                     Set<String> roles, Set<String> permissions,
                     boolean mustChangePassword, boolean accountNonLocked, boolean superAdmin) {
        this.id = id;
        this.subjectType = subjectType;
        this.employeeId = employeeId;
        this.visitorId = visitorId;
        this.loginAccount = loginAccount;
        this.visitorNo = visitorNo;
        this.roles = roles;
        this.permissions = permissions;
        this.mustChangePassword = mustChangePassword;
        this.accountNonLocked = accountNonLocked;
        this.superAdmin = superAdmin;
    }

    /** 访客主体工厂。 */
    public static AuthUser visitor(UUID visitorId, String phone, String visitorNo, Set<String> permissions) {
        return new AuthUser(visitorId, SubjectType.VISITOR, null, visitorId, phone, visitorNo,
                Set.of(), permissions, false, true, false);
    }

    public boolean isVisitor() {
        return subjectType == SubjectType.VISITOR;
    }

    public boolean isSuperAdmin() {
        return superAdmin;
    }

    @Override
    public Collection<? extends GrantedAuthority> getAuthorities() {
        // 首登强制改密：仅给 CHANGE_PASSWORD，其余全锁
        if (mustChangePassword) {
            return Set.of(new SimpleGrantedAuthority("CHANGE_PASSWORD"));
        }
        return Stream.concat(
                permissions.stream().map(SimpleGrantedAuthority::new),
                roles.stream().map(r -> new SimpleGrantedAuthority("ROLE_" + r))
        ).collect(Collectors.toSet());
    }

    @Override public String getUsername() { return loginAccount; }
    @Override public String getPassword() { return ""; }   // 不在此持有密码
    @Override public boolean isAccountNonExpired() { return true; }
    @Override public boolean isCredentialsNonExpired() { return true; }
    @Override public boolean isEnabled() { return true; }
    @Override public boolean isAccountNonLocked() { return accountNonLocked; }
}
