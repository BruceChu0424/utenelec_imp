package com.uten.imp.security;

import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.aop.framework.ProxyFactory;
import org.springframework.core.io.ClassPathResource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.AbstractDataSource;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.annotation.AnnotationTransactionAttributeSource;
import org.springframework.transaction.interceptor.TransactionInterceptor;
import org.testcontainers.postgresql.PostgreSQLContainer;

import javax.sql.DataSource;
import java.sql.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Narrow real-JDBC proof: two independent realms behind the same authority endpoint.
 * These deliberately minimal databases are not full migration or business UAT evidence. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ReadScopeDatasetRealmPostgresTest {
    static final PostgreSQLContainer POSTGRES=new PostgreSQLContainer("postgres:16-alpine")
            .withDatabaseName("realm_router").withReuse(false)
            .withCreateContainerCmdModifier(cmd->cmd.getHostConfig().withMemory(512L*1024*1024).withNanoCPUs(1_000_000_000L));
    @AfterAll static void close(){POSTGRES.stop();}

    @Test void identicalAuthorizationFactsBehindTheSameReaderCannotReuseAnIndependentDatasetProof() throws Exception {
        POSTGRES.start();
        var control=new JdbcTemplate(new DriverManagerDataSource(POSTGRES.getJdbcUrl(),POSTGRES.getUsername(),POSTGRES.getPassword()));
        control.execute("CREATE DATABASE realm_a");control.execute("CREATE DATABASE realm_b");
        DataSource a=realm("realm_a"),b=realm("realm_b");
        var selected=new AtomicReference<>(a);
        DataSource endpoint=new AbstractDataSource(){
            @Override public Connection getConnection() throws SQLException{return selected.get().getConnection();}
            @Override public Connection getConnection(String username,String password) throws SQLException{return selected.get().getConnection(username,password);}
        };
        var actor=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"same-api-reader",Set.of("stock_report:view"),false,true,false);
        var restorer=mock(SubmitterPrincipalRestorer.class);
        when(restorer.currentStamps(actor.getId())).thenReturn(Optional.of(new SubmitterPrincipalRestorer.AuthorizationStamps(1,7)));
        when(restorer.restore(actor.getId(),1,7L)).thenReturn(actor);
        var owners=mock(OwnerVisibility.class);
        var target=new ReadScopeVersionAuthority(new NamedParameterJdbcTemplate(endpoint),restorer,owners);
        var proxy=new ProxyFactory(target);proxy.setProxyTargetClass(true);
        var transactionAdvice = new TransactionInterceptor();
        transactionAdvice.setTransactionManager(new DataSourceTransactionManager(endpoint));
        transactionAdvice.setTransactionAttributeSource(new AnnotationTransactionAttributeSource());
        transactionAdvice.afterPropertiesSet();
        proxy.addAdvice(transactionAdvice);
        var authority=(ReadScopeVersionAuthority)proxy.getProxy();
        UUID firstId=new JdbcTemplate(a).queryForObject("SELECT business_dataset_id FROM authorization_state",UUID.class);
        UUID secondId=new JdbcTemplate(b).queryForObject("SELECT business_dataset_id FROM authorization_state",UUID.class);
        assertThat(firstId).isNotEqualTo(secondId);
        String first=authority.scopeFor("stock",actor);
        selected.set(b);String second=authority.scopeFor("stock",actor);
        assertThat(second).isNotEqualTo(first);
        selected.set(a);assertThat(authority.scopeFor("stock",actor)).isEqualTo(first);
        // Returning to the same unchanged realm is legal; a new immutable UUID is
        // what distinguishes independent data, not a fabricated monotonic API counter.
        verifyNoInteractions(owners);
        for(DataSource database:List.of(a,b)){
            var jdbc=new JdbcTemplate(database);
            assertThatThrownBy(()->jdbc.update("UPDATE authorization_state SET business_dataset_id=gen_random_uuid() WHERE singleton_id=1"))
                    .isInstanceOf(org.springframework.dao.DataAccessException.class);
        }
    }
    private static DataSource realm(String name) throws Exception {
        String url=POSTGRES.getJdbcUrl().replace("/realm_router","/"+name);
        var source=new DriverManagerDataSource(url,POSTGRES.getUsername(),POSTGRES.getPassword());
        var db=new JdbcTemplate(source);
        db.execute("CREATE TABLE authorization_state(singleton_id int PRIMARY KEY,business_reset_generation bigint NOT NULL)");
        db.execute("INSERT INTO authorization_state VALUES(1,7)");
        db.execute("CREATE TABLE read_scope_generations(domain text PRIMARY KEY,generation bigint NOT NULL)");
        db.execute("INSERT INTO read_scope_generations VALUES('stock',0)");
        // Apply the actual V935 identity migration, without changing its bytes or disabling its guards.
        try(var stream=new ClassPathResource("db/migration/V935__persistent_business_dataset_identity.sql").getInputStream()){
            db.execute(new String(stream.readAllBytes(),java.nio.charset.StandardCharsets.UTF_8));
        }
        return source;
    }
}
