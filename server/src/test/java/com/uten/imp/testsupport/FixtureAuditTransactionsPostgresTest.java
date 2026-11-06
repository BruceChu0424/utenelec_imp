package com.uten.imp.testsupport;

import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.support.MigratedSchemaBaseline;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionTemplate;
import static org.assertj.core.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class FixtureAuditTransactionsPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private static DriverManagerDataSource source;
    @BeforeAll static void open()throws Exception {
        database=MigratedSchemaBaseline.openDatabase("fixture_audit_transactions");
        source=new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword());
    }
    @AfterAll static void close()throws Exception {if(database!=null)database.close();}

    @Test void productionListenersBindTheExistingStaffAndDoNotCarryItsIdentityAcrossTransactions() {
        UUID id=UUID.randomUUID();Set<String> permissions=Set.of("goods:view");
        var principal=new AuthUser(id,FixtureAuditTransactions.employee(id),FixtureAuditTransactions.account(id),permissions,false,true,false);
        FixtureAuditTransactions.ensureIdentity(source,principal);
        var current=new SecurityContextCurrentUser(){@Override public Optional<AuthUser> get(){return Optional.of(principal);}};
        var db=new JdbcTemplate(source);var manager=new DataSourceTransactionManager(source);
        FixtureAuditTransactions.install(manager,FixtureAuditTransactions.session(HistoricalJdbcNativeSql.statements(db),current));
        var tx=new TransactionTemplate(manager);
        UUID bound=tx.execute(status->db.queryForObject("SELECT current_setting('app.actor_id')::uuid",UUID.class));
        assertThat(bound).isEqualTo(id);
        assertThat(principal.getPermissions()).containsExactlyInAnyOrderElementsOf(permissions);
        assertThat(db.queryForObject("SELECT NULLIF(current_setting('app.actor_id',true),'')",String.class)).isNull();
        assertThatThrownBy(()->tx.executeWithoutResult(status->{
            assertThat(db.queryForObject("SELECT current_setting('app.actor_id')::uuid",UUID.class)).isEqualTo(id);
            throw new IllegalStateException("rollback fixture");
        })).hasMessage("rollback fixture");
        assertThat(db.queryForObject("SELECT NULLIF(current_setting('app.actor_id',true),'')",String.class)).isNull();
    }

    @Test void manualJdbcBindsOnlyWithinItsRealTransactionAndRetainsExplicitActorSwitches()throws Exception {
        try(var connection=database.openConnection()) {
            UUID first=UUID.randomUUID(),second=UUID.randomUUID();
            assertThatThrownBy(()->FixtureAuditTransactions.bindJdbc(connection,first)).isInstanceOf(IllegalStateException.class);
            connection.setAutoCommit(false);
            FixtureAuditTransactions.bindJdbc(connection,first);
            try(var query=connection.createStatement();var row=query.executeQuery("SELECT current_setting('app.actor_id')::uuid")) {
                assertThat(row.next()).isTrue();assertThat(row.getObject(1,UUID.class)).isEqualTo(first);
            }
            connection.commit();
            FixtureAuditTransactions.bindJdbc(connection,second);
            try(var query=connection.createStatement();var row=query.executeQuery("SELECT current_setting('app.actor_id')::uuid")) {
                assertThat(row.next()).isTrue();assertThat(row.getObject(1,UUID.class)).isEqualTo(second);
            }
            connection.rollback();
            try(var query=connection.createStatement();var row=query.executeQuery("SELECT NULLIF(current_setting('app.actor_id',true),'')")) {
                assertThat(row.next()).isTrue();assertThat(row.getString(1)).isNull();
            }
            connection.rollback();
        }
    }
    @Test void autoCommitBusinessWritesKeepTheirBoundaryAndRecoverAfterSqlRejection()throws Exception {
        try(var connection=database.openConnection()) {
            try(var statement=connection.createStatement()){statement.execute("CREATE TEMP TABLE fixture_audit_counter(id integer PRIMARY KEY,value integer NOT NULL)");}
            assertThat(FixtureAuditTransactions.executeUpdate(connection,"INSERT INTO fixture_audit_counter VALUES(1,1)")).isEqualTo(1);
            var rejected=org.junit.jupiter.api.Assertions.assertThrows(java.sql.SQLException.class,()->FixtureAuditTransactions.executeUpdate(connection,"INSERT INTO fixture_audit_counter VALUES(1,2)"));
            assertThat(rejected.getSQLState()).isEqualTo("23505");
            assertThat(connection.getAutoCommit()).isTrue();
            connection.setAutoCommit(false);FixtureAuditTransactions.bindJdbc(connection);
            FixtureAuditTransactions.executeUpdate(connection,"UPDATE fixture_audit_counter SET value=2 WHERE id=1");
            connection.rollback();connection.setAutoCommit(true);
            try(var statement=connection.createStatement();var row=statement.executeQuery("SELECT value,NULLIF(current_setting('app.actor_id',true),'') FROM fixture_audit_counter WHERE id=1")) {
                assertThat(row.next()).isTrue();assertThat(row.getInt(1)).isEqualTo(1);assertThat(row.getString(2)).isNull();
            }
        }
    }
}
