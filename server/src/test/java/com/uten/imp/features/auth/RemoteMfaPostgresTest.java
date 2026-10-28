package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.CryptoProperties;
import com.uten.imp.config.props.JwtProperties;
import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.auth.model.RefreshTokenRepository;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.security.*;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.transaction.support.TransactionTemplate;

import java.time.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

/** Real migrated PostgreSQL: encryption, serialization, durable failure counters and session binding. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class RemoteMfaPostgresTest {
    MigratedSchemaBaseline.ScopedDatabase database;
    JdbcTemplate jdbc;
    NamedParameterJdbcTemplate named;
    AuthSessionService sessions;
    RemoteMfaService mfa;
    TransactionTemplate transaction;
    MutableClock clock;
    RemoteAccessPolicy access;
    RefreshTokenRepository refresh;
    UserAccountRepository users;
    AuthUser principal;

    @BeforeEach void setup() throws Exception {
        database=MigratedSchemaBaseline.openDatabase("auth_remote_mfa");
        var ds=new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword());
        jdbc=new JdbcTemplate(ds);
        named=spy(new NamedParameterJdbcTemplate(ds));
        var manager=new DataSourceTransactionManager(ds);
        transaction=new TransactionTemplate(manager);
        clock=new MutableClock(Instant.parse("2026-10-17T12:00:00Z"));
        SystemSettingsService settings=mock(SystemSettingsService.class);
        when(settings.readLong(SystemSettingKey.JWT_REFRESH_TTL_DAYS)).thenReturn(7L);
        when(settings.readInt(SystemSettingKey.SESSION_IDLE_TIMEOUT_MINUTES)).thenReturn(60);
        sessions=new AuthSessionService(named,settings,clock);
        access=mock(RemoteAccessPolicy.class);
        refresh=mock(RefreshTokenRepository.class);
        when(refresh.revokeAllByUserId(any())).thenAnswer(inv->jdbc.update(
                "UPDATE refresh_tokens SET revoked_at=now() WHERE user_id=? AND revoked_at IS NULL",(Object)inv.getArgument(0)));
        users=mock(UserAccountRepository.class);
        when(users.existsAuthenticatableEmployee(any(),org.mockito.ArgumentMatchers.anyCollection())).thenAnswer(inv->jdbc.query(
                "SELECT status,is_deleted FROM employees WHERE id=?",
                (rs,n)->!rs.getBoolean("is_deleted") && inv.<java.util.Collection<String>>getArgument(1).contains(rs.getString("status")),
                (Object)inv.getArgument(0)).stream().anyMatch(Boolean.TRUE::equals));
        when(users.findByIdForUpdate(any())).thenAnswer(inv->jdbc.query(
                "SELECT id,employee_id,login_account,status,is_deleted,remote_access,must_change_password,is_super_admin,temp_password_expires_at FROM users WHERE id=? FOR UPDATE",
                (rs,n)->{
                    UserAccount u=new UserAccount();u.setId(rs.getObject("id",UUID.class));
                    u.setEmployeeId(rs.getObject("employee_id",UUID.class));u.setLoginAccount(rs.getString("login_account"));
                    u.setStatus(rs.getString("status"));u.setDeleted(rs.getBoolean("is_deleted"));
                    u.setRemoteAccess(rs.getBoolean("remote_access"));u.setMustChangePassword(rs.getBoolean("must_change_password"));
                    u.setTempPasswordExpiresAt(rs.getObject("temp_password_expires_at",OffsetDateTime.class));
                    u.setSuperAdmin(rs.getBoolean("is_super_admin"));return u;
                },(Object)inv.getArgument(0)).stream().findFirst());
        SecretCipherProperties cipherProperties=new SecretCipherProperties();
        cipherProperties.setSecretCipherKey("mfa-test-only-encryption-material-32-bytes");
        JwtProperties jwt=new JwtProperties();jwt.setIssuer("mfa-integration-test");
        mfa=new RemoteMfaService(named,users,refresh,sessions,new SecretCipher(cipherProperties,new CryptoProperties(),jwt),
                access,new SecurityContextCurrentUser(),mock(AuditService.class),manager);
        principal=newUser(false);
        authenticate(principal);
    }

    @AfterEach void close() throws Exception { SecurityContextHolder.clearContext();if(database!=null)database.close(); }

    @Test void statusReadsAbsentAndPendingFactorsInsideAReadOnlyTransactionWithoutInitializingState() {
        var readOnly = new TransactionTemplate(transaction.getTransactionManager());
        readOnly.setReadOnly(true);
        var absent = readOnly.execute(status -> mfa.status());
        assertThat(absent).isNotNull();
        assertThat(absent.enabled()).isFalse();
        assertThat(absent.pending()).isFalse();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM staff_mfa WHERE user_id=?", Integer.class,
                principal.getId())).isZero();

        mfa.beginEnrollment();
        var pending = readOnly.execute(status -> mfa.status());
        assertThat(pending).isNotNull();
        assertThat(pending.enabled()).isFalse();
        assertThat(pending.pending()).isTrue();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM staff_mfa WHERE user_id=?", Integer.class,
                principal.getId())).isEqualTo(1);
    }

    @Test void enrollmentEncryptsSecretsBindsPendingToSessionAndConsumesConfirmationStep() {
        var enrollment=mfa.beginEnrollment();
        String pending=jdbc.queryForObject("SELECT pending_secret_ciphertext FROM staff_mfa WHERE user_id=?",String.class,principal.getId());
        assertThat(pending).startsWith("g1:").doesNotContain(enrollment.secret());
        assertThat(enrollment.otpauthUri()).contains("digits=6&period=30");
        assertThat(mfa.status().enabled()).isFalse();
        assertThat(mfa.status().pending()).isTrue();
        assertThat(mfa.confirmEnrollment(code(enrollment.secret())).enabled()).isTrue();
        assertThat(mfa.status().sessionVerified()).isTrue();
        assertError(()->mfa.verifySession(code(enrollment.secret())),ErrorCode.MFA_INVALID);
        assertThat(jdbc.queryForObject("SELECT pending_secret_ciphertext FROM staff_mfa WHERE user_id=?",String.class,principal.getId())).isNull();
        assertThat(jdbc.queryForObject("SELECT secret_ciphertext FROM staff_mfa WHERE user_id=?",String.class,principal.getId())).doesNotContain(enrollment.secret());
        clock.advance(Duration.ofSeconds(30));
        assertThat(mfa.verifySession(code(enrollment.secret())).verifiedUntil()).isEqualTo(clock.instant().plus(Duration.ofHours(8)));
    }

    @Test void pendingExpiresAndCannotBeConfirmedFromAnotherSession() {
        var enrollment=mfa.beginEnrollment();
        var replacement=transaction.execute(s->sessions.openStaffSession(principal.getId(),null));
        principal=withSession(principal,replacement.sid());authenticate(principal);
        assertError(()->mfa.confirmEnrollment(code(enrollment.secret())),ErrorCode.MFA_ENROLLMENT_EXPIRED);
        var next=mfa.beginEnrollment();
        clock.advance(Duration.ofMinutes(11));
        assertError(()->mfa.confirmEnrollment(code(next.secret())),ErrorCode.MFA_ENROLLMENT_EXPIRED);
        assertThat(mfa.status().enabled()).isFalse();
    }

    @Test void failedOtpCountersCommitAcrossErrorsAndEnrollmentCannotBypassLock() {
        mfa.beginEnrollment();
        for(int i=0;i<4;i++) assertError(()->mfa.confirmEnrollment("invalid"),ErrorCode.MFA_INVALID);
        assertError(()->mfa.confirmEnrollment("invalid"),ErrorCode.MFA_LOCKED);
        assertThat(jdbc.queryForObject("SELECT failed_attempts FROM staff_mfa WHERE user_id=?",Integer.class,principal.getId())).isEqualTo(5);
        assertError(mfa::beginEnrollment,ErrorCode.MFA_LOCKED);
        clock.advance(Duration.ofMinutes(16));
        var fresh=mfa.beginEnrollment();
        assertThat(mfa.confirmEnrollment(code(fresh.secret())).enabled()).isTrue();
        assertThat(jdbc.queryForObject("SELECT failed_attempts FROM staff_mfa WHERE user_id=?",Integer.class,principal.getId())).isZero();
    }

    @Test void concurrentReplayCanIssueOnlyOneRemoteSession() throws Exception {
        var enrollment=enroll();clock.advance(Duration.ofSeconds(30));
        String otp=code(enrollment.secret());
        AtomicInteger issued=new AtomicInteger();
        CountDownLatch start=new CountDownLatch(1);
        try(var pool=Executors.newFixedThreadPool(2)) {
            Callable<ErrorCode> attempt=()->{start.await();try{
                mfa.remoteLogin(principal.getId(),otp,()->{issued.incrementAndGet();return null;});return null;
            }catch(ApiException ex){return ex.getCode();}};
            var first=pool.submit(attempt);var second=pool.submit(attempt);start.countDown();
            List<ErrorCode> results=Arrays.asList(first.get(10,TimeUnit.SECONDS),second.get(10,TimeUnit.SECONDS));
            assertThat(results).containsExactlyInAnyOrder(null,ErrorCode.MFA_INVALID);
            assertThat(issued).hasValue(1);
        }
    }

    @Test void tokenIssuanceRollbackDoesNotConsumeFactorAndResetRevokesEverySession() {
        var enrollment=enroll();clock.advance(Duration.ofSeconds(30));
        String otp=code(enrollment.secret());
        assertThatThrownBy(()->mfa.remoteLogin(principal.getId(),otp,()->{throw new IllegalStateException("issuance unavailable");}))
                .isInstanceOf(IllegalStateException.class);
        assertThat(mfa.verifySession(otp).verifiedUntil()).isNotNull();
        UUID target=principal.getId();UUID oldSession=principal.getSessionId();
        AuthUser admin=newUser(true);authenticate(admin);
        assertThat(mfa.reset(target,"Employee verified in person").reauthenticationRequired()).isTrue();
        assertThat(jdbc.queryForObject("SELECT enabled_at FROM staff_mfa WHERE user_id=?",OffsetDateTime.class,target)).isNull();
        assertThat(jdbc.queryForObject("SELECT revoked_at IS NOT NULL AND mfa_verified_at IS NULL FROM auth_sessions WHERE sid=?",Boolean.class,oldSession)).isTrue();
        verify(refresh).revokeAllByUserId(target);
        assertError(()->mfa.remoteLogin(target,otp,()->null),ErrorCode.MFA_ENROLLMENT_REQUIRED);
    }

    @Test void lanOnlyManagementCannotBeInvokedRemotelyAndDisableRevokesCurrentSession() {
        var enrollment=enroll();clock.advance(Duration.ofSeconds(30));
        when(access.isRemoteRequest()).thenReturn(true);
        assertError(mfa::beginEnrollment,ErrorCode.FORBIDDEN);
        assertError(()->mfa.confirmEnrollment(code(enrollment.secret())),ErrorCode.FORBIDDEN);
        assertError(()->mfa.disable(code(enrollment.secret())),ErrorCode.FORBIDDEN);
        when(access.isRemoteRequest()).thenReturn(false);
        assertThat(mfa.disable(code(enrollment.secret())).reauthenticationRequired()).isTrue();
        assertError(()->sessions.requireMfaForRefresh(principal.getSessionId(),principal.getId()),ErrorCode.MFA_REQUIRED);
    }

    @Test void sessionProofDoesNotAuthorizeDifferentSessionAndExpiresWithoutRefreshExtension() {
        var enrollment=enroll();
        assertThat(sessions.loadStaff(principal.getId(),principal.getSessionId(),principal.getId()).orElseThrow().session().mfaVerifiedAt()).isEqualTo(clock.instant());
        sessions.requireMfaForRefresh(principal.getSessionId(),principal.getId());
        var replacement=transaction.execute(s->sessions.openStaffSession(principal.getId(),null));
        assertError(()->sessions.requireMfaForRefresh(replacement.sid(),principal.getId()),ErrorCode.MFA_REQUIRED);
        principal=withSession(principal,replacement.sid());authenticate(principal);clock.advance(Duration.ofSeconds(30));
        mfa.verifySession(code(enrollment.secret()));clock.advance(Duration.ofHours(8));
        assertError(()->sessions.requireMfaForRefresh(replacement.sid(),principal.getId()),ErrorCode.MFA_REQUIRED);
    }

    @Test void ordinaryAuthenticationReadsMfaAndGlobalPolicyInOneSql() {
        enroll();
        clearInvocations(named);
        var state=sessions.loadStaff(principal.getId(),principal.getSessionId(),principal.getId()).orElseThrow();
        assertThat(state.session().mfaVerifiedAt()).isEqualTo(clock.instant());
        assertThat(state.remotePolicyEnabled()).isFalse();
        var sql=org.mockito.ArgumentCaptor.forClass(String.class);
        verify(named,times(1)).query(sql.capture(),any(org.springframework.jdbc.core.namedparam.SqlParameterSource.class),
                org.mockito.ArgumentMatchers.<org.springframework.jdbc.core.RowMapper<AuthSessionService.StaffState>>any());
        assertThat(sql.getValue()).contains("sess.mfa_verified_at","rap.enabled AS remote_policy_enabled","CROSS JOIN remote_access_policy rap");
    }

    @Test void passwordChangeCanPreserveOnlyFreshDatabaseProofAndResetCannotResurrectIt() {
        enroll();
        UUID target=principal.getId(),oldSession=principal.getSessionId();
        transaction.executeWithoutResult(s->sessions.revoke(oldSession,AuthSessionService.REASON_PASSWORD_CHANGED));
        assertThat(sessions.mfaAfterPasswordChange(oldSession,target)).isEqualTo(clock.instant());
        authenticate(newUser(true));
        mfa.reset(target,"Employee factor lost");
        assertThat(sessions.mfaAfterPasswordChange(oldSession,target)).isNull();
    }

    @Test void demotedAdministratorCannotResetUsingAnEarlierPrincipalSnapshot() {
        enroll();UUID target=principal.getId();AuthUser admin=newUser(true);authenticate(admin);
        jdbc.update("UPDATE users SET is_super_admin=false WHERE id=?",admin.getId());
        assertError(()->mfa.reset(target,"Stale authority"),ErrorCode.FORBIDDEN);
        assertThat(jdbc.queryForObject("SELECT enabled_at IS NOT NULL FROM staff_mfa WHERE user_id=?",Boolean.class,target)).isTrue();
    }

    @Test void aDepartedAdministratorCannotResetFactorsUsingAnEarlierPrincipalSnapshot() {
        enroll();UUID target=principal.getId();AuthUser admin=newUser(true);authenticate(admin);
        jdbc.update("UPDATE employees SET status='resigned' WHERE id=?",admin.getEmployeeId());
        assertError(()->mfa.reset(target,"Stale employee identity"),ErrorCode.FORBIDDEN);
        assertThat(jdbc.queryForObject("SELECT enabled_at IS NOT NULL FROM staff_mfa WHERE user_id=?",Boolean.class,target)).isTrue();
    }

    @Test void aTemporaryCredentialExpiringAfterTheRequestPrincipalWasReadCannotBeginEnrollment() {
        jdbc.update("UPDATE users SET must_change_password=true,temp_password_expires_at=now()-interval '1 second' WHERE id=?",principal.getId());
        assertError(mfa::beginEnrollment,ErrorCode.UNAUTHORIZED);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM staff_mfa WHERE user_id=?",Integer.class,principal.getId())).isZero();
    }

    @Test void sessionRevocationPreservesFactorsAndPolicyButNeverRevivesOldActiveOrPendingSessions() {
        var activeEnrollment=enroll();
        AuthUser active=principal;
        String encrypted=jdbc.queryForObject("SELECT secret_ciphertext FROM staff_mfa WHERE user_id=?",String.class,active.getId());
        AuthUser pendingUser=newUser(false);authenticate(pendingUser);
        var pendingEnrollment=mfa.beginEnrollment();
        jdbc.update("UPDATE remote_access_policy SET enabled=true,version=version+1 WHERE singleton_id=1");
        var policy=jdbc.queryForMap("SELECT enabled,max_users,version FROM remote_access_policy WHERE singleton_id=1");

        transaction.executeWithoutResult(s->jdbc.update("DELETE FROM auth_sessions"));

        assertThat(jdbc.queryForObject("SELECT count(*) FROM auth_sessions",Long.class)).isZero();
        assertThat(jdbc.queryForObject("SELECT secret_ciphertext FROM staff_mfa WHERE user_id=?",String.class,active.getId())).isEqualTo(encrypted);
        assertThat(jdbc.queryForMap("SELECT enabled,max_users,version FROM remote_access_policy WHERE singleton_id=1")).isEqualTo(policy);
        authenticate(active);
        assertError(()->mfa.verifySession(code(activeEnrollment.secret())),ErrorCode.UNAUTHORIZED);
        assertThat(sessions.mfaAfterPasswordChange(active.getSessionId(),active.getId())).isNull();
        authenticate(pendingUser);
        assertError(()->mfa.confirmEnrollment(code(pendingEnrollment.secret())),ErrorCode.UNAUTHORIZED);

        var activeReplacement=transaction.execute(s->sessions.openStaffSession(active.getId(),null));
        authenticate(withSession(active,activeReplacement.sid()));
        assertThat(mfa.status().enabled()).isTrue();
        assertThat(mfa.status().sessionVerified()).isFalse();
        assertError(()->sessions.requireMfaForRefresh(activeReplacement.sid(),active.getId()),ErrorCode.MFA_REQUIRED);
        clock.advance(Duration.ofSeconds(60));
        assertThat(mfa.verifySession(code(activeEnrollment.secret())).verifiedUntil()).isNotNull();

        var pendingReplacement=transaction.execute(s->sessions.openStaffSession(pendingUser.getId(),null));
        authenticate(withSession(pendingUser,pendingReplacement.sid()));
        assertError(()->mfa.confirmEnrollment(code(pendingEnrollment.secret())),ErrorCode.MFA_ENROLLMENT_EXPIRED);
        var restarted=mfa.beginEnrollment();
        assertThat(mfa.confirmEnrollment(code(restarted.secret())).enabled()).isTrue();
    }

    @Test void concurrentAdminResetSerializesWithFactorConsumptionAndRevokesNewlyIssuedSession() throws Exception {
        var enrollment=enroll();clock.advance(Duration.ofSeconds(30));
        UUID target=principal.getId();String otp=code(enrollment.secret());
        AuthUser admin=newUser(true);
        CountDownLatch issued=new CountDownLatch(1),finishIssue=new CountDownLatch(1);
        AtomicReference<UUID> newSession=new AtomicReference<>();
        try(var pool=Executors.newFixedThreadPool(2)) {
            var login=pool.submit(()->mfa.remoteLogin(target,otp,()->{
                var session=sessions.openStaffSession(target,null);
                sessions.markMfaVerified(session.sid(),target,clock.instant());
                newSession.set(session.sid());issued.countDown();
                try { if(!finishIssue.await(10,TimeUnit.SECONDS))throw new IllegalStateException("Test issuance timed out"); }
                catch(InterruptedException e){Thread.currentThread().interrupt();throw new IllegalStateException(e);}
                return null;
            }));
            assertThat(issued.await(10,TimeUnit.SECONDS)).isTrue();
            var reset=pool.submit(()->{authenticate(admin);try{return mfa.reset(target,"Identity checked after device loss");}
                finally {SecurityContextHolder.clearContext();}});
            try { assertThatThrownBy(()->reset.get(150,TimeUnit.MILLISECONDS)).isInstanceOf(TimeoutException.class); }
            finally { finishIssue.countDown(); }
            login.get(10,TimeUnit.SECONDS);reset.get(10,TimeUnit.SECONDS);
            assertThat(jdbc.queryForObject("SELECT revoked_at IS NOT NULL AND mfa_verified_at IS NULL FROM auth_sessions WHERE sid=?",
                    Boolean.class,newSession.get())).isTrue();
            assertThat(jdbc.queryForObject("SELECT enabled_at FROM staff_mfa WHERE user_id=?",OffsetDateTime.class,target)).isNull();
        } finally {finishIssue.countDown();}
    }

    private RemoteMfaService.Enrollment enroll(){var e=mfa.beginEnrollment();mfa.confirmEnrollment(code(e.secret()));return e;}
    private String code(String secret){return Totp.code(secret,clock.instant().getEpochSecond()/30,6);}
    private AuthUser newUser(boolean admin) {
        UUID employee=UUID.randomUUID(),id=UUID.randomUUID();String label=UUID.randomUUID().toString();
        jdbc.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                SELECT ?,?,?,'其他',id,CURRENT_DATE,'active','regular' FROM departments WHERE code='DEPT_FIN'
                """,employee,"MFA-"+label,com.uten.imp.support.SyntheticEmployeeIdentity.name("MFA测试",employee));
        jdbc.update("""
                INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status,is_super_admin,remote_access)
                VALUES(?,?,?,'test-only',false,'active',?,true)
                """,id,employee,"mfa-"+label,admin);
        var session=transaction.execute(s->sessions.openStaffSession(id,null));
        return new AuthUser(id,employee,"mfa-"+label,admin?Set.of("authorization:manage"):Set.of(),false,true,admin,true,null,session.sid());
    }
    private static AuthUser withSession(AuthUser user,UUID sid){return new AuthUser(user.getId(),user.getEmployeeId(),user.getLoginAccount(),user.getPermissions(),false,true,user.isSuperAdmin(),true,null,sid);}
    private static void authenticate(AuthUser user){SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,null,user.getAuthorities()));}
    private static void assertError(org.assertj.core.api.ThrowableAssert.ThrowingCallable action,ErrorCode expected){
        assertThatThrownBy(action).isInstanceOfSatisfying(ApiException.class,ex->assertThat(ex.getCode()).isEqualTo(expected));
    }
    static final class MutableClock extends Clock {
        private volatile Instant value;
        MutableClock(Instant value){this.value=value;}
        void advance(Duration duration){value=value.plus(duration);}
        @Override public ZoneId getZone(){return ZoneOffset.UTC;}
        @Override public Clock withZone(ZoneId zone){return this;}
        @Override public Instant instant(){return value;}
    }
}
