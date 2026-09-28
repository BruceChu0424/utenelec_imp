package com.uten.imp.security;

import com.uten.imp.features.auth.PermissionResolver;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.core.namedparam.SqlParameterSource;

import java.sql.ResultSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyBoolean;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 后台任务重建提交人主体: 与 JwtAuthFilter 同一套账号状态判定, 外加「首登待改密」; 授权戳任何变化都拒绝,
 * 从不回落到超管或系统身份。
 */
class SubmitterPrincipalRestorerTest {

    private final UUID userId = UUID.randomUUID();
    private final UUID employeeId = UUID.randomUUID();
    private NamedParameterJdbcTemplate jdbc;
    private StaffAuthorityResolver authorities;
    private SubmitterPrincipalRestorer restorer;

    private record Row(UUID employeeId, String loginAccount, String status, boolean mustChangePassword,
                       boolean superAdmin, boolean deleted, long authVersion, long epoch) {
    }

    @BeforeEach
    void setUp() {
        jdbc = mock(NamedParameterJdbcTemplate.class);
        authorities = mock(StaffAuthorityResolver.class);
        restorer = new SubmitterPrincipalRestorer(jdbc, authorities);
        when(authorities.resolve(eq(userId), eq(employeeId), anyBoolean(), anyLong(), anyLong()))
                .thenReturn(new PermissionResolver.AuthorizationSnapshot(Set.of("ai:use", "sales_quote:create")));
    }

    @SuppressWarnings("unchecked")
    private void account(Row row) throws Exception {
        if (row == null) {
            when(jdbc.query(anyString(), any(SqlParameterSource.class), any(RowMapper.class))).thenReturn(List.of());
            return;
        }
        ResultSet rs = mock(ResultSet.class);
        when(rs.getObject("employee_id", UUID.class)).thenReturn(row.employeeId());
        when(rs.getString("login_account")).thenReturn(row.loginAccount());
        when(rs.getString("status")).thenReturn(row.status());
        when(rs.getBoolean("must_change_password")).thenReturn(row.mustChangePassword());
        when(rs.getBoolean("is_super_admin")).thenReturn(row.superAdmin());
        when(rs.getBoolean("remote_access")).thenReturn(false);
        when(rs.getBoolean("is_deleted")).thenReturn(row.deleted());
        when(rs.getLong("auth_version")).thenReturn(row.authVersion());
        when(rs.getLong("authorization_epoch")).thenReturn(row.epoch());
        when(jdbc.query(anyString(), any(SqlParameterSource.class), any(RowMapper.class))).thenAnswer(invocation -> {
            RowMapper<Object> mapper = invocation.getArgument(2);
            return List.of(mapper.mapRow(rs, 0));
        });
    }

    private Row active() {
        return new Row(employeeId, "13900000000", "active", false, false, false, 7, 3);
    }

    @Test
    void restoresTheSubmitterWithServerSideAuthoritiesAndNoSession() throws Exception {
        account(active());

        AuthUser user = restorer.restore(userId, 7, 3L);

        assertThat(user.getId()).isEqualTo(userId);
        assertThat(user.getEmployeeId()).isEqualTo(employeeId);
        assertThat(user.getPermissions()).containsExactlyInAnyOrder("ai:use", "sales_quote:create");
        assertThat(user.isSuperAdmin()).isFalse();
        assertThat(user.isVisitor()).isFalse();
        assertThat(user.getSessionId()).isNull();
        assertThat(user.getImpersonatedBy()).isNull();
        assertThat(user.isMustChangePassword()).isFalse();
        verify(authorities).resolve(userId, employeeId, false, 7, 3);
    }

    @Test
    void currentStampsMirrorTheJwtClaims() throws Exception {
        account(active());

        assertThat(restorer.currentStamps(userId))
                .contains(new SubmitterPrincipalRestorer.AuthorizationStamps(7, 3));
    }

    @Test
    void rejectsEveryAccountStateChangeWithoutResolvingAuthorities() throws Exception {
        List<Row> rejected = List.of(
                new Row(employeeId, "13900000000", "locked", false, false, false, 7, 3),
                new Row(employeeId, "13900000000", "disabled", false, false, false, 7, 3),
                new Row(employeeId, "13900000000", "active", false, false, true, 7, 3),
                new Row(employeeId, "13900000000", "active", true, false, false, 7, 3),
                new Row(null, "13900000000", "active", false, false, false, 7, 3),
                new Row(employeeId, " ", "active", false, false, false, 7, 3),
                new Row(employeeId, "13900000000", "active", false, false, false, 8, 3),
                new Row(employeeId, "13900000000", "active", false, false, false, 7, 4));
        for (Row row : rejected) {
            setUp();
            account(row);
            assertThatThrownBy(() -> restorer.restore(userId, 7, 3L))
                    .as(row.toString())
                    .isInstanceOf(SubmitterPrincipalRestorer.PrincipalChangedException.class);
            verify(authorities, never()).resolve(any(), any(), anyBoolean(), anyLong(), anyLong());
        }
    }

    @Test
    void missingAccountOrUnknownEpochFailsClosed() throws Exception {
        account(null);
        assertThatThrownBy(() -> restorer.restore(userId, 7, 3L))
                .isInstanceOf(SubmitterPrincipalRestorer.PrincipalChangedException.class)
                .extracting(error -> ((SubmitterPrincipalRestorer.PrincipalChangedException) error).reason())
                .isEqualTo("account_missing");

        setUp();
        account(active());
        assertThatThrownBy(() -> restorer.restore(userId, 7, null))
                .isInstanceOf(SubmitterPrincipalRestorer.PrincipalChangedException.class);
    }

    @Test
    void superAdminIsRestoredOnlyWhenTheAccountReallyIsOne() throws Exception {
        account(new Row(employeeId, "13900000000", "active", false, true, false, 7, 3));

        AuthUser user = restorer.restore(userId, 7, 3L);

        assertThat(user.isSuperAdmin()).isTrue();
        verify(authorities).resolve(userId, employeeId, true, 7, 3);
    }
}
