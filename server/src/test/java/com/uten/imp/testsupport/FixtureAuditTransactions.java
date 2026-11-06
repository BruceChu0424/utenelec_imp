package com.uten.imp.testsupport;

import com.uten.imp.audit.AuditDeviceContext;
import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.finance.BusinessPrecisionTransactionBinder;
import com.uten.imp.config.Jackson2ObjectMapperAutoConfiguration;
import com.uten.imp.config.props.CryptoProperties;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TransactionAuditActorBinder;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.SQLException;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.WeakHashMap;
import javax.sql.DataSource;
import org.springframework.beans.factory.support.StaticListableBeanFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.support.AbstractPlatformTransactionManager;

/** Production audit/precision binding for fixtures which construct their own transactions. */
public final class FixtureAuditTransactions {
    private static final Map<Connection,UUID> JDBC_ACTORS=new WeakHashMap<>();
    private FixtureAuditTransactions() { }

    public static UUID employee(UUID actor) {
        return UUID.nameUUIDFromBytes(("fixture-audit-employee:"+actor).getBytes(StandardCharsets.UTF_8));
    }

    public static String account(UUID actor) { return "fixture-audit-"+actor; }

    public static TxSessionVars session(EntityManager em,SecurityContextCurrentUser current) {
        var vars=new TxSessionVars(new CryptoProperties(),current,
                new AuditDeviceContext(Jackson2ObjectMapperAutoConfiguration.domainObjectMapper()));
        ReflectionTestUtils.setField(vars,"em",em);
        return vars;
    }

    public static void install(AbstractPlatformTransactionManager manager,TxSessionVars vars) {
        var beans=new StaticListableBeanFactory(Map.of("fixtureSessionVars",vars));
        var provider=beans.getBeanProvider(TxSessionVars.class);
        manager.addListener(new TransactionAuditActorBinder(provider));
        manager.addListener(new BusinessPrecisionTransactionBinder(provider));
    }

    /** The existing fixture principal retains its permissions and super-admin flag. */
    public static void ensureIdentity(DataSource source,AuthUser principal) {
        ensureIdentity(new JdbcTemplate(source),principal);
    }

    private static void ensureIdentity(JdbcTemplate db,AuthUser principal) {
        UUID actor=principal.getId(),employee=principal.getEmployeeId();
        if(actor==null||employee==null||principal.isVisitor())throw new IllegalArgumentException("Fixture needs its actual staff principal");
        var identities=db.queryForList("SELECT employee_id FROM users WHERE id=?",UUID.class,actor);
        if(identities.isEmpty()) {
            UUID department=db.queryForObject("SELECT id FROM departments WHERE NOT is_deleted ORDER BY code LIMIT 1",UUID.class);
            db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',?,CURRENT_DATE,'active','regular')",
                    employee,"FTA-"+employee,com.uten.imp.support.SyntheticEmployeeIdentity.name("Audit fixture",employee),department);
            db.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,is_super_admin,status) VALUES(?,?,?,'test-only-hash',false,?,'active')",
                    actor,employee,principal.getLoginAccount(),principal.isSuperAdmin());
        } else {
            if(identities.size()!=1||!employee.equals(identities.getFirst()))throw new IllegalStateException("Fixture actor identity changed");
            db.update("UPDATE users SET is_super_admin=? WHERE id=? AND is_super_admin IS DISTINCT FROM ?",principal.isSuperAdmin(),actor,principal.isSuperAdmin());
        }
        if(!Boolean.TRUE.equals(db.queryForObject("SELECT EXISTS(SELECT 1 FROM users u JOIN employees e ON e.id=u.employee_id WHERE u.id=? AND e.id=? AND NOT u.is_deleted AND u.status='active' AND NOT e.is_deleted AND e.status='active')",Boolean.class,actor,employee)))
            throw new IllegalStateException("Fixture actor is not an actual active staff identity");
    }

    /** Raw JDBC fixtures own their explicit transaction; bind the same production
     * session on that exact connection, without an ORM factory or session GUC. */
    public static void bindJdbc(Connection connection) throws SQLException {
        UUID actor;
        synchronized(JDBC_ACTORS) { actor=JDBC_ACTORS.computeIfAbsent(connection,ignored->UUID.randomUUID()); }
        bindJdbc(connection,actor);
    }

    public static void bindJdbc(Connection connection,UUID actor) throws SQLException {
        if(connection.getAutoCommit())throw new IllegalStateException("Fixture audit binding requires its explicit transaction");
        var source=new SingleConnectionDataSource(connection,true);
        var db=new JdbcTemplate(source);
        var principal=new AuthUser(actor,employee(actor),account(actor),Set.of(),false,true,false);
        ensureIdentity(db,principal);
        var current=new SecurityContextCurrentUser(){@Override public Optional<AuthUser> get(){return Optional.of(principal);}};
        var vars=session(HistoricalJdbcNativeSql.statements(db),current);
        vars.bind();
        if(!BusinessPrecisionContext.choices().isEmpty())vars.bindBusinessPrecision(BusinessPrecisionContext.json());
    }

    /** Keep JDBC auto-commit's one-statement boundary, binding LOCAL audit first. */
    public static int executeUpdate(Connection connection,String sql,Object... parameters)throws SQLException {
        boolean owns=connection.getAutoCommit();
        if(owns)connection.setAutoCommit(false);
        try {
            if(owns)bindJdbc(connection);
            int changed;
            try(var statement=connection.prepareStatement(sql)) {
                for(int index=0;index<parameters.length;index++)statement.setObject(index+1,parameters[index]);
                changed=statement.executeUpdate();
            }
            if(owns)connection.commit();
            return changed;
        } catch(SQLException|RuntimeException|Error failure) {
            if(owns)try{connection.rollback();}catch(SQLException cleanup){failure.addSuppressed(cleanup);}
            throw failure;
        } finally {
            if(owns)connection.setAutoCommit(true);
        }
    }
}
