package com.uten.imp.features.auth;

import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.config.props.DeploymentProperties;
import com.uten.imp.features.admin.systemsetting.*;
import com.uten.imp.features.auth.dto.LoginRequest;
import com.uten.imp.features.auth.model.*;
import com.uten.imp.security.*;
import com.uten.imp.support.MigratedSchemaBaseline;
import java.time.OffsetDateTime;
import java.util.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.aop.framework.ProxyFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.*;
import org.springframework.transaction.annotation.AnnotationTransactionAttributeSource;
import org.springframework.transaction.interceptor.TransactionInterceptor;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Real V322 state-generation triggers and a real independent failure-recording transaction. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class StaffAuthenticationGenerationPostgresTest {
    @Test void anAdminLockUnlockKeepsThePasswordButInvalidatesAConcurrentFailureSnapshot() throws Exception {
        try(var database=MigratedSchemaBaseline.openDatabase("staff_failure_generation")) {
            var ds=new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword());
            var jdbc=new JdbcTemplate(ds);UUID employee=UUID.randomUUID(),userId=UUID.randomUUID();
            String login="generation-"+userId;
            jdbc.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) SELECT ?,?,'代际测试','其他',id,current_date,'active','regular' FROM departments WHERE code='DEPT_FIN'",
                    employee,"GEN-"+employee.toString().substring(0,12));
            jdbc.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status,is_super_admin) VALUES(?,?,?,'fixture-credential',false,'active',false)",userId,employee,login);
            var users=mock(UserAccountRepository.class);
            java.util.function.Supplier<UserAccount> read=()->jdbc.queryForObject("SELECT * FROM users WHERE id=? FOR UPDATE",(rs,n)->{
                var u=new UserAccount();u.setId(rs.getObject("id",UUID.class));u.setEmployeeId(rs.getObject("employee_id",UUID.class));
                u.setLoginAccount(rs.getString("login_account"));u.setPasswordHash(rs.getString("password_hash"));u.setStatus(rs.getString("status"));
                u.setDeleted(rs.getBoolean("is_deleted"));u.setAuthVersion(rs.getLong("auth_version"));u.setFailedAttempts(rs.getInt("failed_attempts"));
                u.setLockedUntil(rs.getObject("locked_until",OffsetDateTime.class));u.setMustChangePassword(rs.getBoolean("must_change_password"));return u;
            },userId);
            UserAccount observed=read.get();
            when(users.findByLoginAccount(login)).thenReturn(Optional.of(observed));
            when(users.existsAuthenticatableEmployee(any(),anyCollection())).thenReturn(true);
            when(users.findByIdForUpdate(userId)).thenAnswer(call->Optional.of(read.get()));
            when(users.save(any(UserAccount.class))).thenAnswer(call->{UserAccount u=call.getArgument(0);
                jdbc.update("UPDATE users SET failed_attempts=?,status=?,locked_until=? WHERE id=?",u.getFailedAttempts(),u.getStatus(),u.getLockedUntil(),u.getId());return u;});
            var settings=mock(SystemSettingsService.class);
            when(settings.readInt(SystemSettingKey.LOCKOUT_THRESHOLD)).thenReturn(1);
            when(settings.readInt(SystemSettingKey.LOCKOUT_MINUTES)).thenReturn(15);
            var audit=mock(AuditService.class);
            var target=new LoginFailureRecorder(users,settings,audit,mock(TxSessionVars.class));
            var proxy=new ProxyFactory(target);
            proxy.addAdvice(new TransactionInterceptor(new DataSourceTransactionManager(ds),new AnnotationTransactionAttributeSource()));
            var recorder=(LoginFailureRecorder)proxy.getProxy();
            var passwords=mock(org.springframework.security.crypto.password.PasswordEncoder.class);
            when(passwords.encode(anyString())).thenReturn("dummy-fixture");
            when(passwords.matches("wrong-attempt","fixture-credential")).thenAnswer(call->{
                jdbc.update("UPDATE users SET status='locked',locked_until=NULL WHERE id=?",userId);
                jdbc.update("UPDATE users SET status='active',locked_until=NULL,failed_attempts=0 WHERE id=?",userId);
                return false;
            });
            var deployment=new DeploymentProperties();deployment.setSite("local");
            var service=new LoginService(users,passwords,mock(LoginRateLimiter.class),audit,recorder,
                    new RemoteAccessPolicy(deployment),mock(StaffLoginTransaction.class));
            assertEquals(ErrorCode.BAD_CREDENTIALS,assertThrows(ApiException.class,
                    ()->service.login(new LoginRequest(login,"wrong-attempt"),"192.0.2.1")).getCode());
            assertTrue(jdbc.queryForObject("SELECT auth_version>? FROM users WHERE id=?",Boolean.class,observed.getAuthVersion(),userId),
                    "Real administrative state transitions must advance the observation generation");
            assertTrue(jdbc.queryForObject("SELECT password_hash=? FROM users WHERE id=?",Boolean.class,observed.getPasswordHash(),userId),
                    "This race must retain exactly the same password");
            assertEquals(0,jdbc.queryForObject("SELECT failed_attempts FROM users WHERE id=?",Integer.class,userId));
            assertEquals("active",jdbc.queryForObject("SELECT status FROM users WHERE id=?",String.class,userId));
        }
    }
}
