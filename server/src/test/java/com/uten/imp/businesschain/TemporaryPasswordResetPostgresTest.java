package com.uten.imp.businesschain;

import com.uten.imp.features.admin.AccountLifecycleCoordinator;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.test.web.servlet.MvcResult;

import java.time.Duration;
import java.sql.DriverManager;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;

/** Private PostgreSQL and the complete HTTP/session/step-up chain; never production credentials. */
class TemporaryPasswordResetPostgresTest extends AuthSessionPostgresTestSupport {
    private static final String STEP_UP="X-Uten-Step-Up";
    private final List<String> promotedUsers=new java.util.ArrayList<>();
    @org.springframework.beans.factory.annotation.Autowired
    @org.springframework.beans.factory.annotation.Qualifier(DATABASE_LEASE_BEAN)
    private com.uten.imp.support.MigratedSchemaBaseline.ScopedDatabase fixtureDatabase;

    @AfterEach void retireTestOnlyAdministratorRoles() {
        for(String id:promotedUsers)jdbc.update("UPDATE users SET is_super_admin=false WHERE id=?::uuid",id);
    }

    @ParameterizedTest @ValueSource(booleans={false,true})
    void bothEntrypointsPreserveChosenValuesAndTheRandomTemporaryLifecycle(boolean employeeEntry) throws Exception {
        String admin=adminToken();Employee target=newEmployee(admin,"DEPT_ENG");
        String endpoint=endpoint(target,employeeEntry), oldAccess=target.accessToken();
        for(String chosen:List.of("1","  Selected-"+UUID.randomUUID()+"  ","密".repeat(130)+"a")) {
            var reset=reset(endpoint,admin,ADMIN_PASSWORD,Map.of("temporaryPassword",chosen));
            assertEquals(200,reset.getResponse().getStatus(),body(reset));
            assertEquals(chosen,json(reset).path("temporaryPassword").asText());
            assertEquals(401,me(oldAccess).getResponse().getStatus());
            var login=login(target.loginAccount(),chosen);
            assertTrue(login.path("mustChangePassword").asBoolean());
            oldAccess=login.path("accessToken").asText();
            assertEquals(403,mvc.perform(get("/api/admin/users").header("Authorization","Bearer "+oldAccess))
                    .andReturn().getResponse().getStatus());
            assertEquals(401,loginResult(target.loginAccount(),chosen+"wrong").getResponse().getStatus());
            assertTrue(jdbc.queryForObject("SELECT must_change_password AND temp_password_expires_at>now() FROM users WHERE id=?::uuid",
                    Boolean.class,target.userId()));
        }
        MvcResult random;
        if(employeeEntry) {
            var body=new HashMap<String,Object>();body.put("temporaryPassword",null);
            random=reset(endpoint,admin,ADMIN_PASSWORD,body);
        } else {
            random=mvc.perform(post(endpoint).header("Authorization","Bearer "+admin)
                    .header(STEP_UP,stepUp(admin,ADMIN_PASSWORD))).andReturn();
        }
        assertEquals(200,random.getResponse().getStatus(),body(random));
        String temporary=json(random).path("temporaryPassword").asText();assertEquals(20,temporary.length());
        var initial=login(target.loginAccount(),temporary);assertTrue(initial.path("mustChangePassword").asBoolean());
        var changed=changePassword(initial.path("accessToken").asText(),temporary,"ChangedOwn-"+UUID.randomUUID());
        assertFalse(changed.path("mustChangePassword").asBoolean());
        assertNull(jdbc.queryForObject("SELECT temp_password_expires_at FROM users WHERE id=?::uuid",java.time.OffsetDateTime.class,target.userId()));
        assertEquals(200,me(admin).getResponse().getStatus());
    }

