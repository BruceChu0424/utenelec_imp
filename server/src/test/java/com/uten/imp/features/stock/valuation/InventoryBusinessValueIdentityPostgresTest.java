package com.uten.imp.features.stock.valuation;

import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.UUID;
import com.uten.imp.support.MigratedProjectionSchema;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.postgresql.PostgreSQLContainer;
import static org.assertj.core.api.Assertions.*;

/** Real transaction identities, including rebind/savepoint restoration and bounded mixed-source reads. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class InventoryBusinessValueIdentityPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    private static final UUID FIRST=UUID.randomUUID(),SECOND=UUID.randomUUID();
    private static final UUID FIRST_EMPLOYEE=UUID.randomUUID(),SECOND_EMPLOYEE=UUID.randomUUID();
    private static JdbcTemplate db;
    private static TransactionTemplate tx;
    private static InventoryBusinessValueSupport support;

    @BeforeAll static void start(){
        PG.start();var ds=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        db=new JdbcTemplate(ds);tx=new TransactionTemplate(new DataSourceTransactionManager(ds));
        support=new InventoryBusinessValueSupport(new NamedParameterJdbcTemplate(ds));
        MigratedProjectionSchema.createCurrentTables(db,"users");
        db.update("""
                INSERT INTO users(id,employee_id,login_account,password_hash)
                VALUES (?,?,'anonymous-identity-first','not-a-login-credential'),
                    (?,?,'anonymous-identity-second','not-a-login-credential')
                """,FIRST,FIRST_EMPLOYEE,SECOND,SECOND_EMPLOYEE);
    }
    @AfterAll static void stop(){PG.stop();}

    @Test void actorRebindAndSavepointRollbackNeverReuseAnotherIdentity(){
        tx.executeWithoutResult(status->{
            bind(FIRST);assertActor(null,FIRST,FIRST_EMPLOYEE);
            Object savepoint=status.createSavepoint();
            bind(SECOND);assertActor(null,SECOND,SECOND_EMPLOYEE);
            assertActor(FIRST,FIRST,FIRST_EMPLOYEE);
            status.rollbackToSavepoint(savepoint);assertActor(null,FIRST,FIRST_EMPLOYEE);
            status.releaseSavepoint(savepoint);
        });
        tx.executeWithoutResult(status->{
            assertThatThrownBy(()->context(null)).hasMessageContaining("缺少实际责任账号");
            assertActor(SECOND,SECOND,SECOND_EMPLOYEE);
            assertThatThrownBy(()->context(UUID.randomUUID())).isInstanceOf(org.springframework.dao.EmptyResultDataAccessException.class);
        });
    }

    @Test void mixedActorsAcrossBoundedReadsRetainEverySourceAndOriginalOrder(){
        tx.executeWithoutResult(status->{
            bind(SECOND);
            var inputs=new ArrayList<InventoryBusinessValueSupport.ContextInput>();
            for(int index=0;index<257;index++){
                UUID source=UUID.randomUUID();
                inputs.add(new InventoryBusinessValueSupport.ContextInput("IDENTITY_VECTOR",source,source,source,
                        index%3==0?FIRST:index%3==1?null:SECOND,OffsetDateTime.now()));
            }
            var contexts=support.contexts(inputs);assertThat(contexts).hasSize(inputs.size());
            for(int index=0;index<inputs.size();index++){
                var actual=contexts.get(index);var input=inputs.get(index);
                assertThat(actual.sourceEventId()).isEqualTo(input.event());
                assertThat(actual.sourceDocId()).isEqualTo(input.document());
                assertThat(actual.sourceItemId()).isEqualTo(input.item());
                assertThat(actual.actorUserId()).isEqualTo(index%3==0?FIRST:SECOND);
                assertThat(actual.actorEmployeeId()).isEqualTo(index%3==0?FIRST_EMPLOYEE:SECOND_EMPLOYEE);
                assertThat(actual.idempotencyKey()).isEqualTo("IDENTITY_VECTOR:"+input.event());
            }
        });
    }

    private static void bind(UUID actor){db.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,actor.toString());}
    private static com.uten.imp.application.port.InventoryValuationPort.EventContext context(UUID actor){
        UUID source=UUID.randomUUID();return support.context("IDENTITY_VECTOR",source,source,source,actor,OffsetDateTime.now());
    }
    private static void assertActor(UUID requested,UUID actor,UUID employee){
        var actual=context(requested);assertThat(actual.actorUserId()).isEqualTo(actor);assertThat(actual.actorEmployeeId()).isEqualTo(employee);
    }
}
