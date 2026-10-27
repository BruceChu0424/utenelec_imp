package com.uten.imp.businesschain;

import com.uten.imp.security.JwtService;
import java.util.UUID;
import java.util.stream.Stream;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;
import org.springframework.beans.factory.annotation.Autowired;
import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/** Account flags alone cannot give an archived/noncurrent employee a staff identity. */
class StaffEmployeeAuthenticationLifecyclePostgresTest extends AuthSessionPostgresTestSupport {
    @Autowired JwtService jwt;
    @Autowired javax.sql.DataSource dataSource;

    static Stream<Arguments> noncurrentIdentities() {
        return Stream.of(false,true).flatMap(superAdmin -> Stream.of("resigned","deleted")
                .map(state -> Arguments.of(superAdmin,state)));
    }

    @ParameterizedTest @MethodSource("noncurrentIdentities")
    void loginRefreshAndFreshlySignedAccessAllRejectANoncurrentEmployee(boolean superAdmin,String state) throws Exception {
        Employee employee=newEmployee(adminToken());
        UUID user=UUID.fromString(employee.userId());
        jdbc.update("UPDATE users SET is_super_admin=? WHERE id=?",superAdmin,user);
        var valid=login(employee.loginAccount(),EMPLOYEE_PASSWORD);
        UUID sid=jdbc.queryForObject("SELECT sid FROM auth_sessions WHERE user_id=? AND revoked_at IS NULL",UUID.class,user);
        if(state.equals("deleted")) jdbc.update("UPDATE employees SET is_deleted=true WHERE id=?",UUID.fromString(employee.employeeId()));
        else jdbc.update("UPDATE employees SET status='resigned' WHERE id=?",UUID.fromString(employee.employeeId()));
        assertEquals("active",jdbc.queryForObject("SELECT status FROM users WHERE id=?",String.class,user));
        long version=jdbc.queryForObject("SELECT auth_version FROM users WHERE id=?",Long.class,user);
        long epoch=jdbc.queryForObject("SELECT epoch FROM authorization_state WHERE singleton_id=1",Long.class);
        // A new current stamp avoids accidentally proving only the existing av/ae invalidation rule.
        var access=me(jwt.issueAccess(user,version,epoch,sid));
        var refresh=mvc.perform(json(post("/api/auth/refresh"),java.util.Map.of("refreshToken",valid.path("refreshToken").asText()),null)).andReturn();
        var login=loginResult(employee.loginAccount(),EMPLOYEE_PASSWORD);
        assertAll(
                ()->assertEquals(401,access.getResponse().getStatus(),"Freshly signed JWT must still require a current employee"),
                ()->assertEquals(401,refresh.getResponse().getStatus(),"Refresh must not mint credentials for an archived/resigned employee"),
                ()->assertEquals(401,login.getResponse().getStatus(),"Correct password must not reopen a noncurrent employee identity"));
    }

    static Stream<Arguments> currentIdentities() {
        return Stream.of(false,true).flatMap(superAdmin -> Stream.of("active","probation","onLeave")
                .map(state -> Arguments.of(superAdmin,state)));
    }

    @ParameterizedTest @MethodSource("currentIdentities")
    void currentIdentityStatusesRemainUsableForOrdinaryAndSuperAdminAccounts(boolean superAdmin,String state) throws Exception {
        Employee employee=newEmployee(adminToken());UUID user=UUID.fromString(employee.userId());
        jdbc.update("UPDATE users SET is_super_admin=? WHERE id=?",superAdmin,user);
        jdbc.update("UPDATE employees SET status=? WHERE id=?",state,UUID.fromString(employee.employeeId()));
        var valid=login(employee.loginAccount(),EMPLOYEE_PASSWORD);
        assertEquals(200,me(valid.path("accessToken").asText()).getResponse().getStatus());
        assertEquals(200,mvc.perform(json(post("/api/auth/refresh"),java.util.Map.of("refreshToken",valid.path("refreshToken").asText()),null))
                .andReturn().getResponse().getStatus());
    }

    @org.junit.jupiter.api.Test
    void logoutUsingTheRefreshThatJustRotatedStillClosesItsOwnSession() throws Exception {
        Employee employee=newEmployee(adminToken());
        String beforeRotation=employee.refreshToken();
        var rotated=mvc.perform(json(post("/api/auth/refresh"),java.util.Map.of("refreshToken",beforeRotation),null)).andReturn();
        assertEquals(200,rotated.getResponse().getStatus());
        var replacement=json(rotated);
        assertEquals(200,mvc.perform(json(post("/api/auth/logout"),java.util.Map.of("refreshToken",beforeRotation),null))
                .andReturn().getResponse().getStatus());
        var access=me(replacement.path("accessToken").asText());
        var refresh=mvc.perform(json(post("/api/auth/refresh"),java.util.Map.of("refreshToken",replacement.path("refreshToken").asText()),null)).andReturn();
        assertAll(
                ()->assertEquals(401,access.getResponse().getStatus(),"A rotation race must not leave access working after logout"),
                ()->assertEquals(401,refresh.getResponse().getStatus(),"The replacement token is bound to the logged-out session"));
        assertTrue(jdbc.queryForObject("SELECT replaced_by IS NOT NULL FROM refresh_tokens WHERE token_hash=?",Boolean.class,
                com.uten.imp.common.util.HashUtil.sha256(beforeRotation)),"Logout must preserve the rotation lineage");
    }