    @Test
    void superAdministratorCanResetOnlyAnotherSuperAdministratorAndDoesNotAcquireRoutineSupportActions() throws Exception {
        String admin=adminToken();Employee peer=newEmployee(admin,"DEPT_ENG"),support=newEmployee(admin,"DEPT_ENG");
        promote(peer);
        admin=adminToken();
        String peerOld=login(peer.loginAccount(),EMPLOYEE_PASSWORD).path("accessToken").asText();
        var summary=mvc.perform(get("/api/admin/users/by-employee/"+peer.employeeId()).header("Authorization","Bearer "+admin)).andReturn();
        assertEquals(200,summary.getResponse().getStatus(),body(summary));
        assertFalse(json(summary).path("accountSupportAllowed").asBoolean());
        assertTrue(json(summary).path("passwordResetSupportAllowed").asBoolean());
        var detail=mvc.perform(get("/api/org/employees/"+peer.employeeId()).header("Authorization","Bearer "+admin)).andReturn();
        assertFalse(json(detail).path("accountSupportAllowed").asBoolean());
        assertTrue(json(detail).path("passwordResetSupportAllowed").asBoolean());
        var granted=mvc.perform(json(put("/api/admin/users/"+support.userId()+"/permission-overrides"),
                Map.of("grants",List.of("account:support"),"revokes",List.of()),admin)
                .header(STEP_UP,stepUp(admin,ADMIN_PASSWORD))).andReturn();
        assertEquals(200,granted.getResponse().getStatus(),body(granted));
        admin=adminToken();
        String ordinary=login(support.loginAccount(),EMPLOYEE_PASSWORD).path("accessToken").asText();
        for(boolean employeeEntry:List.of(false,true)) {
            assertEquals(403,reset(endpoint(peer,employeeEntry),ordinary,EMPLOYEE_PASSWORD,Map.of("temporaryPassword","Forbidden-1!"))
                    .getResponse().getStatus());
        }
        UUID self=jdbc.queryForObject("SELECT id FROM users WHERE login_account=?",UUID.class,ADMIN_LOGIN);
        assertEquals(403,reset("/api/admin/users/"+self+"/reset-password",admin,ADMIN_PASSWORD,Map.of()).getResponse().getStatus());
        UUID selfEmployee=jdbc.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,self);
        assertEquals(403,reset("/api/org/employees/"+selfEmployee+"/account/reset-password",admin,ADMIN_PASSWORD,Map.of()).getResponse().getStatus());
        assertEquals(200,me(admin).getResponse().getStatus());
        String chosen="PeerTemporary-"+UUID.randomUUID();
        var changed=reset(endpoint(peer,true),admin,ADMIN_PASSWORD,Map.of("temporaryPassword",chosen));
        assertEquals(200,changed.getResponse().getStatus(),body(changed));assertEquals(chosen,json(changed).path("temporaryPassword").asText());
        assertEquals(401,me(peerOld).getResponse().getStatus());
        assertTrue(jdbc.queryForObject("SELECT is_super_admin FROM users WHERE id=?::uuid",Boolean.class,peer.userId()));
        var first=login(peer.loginAccount(),chosen);assertTrue(first.path("mustChangePassword").asBoolean());
        assertEquals(403,mvc.perform(get("/api/admin/users").header("Authorization","Bearer "+first.path("accessToken").asText()))
                .andReturn().getResponse().getStatus());
        var own=changePassword(first.path("accessToken").asText(),chosen,"PeerOwn-"+UUID.randomUUID());
        assertFalse(own.path("mustChangePassword").asBoolean());
        var deniedLock=mvc.perform(json(post("/api/admin/users/"+peer.userId()+"/lock"),Map.of(),admin)).andReturn();
        assertEquals(403,deniedLock.getResponse().getStatus(),body(deniedLock));
    }

    @Test
    void malformedAndBlankInputNeitherChangesCredentialsNorExtendsStepUp() throws Exception {
        String admin=adminToken();Employee target=newEmployee(admin,"DEPT_ENG");
        String before=hash(target),token=stepUp(admin,ADMIN_PASSWORD),endpoint=endpoint(target,false);
        clock.advance(Duration.ofMinutes(4));
        var blank=mvc.perform(json(post(endpoint),Map.of("temporaryPassword"," \u2003\n"),admin).header(STEP_UP,token)).andReturn();
        assertEquals(422,blank.getResponse().getStatus(),body(blank));
        String marker="NeverPersist-"+UUID.randomUUID();
        for(Object input:List.of(Map.of("password",marker),Map.of("temporaryPassword",Map.of("value",marker)),
                Map.of("temporaryPassword",123456),Map.of("temporaryPassword",true))) {
            var rejected=mvc.perform(json(post(endpoint),input,admin).header(STEP_UP,token)).andReturn();
            assertEquals(400,rejected.getResponse().getStatus(),body(rejected));assertFalse(body(rejected).contains(marker));
        }
        assertEquals(before,hash(target));
        clock.advance(Duration.ofMinutes(2));
        var expired=mvc.perform(json(post(endpoint),Map.of("temporaryPassword","Valid-Input-3"),admin).header(STEP_UP,token)).andReturn();
        assertEquals(403,expired.getResponse().getStatus(),body(expired));
        assertEquals("REAUTH_REQUIRED",json(expired).path("code").asText());assertEquals(before,hash(target));
    }

    @ParameterizedTest @ValueSource(strings={"disabled","locked"})
    void customResetKeepsDisabledAndManualLockStates(String state) throws Exception {
        String admin=adminToken();Employee target=newEmployee(admin,"DEPT_ENG");
        jdbc.update("UPDATE users SET status=?,locked_until=NULL,failed_attempts=3 WHERE id=?::uuid",state,target.userId());
        admin=adminToken(); // Lifecycle writes advance the shared authorization epoch.
        var reset=reset(endpoint(target,false),admin,ADMIN_PASSWORD,Map.of("temporaryPassword","Held-State-"+UUID.randomUUID()));
        assertEquals(200,reset.getResponse().getStatus(),body(reset));
        assertEquals(state,jdbc.queryForObject("SELECT status FROM users WHERE id=?::uuid",String.class,target.userId()));
        assertEquals(0,jdbc.queryForObject("SELECT failed_attempts FROM users WHERE id=?::uuid",Integer.class,target.userId()));
        assertNull(jdbc.queryForObject("SELECT locked_until FROM users WHERE id=?::uuid",java.time.OffsetDateTime.class,target.userId()));
    }

    @Test
    void customSecretIsResponseOnlyAndStillExpires() throws Exception {
        String admin=adminToken();Employee target=newEmployee(admin,"DEPT_ENG");
        String chosen="Ephemeral-"+UUID.randomUUID();
        var logger=(ch.qos.logback.classic.Logger)org.slf4j.LoggerFactory.getLogger(org.slf4j.Logger.ROOT_LOGGER_NAME);
        var logs=new ch.qos.logback.core.read.ListAppender<ch.qos.logback.classic.spi.ILoggingEvent>();logs.start();logger.addAppender(logs);
        try {
            var reset=reset(endpoint(target,false),admin,ADMIN_PASSWORD,Map.of("temporaryPassword",chosen));
            assertEquals(200,reset.getResponse().getStatus(),body(reset));
            assertEquals(chosen,json(reset).path("temporaryPassword").asText());
        } finally {logger.detachAppender(logs);logs.stop();}
        assertThat(logs.list).noneMatch(event->event.getFormattedMessage().contains(chosen));
        assertEquals(0,jdbc.queryForObject("SELECT count(*) FROM audit_log a WHERE position(? in to_jsonb(a)::text)>0",Integer.class,chosen));
        assertEquals(0,jdbc.queryForObject("SELECT count(*) FROM notices n WHERE position(? in to_jsonb(n)::text)>0",Integer.class,chosen));
        assertNotEquals(chosen,hash(target));
        jdbc.update("UPDATE users SET temp_password_expires_at=now()-interval '1 second' WHERE id=?::uuid",target.userId());
        assertEquals(401,loginResult(target.loginAccount(),chosen).getResponse().getStatus());
    }

    @ParameterizedTest @ValueSource(strings={"role","permission","session","version","stepup"})
    void queuedSuperAdministratorResetCannotUseRevokedIdentityOrCredentialAuthority(String changed) throws Exception {
        String root=adminToken();Employee actor=newEmployee(root,"DEPT_ENG"),target=newEmployee(root,"DEPT_ENG");
        promote(actor);promote(target);
        String admin=login(actor.loginAccount(),EMPLOYEE_PASSWORD).path("accessToken").asText(),token=stepUp(admin,EMPLOYEE_PASSWORD);
        String before=hash(target);
        try(var blocker=DriverManager.getConnection(fixtureDatabase.getJdbcUrl(),fixtureDatabase.getUsername(),fixtureDatabase.getPassword());
                var executor=Executors.newSingleThreadExecutor()) {
            blocker.setAutoCommit(false);
            try(var lock=blocker.prepareStatement("SELECT pg_advisory_xact_lock(?,?)")) {
                lock.setInt(1,AccountLifecycleCoordinator.LOCK_NAMESPACE);lock.setInt(2,AccountLifecycleCoordinator.LOCK_KEY);lock.execute();
            }
            var request=executor.submit(()->mvc.perform(json(post(endpoint(target,false)),Map.of("temporaryPassword","Queued-Secret-9"),admin)
                    .header(STEP_UP,token)).andReturn());
            try {
                org.awaitility.Awaitility.await().atMost(Duration.ofSeconds(15)).until(()->{
                    try(var query=blocker.prepareStatement("SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND classid=? AND objid=? AND NOT granted")) {
                        query.setInt(1,AccountLifecycleCoordinator.LOCK_NAMESPACE);query.setInt(2,AccountLifecycleCoordinator.LOCK_KEY);
                        try(var rows=query.executeQuery()){rows.next();return rows.getInt(1)>0;}
                    }
                });
                String revokeSql=switch(changed) {
                    case "permission" -> """
                        INSERT INTO user_permission_overrides(user_id,permission_id,effect,active,authority_source)
                        SELECT ?::uuid,id,'revoke',true,'SUPER_ADMIN_CONFIRMED' FROM permissions WHERE code='account:support'
                        ON CONFLICT(user_id,permission_id) DO UPDATE SET effect='revoke',active=true,authority_source='SUPER_ADMIN_CONFIRMED'
                        """;
                    case "session" -> "UPDATE auth_sessions SET revoked_at=now(),revoked_reason='logout',step_up_token_hash=NULL,step_up_expires_at=NULL WHERE user_id=?::uuid AND revoked_at IS NULL";
                    case "version" -> "UPDATE users SET auth_version=auth_version+1 WHERE id=?::uuid";
                    case "stepup" -> "UPDATE auth_sessions SET step_up_token_hash=NULL,step_up_expires_at=NULL WHERE user_id=?::uuid AND revoked_at IS NULL";
                    default -> "UPDATE users SET is_super_admin=false WHERE id=?::uuid";
                };
                try(var revoke=blocker.prepareStatement(revokeSql)) {
                    revoke.setString(1,actor.userId());assertEquals(1,revoke.executeUpdate());
                }
                blocker.commit();
            } finally {blocker.rollback();}
            var refused=request.get(30,TimeUnit.SECONDS);
            assertEquals(403,refused.getResponse().getStatus(),"Queued reset must reject revoked credential authority");
            assertEquals("stepup".equals(changed)?"REAUTH_REQUIRED":"FORBIDDEN",json(refused).path("code").asText());
            assertEquals(before,hash(target));
            assertEquals(0,jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE action='password_temporary_reset' AND target_id=?",
                    Integer.class,target.userId()));
        }
    }

    @Test
    void administratorResetRevokesAnotherAdministratorsAlreadyAdmittedQueuedReset() throws Exception {
        String root=adminToken();Employee actor=newEmployee(root,"DEPT_ENG"),target=newEmployee(root,"DEPT_ENG");
        promote(actor);promote(target);
        String admin=adminToken(),adminStepUp=stepUp(admin,ADMIN_PASSWORD);
        String actorToken=login(actor.loginAccount(),EMPLOYEE_PASSWORD).path("accessToken").asText();
        String actorStepUp=stepUp(actorToken,EMPLOYEE_PASSWORD),before=hash(target);
        try(var blocker=DriverManager.getConnection(fixtureDatabase.getJdbcUrl(),fixtureDatabase.getUsername(),fixtureDatabase.getPassword());
                var executor=Executors.newFixedThreadPool(2)) {
            blocker.setAutoCommit(false);
            try(var lock=blocker.prepareStatement("SELECT pg_advisory_xact_lock(?,?)")) {
                lock.setInt(1,AccountLifecycleCoordinator.LOCK_NAMESPACE);lock.setInt(2,AccountLifecycleCoordinator.LOCK_KEY);lock.execute();
            }
            var first=executor.submit(()->mvc.perform(json(post(endpoint(actor,false)),Map.of("temporaryPassword","Admin-Queued-First"),admin)
                    .header(STEP_UP,adminStepUp)).andReturn());
            java.util.concurrent.Future<MvcResult> second;
            try {
                awaitRegistryWaiters(blocker,1);
                second=executor.submit(()->mvc.perform(json(post(endpoint(target,true)),Map.of("temporaryPassword","Revoked-Queued-Second"),actorToken)
                        .header(STEP_UP,actorStepUp)).andReturn());
                awaitRegistryWaiters(blocker,2);
                blocker.commit();
            } finally {blocker.rollback();}
            var completed=first.get(30,TimeUnit.SECONDS);
            var refused=second.get(30,TimeUnit.SECONDS);
            assertEquals(200,completed.getResponse().getStatus(),body(completed));
            assertEquals(403,refused.getResponse().getStatus(),body(refused));
            assertEquals("FORBIDDEN",json(refused).path("code").asText());
            assertEquals(401,me(actorToken).getResponse().getStatus());
            assertEquals(before,hash(target));
            assertEquals(0,jdbc.queryForObject("SELECT count(*) FROM audit_log WHERE action='password_temporary_reset' AND target_id=?",
                    Integer.class,target.userId()));
        }
    }

    @ParameterizedTest @ValueSource(strings={"lock","unlock","disable","enable"})
    void routineAccountSupportStillNeedsNoStepUpButRejectsARevokedQueuedSession(String action) throws Exception {
        Employee target=newEmployee(adminToken(),"DEPT_ENG");
        String initial="unlock".equals(action)?"locked":"enable".equals(action)?"disabled":"active";
        jdbc.update("UPDATE users SET status=?,locked_until=NULL WHERE id=?::uuid",initial,target.userId());
        String admin=adminToken(); // Admit after the fixture's lifecycle/epoch mutation.
        String path="/api/admin/users/"+target.userId()+"/"+action;
        UUID actor=jdbc.queryForObject("SELECT id FROM users WHERE login_account=?",UUID.class,ADMIN_LOGIN);
        try(var blocker=DriverManager.getConnection(fixtureDatabase.getJdbcUrl(),fixtureDatabase.getUsername(),fixtureDatabase.getPassword());
                var executor=Executors.newSingleThreadExecutor()) {
            blocker.setAutoCommit(false);
            try(var lock=blocker.prepareStatement("SELECT id FROM employees WHERE id=?::uuid FOR UPDATE")) {
                lock.setString(1,target.employeeId());lock.execute();
            }
            var request=executor.submit(()->mvc.perform(json(post(path),Map.of(),admin)).andReturn());
            try {
                org.awaitility.Awaitility.await().atMost(Duration.ofSeconds(15)).until(()->{
                    if(request.isDone()) {
                        var premature=request.get();
                        fail("Routine request did not wait for its target lock: "+premature.getResponse().getStatus()+" "+body(premature));
                    }
                    try(var query=blocker.prepareStatement("SELECT EXISTS(SELECT 1 FROM pg_locks WHERE NOT granted AND pg_backend_pid()=ANY(pg_blocking_pids(pid)))");
                            var rows=query.executeQuery()) {rows.next();return rows.getBoolean(1);}
                });
                try(var revoke=blocker.prepareStatement("UPDATE auth_sessions SET revoked_at=now(),revoked_reason='logout',step_up_token_hash=NULL,step_up_expires_at=NULL WHERE user_id=? AND revoked_at IS NULL")) {
                    revoke.setObject(1,actor);assertEquals(1,revoke.executeUpdate());
                }
                blocker.commit();
            } finally {blocker.rollback();}
            var refused=request.get(30,TimeUnit.SECONDS);
            assertEquals(403,refused.getResponse().getStatus(),body(refused));
            assertEquals(initial,jdbc.queryForObject("SELECT status FROM users WHERE id=?::uuid",String.class,target.userId()));
        }
        // A new valid session performs the same routine action without step-up.
        var accepted=mvc.perform(json(post(path),Map.of(),adminToken())).andReturn();
        assertEquals(200,accepted.getResponse().getStatus(),body(accepted));
    }

    private void awaitRegistryWaiters(java.sql.Connection connection,int minimum) {
        org.awaitility.Awaitility.await().atMost(Duration.ofSeconds(15)).until(()->{
            try(var query=connection.prepareStatement("SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND classid=? AND objid=? AND NOT granted")) {
                query.setInt(1,AccountLifecycleCoordinator.LOCK_NAMESPACE);query.setInt(2,AccountLifecycleCoordinator.LOCK_KEY);
                try(var rows=query.executeQuery()){rows.next();return rows.getInt(1)>=minimum;}
            }
        });
    }

    private void promote(Employee employee) throws Exception {
        String admin=adminToken();
        var response=mvc.perform(json(put("/api/admin/users/"+employee.userId()+"/super-admin"),Map.of("superAdmin",true),admin)
                .header(STEP_UP,stepUp(admin,ADMIN_PASSWORD))).andReturn();
        assertEquals(200,response.getResponse().getStatus(),body(response));
        promotedUsers.add(employee.userId());
    }
    private MvcResult reset(String endpoint,String token,String actorPassword,Object body) throws Exception {
        return mvc.perform(json(post(endpoint),body,token).header(STEP_UP,stepUp(token,actorPassword))).andReturn();
    }
    private static String endpoint(Employee target,boolean employeeEntry) {
        return employeeEntry?"/api/org/employees/"+target.employeeId()+"/account/reset-password"
                :"/api/admin/users/"+target.userId()+"/reset-password";
    }
    private String hash(Employee employee) {
        return jdbc.queryForObject("SELECT password_hash FROM users WHERE id=?::uuid",String.class,employee.userId());
    }
}
