package com.uten.imp.common.util;

import java.sql.*;
import java.util.concurrent.*;
import org.hibernate.Session;
import org.hibernate.SessionFactory;
import org.hibernate.cfg.Configuration;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import static org.assertj.core.api.Assertions.*;

/** Same physical connection is deliberately reused to expose leaked settings. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class InteractiveTaskReadScopePostgresTest {
    static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    static Connection physical;
    static SessionFactory factory;
    Session session;
    @BeforeAll static void start()throws Exception{
        PG.start();physical=DriverManager.getConnection(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        try(var statement=physical.createStatement()){
            statement.execute("CREATE TABLE fixture_write(value integer)");
            statement.execute("CREATE ROLE fixture_reader NOLOGIN NOSUPERUSER NOBYPASSRLS");
            statement.execute("GRANT SELECT,INSERT ON fixture_write TO fixture_reader");
        }
        var configuration=new Configuration().setProperty("hibernate.hbm2ddl.auto","none");
        configuration.getProperties().put("hibernate.connection.datasource",new SingleConnectionDataSource(physical,true));
        factory=configuration.buildSessionFactory();
    }
    @AfterAll static void stop()throws Exception{if(factory!=null){
        factory.close();
    }
    if(physical!=null){
        physical.close();
    }
    PG.stop();}
    @BeforeEach void begin()throws Exception{session=factory.openSession();session.getTransaction().begin();setting("on");}
    @AfterEach void close()throws Exception{
        if(session!=null){if(session.getTransaction().isActive()){
            session.getTransaction().rollback();
        }
        session.close();}
        physical.setReadOnly(false);
    }

    @Test void nestedReadsRestoreOriginalOnAndOffWithoutChangingConnectionOrIsolation()throws Exception{
        session.getTransaction().rollback();physical.setReadOnly(true);session.getTransaction().begin();setting("on");
        try(var statement=physical.createStatement()){statement.execute("SET LOCAL ROLE fixture_reader");}
        int pid=integer("SELECT pg_backend_pid()"),isolation=physical.getTransactionIsolation();
        assertThat(physical.isReadOnly()).isTrue();assertThat(text("SHOW transaction_read_only")).isEqualTo("on");
        try(var outer=InteractiveTaskReadScope.open(session)){
            assertThat(jit()).isEqualTo("off");assertThat(integer("SELECT pg_backend_pid()")).isEqualTo(pid);
            assertThat(text("SELECT current_user")).isEqualTo("fixture_reader");
            try(var inner=InteractiveTaskReadScope.open(session)){assertThat(jit()).isEqualTo("off");}
            assertThat(jit()).isEqualTo("off");
        }
        assertThat(jit()).isEqualTo("on");assertThat(physical.getTransactionIsolation()).isEqualTo(isolation);
        assertThat(physical.isReadOnly()).isTrue();assertThat(session.getTransaction().isActive()).isTrue();
        assertThat(physical.getAutoCommit()).isFalse();assertThat(text("SELECT current_user")).isEqualTo("fixture_reader");
        setting("off");try(var ignored=InteractiveTaskReadScope.open(session)){assertThat(jit()).isEqualTo("off");setting("on");}
        assertThat(jit()).isEqualTo("off");
        session.getTransaction().rollback();physical.setReadOnly(false);session.getTransaction().begin();
        assertThat(jit()).isEqualTo("on");assertThat(integer("SELECT pg_backend_pid()")).isEqualTo(pid);
        assertThat(text("SELECT current_user")).isEqualTo(PG.getUsername());
        writeAndRead();
    }

    @Test void applicationFailureAndDatabaseAbortDoNotPolluteTheNextWriteOrRead()throws Exception{
        var expected=new IllegalStateException("synthetic cancelled UI read");
        assertThatThrownBy(()->{try(var ignored=InteractiveTaskReadScope.open(session)){throw expected;}}).isSameAs(expected);
        assertThat(jit()).isEqualTo("on");writeAndRead();
        SQLException failure=org.junit.jupiter.api.Assertions.assertThrows(SQLException.class,()->{
            try(var ignored=InteractiveTaskReadScope.open(session);var statement=physical.createStatement()){
                statement.executeQuery("SELECT 1/0");
            }
        });
        assertThat(failure.getSQLState()).isEqualTo("22012");assertThat(failure.getSuppressed()).isNotEmpty();
        session.getTransaction().rollback();session.getTransaction().begin();assertThat(jit()).isEqualTo("on");writeAndRead();
    }

    @Test void actualJdbcCancellationRollsBackLocalJitOnTheSameReusableConnection()throws Exception{
        int pid=integer("SELECT pg_backend_pid()");var executor=Executors.newSingleThreadExecutor();
        try{
            SQLException failure=org.junit.jupiter.api.Assertions.assertThrows(SQLException.class,()->{
                try(var ignored=InteractiveTaskReadScope.open(session);var statement=physical.createStatement()){
                    var running=executor.submit(()->{try(var result=statement.executeQuery("SELECT pg_sleep(30)")){return (SQLException)null;}catch(SQLException cancelled){return cancelled;}});
                    boolean active=false;
                    try(var observer=DriverManager.getConnection(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());var query=observer.prepareStatement("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE pid=? AND state='active' AND query LIKE '%pg_sleep%')")){
                        query.setInt(1,pid);
                        for(int attempt=0;attempt<100&&!active;attempt++){
                            try(var result=query.executeQuery()){result.next();active=result.getBoolean(1);}
                            if(!active)Thread.sleep(25);
                        }
                    }
                    assertThat(active).as("owned backend reached the cancellable statement").isTrue();
                    statement.cancel();throw java.util.Objects.requireNonNull(running.get(10,TimeUnit.SECONDS));
                }
            });
            assertThat(failure.getSQLState()).isEqualTo("57014");assertThat(failure.getSuppressed()).isNotEmpty();
            session.getTransaction().rollback();session.getTransaction().begin();
            assertThat(jit()).isEqualTo("on");assertThat(integer("SELECT pg_backend_pid()")).isEqualTo(pid);writeAndRead();
        }finally{executor.shutdownNow();}
    }

    private String jit()throws Exception{try(var statement=physical.createStatement();var result=statement.executeQuery("SELECT current_setting('jit')")){result.next();return result.getString(1);}}
    private String text(String sql)throws Exception{try(var statement=physical.createStatement();var result=statement.executeQuery(sql)){result.next();return result.getString(1);}}
    private void setting(String value)throws Exception{try(var statement=physical.prepareStatement("SELECT set_config('jit',?,true)")){statement.setString(1,value);statement.execute();}}
    private int integer(String sql)throws Exception{try(var statement=physical.createStatement();var result=statement.executeQuery(sql)){result.next();return result.getInt(1);}}
    private void writeAndRead()throws Exception{try(var statement=physical.createStatement()){statement.executeUpdate("INSERT INTO fixture_write VALUES(7)");}assertThat(integer("SELECT count(*) FROM fixture_write")).isPositive();assertThat(jit()).isEqualTo("on");}
}