    @org.junit.jupiter.api.Test
    void logoutFromAnOlderRotatedSessionCannotCloseALaterPasswordLogin() throws Exception {
        Employee employee=newEmployee(adminToken());String old=employee.refreshToken();
        assertEquals(200,mvc.perform(json(post("/api/auth/refresh"),java.util.Map.of("refreshToken",old),null)).andReturn().getResponse().getStatus());
        var newer=login(employee.loginAccount(),EMPLOYEE_PASSWORD);
        assertEquals(200,mvc.perform(json(post("/api/auth/logout"),java.util.Map.of("refreshToken",old),null)).andReturn().getResponse().getStatus());
        assertEquals(200,me(newer.path("accessToken").asText()).getResponse().getStatus());
        assertEquals(200,mvc.perform(json(post("/api/auth/refresh"),java.util.Map.of("refreshToken",newer.path("refreshToken").asText()),null))
                .andReturn().getResponse().getStatus());
    }

    @org.junit.jupiter.api.Test
    void aTemporaryPasswordExpiringWhileTheLoginWaitsForItsRealRowLockCannotOpenASession() throws Exception {
        Employee employee=newEmployee(adminToken());UUID user=UUID.fromString(employee.userId());
        var deadline=java.time.OffsetDateTime.now().plusMinutes(10);
        jdbc.update("UPDATE users SET must_change_password=true,temp_password_expires_at=?,failed_attempts=3 WHERE id=?",deadline,user);
        var lastLogin=jdbc.queryForObject("SELECT last_login_at FROM users WHERE id=?",java.time.OffsetDateTime.class,user);
        long sessionsBefore=jdbc.queryForObject("SELECT count(*) FROM auth_sessions WHERE user_id=?",Long.class,user);
        try(var gate=dataSource.getConnection();var pool=java.util.concurrent.Executors.newSingleThreadExecutor()) {
            gate.setAutoCommit(false);
            int pid;
            try(var query=gate.prepareStatement("SELECT pg_backend_pid()");var rows=query.executeQuery()){rows.next();pid=rows.getInt(1);}
            try(var lock=gate.prepareStatement("SELECT id FROM users WHERE id=? FOR UPDATE")){lock.setObject(1,user);lock.executeQuery().close();}
            var pending=pool.submit(()->loginResult(employee.loginAccount(),EMPLOYEE_PASSWORD));
            try {
                long waitUntil=System.nanoTime()+java.util.concurrent.TimeUnit.SECONDS.toNanos(10);
                boolean blocked=false;
                while(System.nanoTime()<waitUntil) {
                    blocked=Boolean.TRUE.equals(jdbc.queryForObject("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE ?=ANY(pg_blocking_pids(pid)))",Boolean.class,pid));
                    if(blocked) break;
                    Thread.sleep(20);
                }
                assertTrue(blocked,"Login must reach the actual PostgreSQL account lock before its credential deadline");
                // Change the authoritative deadline using the connection that
                // owns the real row lock. Sleeping past a 15s deadline instead
                // hits the production lock_timeout and proves only a 409.
                try(var expire=gate.prepareStatement("UPDATE users SET temp_password_expires_at=clock_timestamp()-interval '1 second' WHERE id=?")) {
                    expire.setObject(1,user);
                    assertEquals(1,expire.executeUpdate());
                }
            } finally {gate.commit();}
            assertEquals(401,pending.get(15,java.util.concurrent.TimeUnit.SECONDS).getResponse().getStatus());
        }
        assertEquals(3,jdbc.queryForObject("SELECT failed_attempts FROM users WHERE id=?",Integer.class,user));
        assertEquals(lastLogin,jdbc.queryForObject("SELECT last_login_at FROM users WHERE id=?",java.time.OffsetDateTime.class,user));
        assertEquals(sessionsBefore,jdbc.queryForObject("SELECT count(*) FROM auth_sessions WHERE user_id=?",Long.class,user));
    }

    @org.junit.jupiter.api.Test
    void anOutstandingTemporaryDeadlineIsAlsoAuthoritativeForRefreshAndAccess() throws Exception {
        Employee employee=newEmployee(adminToken());UUID user=UUID.fromString(employee.userId());
        UUID sid=jdbc.queryForObject("SELECT sid FROM auth_sessions WHERE user_id=? AND revoked_at IS NULL",UUID.class,user);
        jdbc.update("UPDATE users SET must_change_password=true,temp_password_expires_at=now()-interval '1 second' WHERE id=?",user);
        long version=jdbc.queryForObject("SELECT auth_version FROM users WHERE id=?",Long.class,user);
        long epoch=jdbc.queryForObject("SELECT epoch FROM authorization_state WHERE singleton_id=1",Long.class);
        long tokensBefore=jdbc.queryForObject("SELECT count(*) FROM refresh_tokens WHERE user_id=?",Long.class,user);
        assertEquals(401,me(jwt.issueAccess(user,version,epoch,sid)).getResponse().getStatus());
        assertEquals(401,mvc.perform(json(post("/api/auth/refresh"),java.util.Map.of("refreshToken",employee.refreshToken()),null))
                .andReturn().getResponse().getStatus());
        assertEquals(tokensBefore,jdbc.queryForObject("SELECT count(*) FROM refresh_tokens WHERE user_id=?",Long.class,user));
    }
}
