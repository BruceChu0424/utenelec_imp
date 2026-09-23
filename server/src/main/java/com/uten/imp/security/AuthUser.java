package com.uten.imp.security;

import lombok.Getter;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.userdetails.UserDetails;

import java.util.Collection;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * 已认证主体（放 SecurityContext）。支持两类主体：
 * <ul>
 *   <li>STAFF：员工/HR/保安/管理层（账号密码登录，users 表）</li>
 *   <li>VISITOR：访客（手机号验证码登录，visitor_accounts 表）</li>
 * </ul>
 * authorities = 功能权限(服务端当场按权限目录合成)；首登强制改密时仅授 CHANGE_PASSWORD。
 * 角色体系已删除(ADR-109)，不再有 ROLE_* 权威。
 *
 * <p>superAdmin：TRUE 时 permissions 已是全部目录码(含超管专属码)。
 */
@Getter
public class AuthUser implements UserDetails {

    private final UUID id;                  // staff=users.id / visitor=visitor_accounts.id
    private final SubjectType subjectType;
    private final UUID employeeId;          // 仅 staff
    private final UUID visitorId;           // 仅 visitor
    private final String loginAccount;      // staff=登录账号 / visitor=访客号（JWT 不携带手机号）
    private final String visitorNo;         // 仅 visitor
    private final Set<String> permissions;
    private final boolean mustChangePassword;
    private final boolean accountNonLocked;
    private final boolean superAdmin;       // 超级管理员标记
    private final UUID impersonatedBy;      // 非 null = 当前为「模拟身份」会话，值为真实操作人（admin）的 userId
    private final boolean remoteAccess;     // 是否允许云端(外网)访问；云端实例(uten.deployment.site=cloud)门禁依据
    private final UUID sessionId;           // 本次请求所属的服务端会话 (auth_sessions.sid); 再认证凭证绑定到它

    /** 员工构造（含 superAdmin 标记）。 */
    public AuthUser(UUID id, UUID employeeId, String loginAccount,
                    Set<String> permissions,
                    boolean mustChangePassword, boolean accountNonLocked,
                    boolean superAdmin) {
        this(id, employeeId, loginAccount, permissions,
                mustChangePassword, accountNonLocked, superAdmin, false, null);
    }

    /** 员工构造（模拟身份：impersonatedBy 为发起模拟的 admin userId，非 null 时触发只读守卫）。 */
    public AuthUser(UUID id, UUID employeeId, String loginAccount,
                    Set<String> permissions,
                    boolean mustChangePassword, boolean accountNonLocked,
                    boolean superAdmin, boolean remoteAccess, UUID impersonatedBy) {
        this(id, employeeId, loginAccount, permissions, mustChangePassword,
                accountNonLocked, superAdmin, remoteAccess, impersonatedBy, null);
    }

    /** 员工构造 (完整): 由 JwtAuthFilter 按服务端账号与会话状态重建, sessionId 取自令牌 sid。 */
    public AuthUser(UUID id, UUID employeeId, String loginAccount,
                    Set<String> permissions,
                    boolean mustChangePassword, boolean accountNonLocked,
                    boolean superAdmin, boolean remoteAccess, UUID impersonatedBy, UUID sessionId) {
        this(id, SubjectType.STAFF, employeeId, null, loginAccount, null,
                permissions, mustChangePassword, accountNonLocked, superAdmin, remoteAccess,
                impersonatedBy, sessionId);
    }

    private AuthUser(UUID id, SubjectType subjectType, UUID employeeId, UUID visitorId,
                     String loginAccount, String visitorNo,
                     Set<String> permissions,
                     boolean mustChangePassword, boolean accountNonLocked, boolean superAdmin,
                     boolean remoteAccess, UUID impersonatedBy, UUID sessionId) {
        this.id = id;
        this.subjectType = subjectType;
        this.employeeId = employeeId;
        this.visitorId = visitorId;
        this.loginAccount = loginAccount;
        this.visitorNo = visitorNo;
        this.permissions = permissions;
        this.mustChangePassword = mustChangePassword;
        this.accountNonLocked = accountNonLocked;
        this.superAdmin = superAdmin;
        this.remoteAccess = remoteAccess;
        this.impersonatedBy = impersonatedBy;
        this.sessionId = sessionId;
    }

    /** 访客主体工厂。 */
    public static AuthUser visitor(UUID visitorId, String visitorAccount, String visitorNo, Set<String> permissions) {
        return visitor(visitorId, visitorAccount, visitorNo, permissions, null);
    }

    public static AuthUser visitor(UUID visitorId, String visitorAccount, String visitorNo,
                                   Set<String> permissions, UUID sessionId) {
        return new AuthUser(visitorId, SubjectType.VISITOR, null, visitorId, visitorAccount, visitorNo,
                permissions, false, true, false, false, null, sessionId);
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
        return permissions.stream()
                .map(SimpleGrantedAuthority::new)
                .collect(Collectors.toSet());
    }

    @Override public String getUsername() { return loginAccount; }
    @Override public String getPassword() { return ""; }   // 不在此持有密码
    @Override public boolean isAccountNonExpired() { return true; }
    @Override public boolean isCredentialsNonExpired() { return true; }
    @Override public boolean isEnabled() { return true; }
    @Override public boolean isAccountNonLocked() { return accountNonLocked; }
}
