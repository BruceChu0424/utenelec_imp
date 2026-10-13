package com.uten.imp.features.stock.valuation;

import java.util.Map;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;
import static org.assertj.core.api.Assertions.*;

/** Protocol/transaction contract; business value guards are exercised by InventoryPositionPostgresTest. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class InventoryValueWriteSetPostgresTest {
    private static final PostgreSQLContainer<?> PG=new PostgreSQLContainer<>("postgres:16-alpine");
    private static JdbcTemplate db;
    private static NamedParameterJdbcTemplate named;
    private static TransactionTemplate tx;

    @BeforeAll static void start(){
        PG.start();var ds=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        db=new JdbcTemplate(ds);named=new NamedParameterJdbcTemplate(ds);tx=new TransactionTemplate(new DataSourceTransactionManager(ds));
        db.execute("""
                CREATE TABLE write_parent(id integer PRIMARY KEY, version integer NOT NULL, body text);
                CREATE TABLE write_child(id integer PRIMARY KEY,parent_id integer NOT NULL REFERENCES write_parent(id),version integer NOT NULL);
                CREATE FUNCTION check_parent_version() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    IF NOT EXISTS(SELECT 1 FROM write_parent WHERE id=NEW.parent_id AND version=NEW.version) THEN
                        RAISE EXCEPTION 'child must observe preceding parent write';
                    END IF;
                    RETURN NEW;
                END $$;
                CREATE TRIGGER check_parent_version BEFORE INSERT ON write_child FOR EACH ROW EXECUTE FUNCTION check_parent_version();
                """);
    }
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void reset(){db.execute("TRUNCATE write_child,write_parent");}

    @Test void boundStatementsKeepImmediateTriggerOrderAndRepeatedNamesIndependent(){
        String payload="quote '; DELETE FROM write_parent; -- :id ?";
        tx.executeWithoutResult(status->{
            var writes=new InventoryValueWriteSet(named);
            writes.add("INSERT INTO write_parent VALUES (:id,:version,:body)",Map.of("id",1,"version",1,"body",payload),"parent");
            writes.add("INSERT INTO write_child VALUES (:id,:parent,:version)",Map.of("id",11,"parent",1,"version",1),"first child");
            writes.add("UPDATE write_parent SET version=:next WHERE id=:id AND version=:before",Map.of("id",1,"next",2,"before",1),"parent changed");
            writes.add("INSERT INTO write_child VALUES (:id,:parent,:version)",Map.of("id",12,"parent",1,"version",2),"second child");
            writes.flush();
            assertThat(db.queryForObject("SELECT body FROM write_parent",String.class)).isEqualTo(payload);
            assertThat(db.queryForList("SELECT version FROM write_child ORDER BY id",Integer.class)).containsExactly(1,2);
            // A flush is a read boundary, not a commit, and the same local writer can finish the event afterwards.
            writes.add("UPDATE write_parent SET version=3 WHERE id=:id AND version=2",Map.of("id",1),"parent changed");
            writes.flush();writes.flush();
        });
        assertThat(db.queryForObject("SELECT version FROM write_parent",Integer.class)).isEqualTo(3);
    }

    @Test void zeroRowCompareAndSetRollsBackEarlierAndLaterWrites(){
        assertThatThrownBy(()->tx.executeWithoutResult(status->{
            var writes=new InventoryValueWriteSet(named);
            writes.add("INSERT INTO write_parent VALUES (1,1,'original')",Map.of(),"insert");
            writes.add("UPDATE write_parent SET version=2 WHERE id=1 AND version=9",Map.of(),"source changed");
            writes.add("INSERT INTO write_child VALUES (11,1,1)",Map.of(),"child");
            writes.flush();
        })).hasMessageContaining("source changed");
        assertThat(db.queryForObject("SELECT count(*) FROM write_parent",Integer.class)).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM write_child",Integer.class)).isZero();
    }

    @Test void laterDatabaseFailureRollsBackTheEntireOperation(){
        assertThatThrownBy(()->tx.executeWithoutResult(status->{
            var writes=new InventoryValueWriteSet(named);
            writes.add("INSERT INTO write_parent VALUES (1,1,'original')",Map.of(),"insert");
            writes.add("INSERT INTO write_child VALUES (11,1,2)",Map.of(),"bad version");
            writes.flush();
        })).hasMessageContaining("child must observe preceding parent write");
        assertThat(db.queryForObject("SELECT count(*) FROM write_parent",Integer.class)).isZero();
    }

    @Test void noTransactionCannotLeaveAnAutocommittedPartialGraph(){
        var writes=new InventoryValueWriteSet(named);
        writes.add("INSERT INTO write_parent VALUES (1,1,'original')",Map.of(),"insert");
        assertThatThrownBy(writes::flush).isInstanceOf(IllegalStateException.class).hasMessageContaining("originating transaction");
        assertThat(db.queryForObject("SELECT count(*) FROM write_parent",Integer.class)).isZero();
    }
}
