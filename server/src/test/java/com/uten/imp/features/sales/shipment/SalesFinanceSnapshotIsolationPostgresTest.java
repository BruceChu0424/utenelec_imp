package com.uten.imp.features.sales.shipment;

import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.*;
import org.springframework.transaction.annotation.AnnotationTransactionAttributeSource;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.math.BigDecimal;
import java.sql.*;
import static org.assertj.core.api.Assertions.*;

/** Actual owning transaction metadata drives a real PostgreSQL concurrent-commit MVCC proof. No business tables are fabricated. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class SalesFinanceSnapshotIsolationPostgresTest {
    static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    static DriverManagerDataSource source;static JdbcTemplate db;
    @BeforeAll static void start(){
        PG.start();source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        db=new JdbcTemplate(source);db.execute("CREATE TABLE finance_snapshot_isolation_probe(id integer PRIMARY KEY,amount numeric NOT NULL)");
    }
    @AfterAll static void stop(){PG.stop();}
    @Test void everyDecisionAndBatchWrapperKeepsOneSnapshotWhileAnotherConnectionCommits() {
        var attributes=new AnnotationTransactionAttributeSource();
        var manager=new DataSourceTransactionManager(source);int sequence=0;
        for(var method:SalesFinanceSnapshotIsolationContractTest.entrypoints()){
            int id=++sequence;db.update("INSERT INTO finance_snapshot_isolation_probe(id,amount)VALUES(?,1000)",id);
            var attribute=attributes.getTransactionAttribute(method,method.getDeclaringClass());
            assertThat(attribute).isNotNull();var transaction=new TransactionTemplate(manager,attribute);
            transaction.executeWithoutResult(status->{
                BigDecimal first=db.queryForObject("SELECT amount FROM finance_snapshot_isolation_probe WHERE id=?",BigDecimal.class,id);
                try(Connection external=source.getConnection();PreparedStatement change=external.prepareStatement("UPDATE finance_snapshot_isolation_probe SET amount=2000 WHERE id=?")){
                    external.setAutoCommit(false);change.setInt(1,id);assertThat(change.executeUpdate()).isEqualTo(1);external.commit();
                }catch(SQLException failure){throw new IllegalStateException(failure);}
                BigDecimal second=db.queryForObject("SELECT amount FROM finance_snapshot_isolation_probe WHERE id=?",BigDecimal.class,id);
                assertThat(first).as(method.toGenericString()).isEqualByComparingTo("1000");
                assertThat(second).as(method.toGenericString()).isEqualByComparingTo(first);
            });
            assertThat(db.queryForObject("SELECT amount FROM finance_snapshot_isolation_probe WHERE id=?",BigDecimal.class,id))
                    .as(method.toGenericString()+" external commit is visible after the owning transaction ends").isEqualByComparingTo("2000");
        }
        assertThat(sequence).isEqualTo(10);
    }
}
