package com.uten.imp.features.sales.order;

import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** The actual migrated PostgreSQL schema must preserve replacement evidence and still allow trusted test reset. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
class SalesOrderRequotationFencePostgresTest {
    private MigratedSchemaBaseline.ScopedDatabase database;
    private DriverManagerDataSource source;
    private JdbcTemplate jdbc;

    @BeforeEach void open() throws Exception {
        database = MigratedSchemaBaseline.openDatabase("sales_requotation_fence");
        source = new DriverManagerDataSource(database.getJdbcUrl(), database.getUsername(), database.getPassword());
        jdbc = new JdbcTemplate(source);
    }
    @AfterEach void close() throws Exception { if (database != null) database.close(); }

    @Test void firstSealCannotSmuggleInBusinessChangesAndTheRecordedFactCannotBeCleared() {
        Fixture f = fixture();
        assertThatThrownBy(() -> jdbc.update("""
                INSERT INTO sales_orders(id,bill_no,bill_date,client_id,status,is_stopped,source_quote_id,requoted_to_id,requoted_at,requoted_by)
                VALUES (?,'XD'||to_char(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Shanghai','YYYYMMDD')||'991503',CURRENT_DATE,?,1,false,?,?,now(),?)
                """, UUID.randomUUID(), f.client(), f.quote(), f.replacement(), f.actor())).hasMessageContaining("must be appended");
        assertThatThrownBy(() -> jdbc.update("""
                UPDATE sales_orders SET requoted_to_id=?,requoted_at=now(),requoted_by=?,is_stopped=false WHERE id=?
                """, f.replacement(), f.actor(), f.order())).hasMessageContaining("already terminated");
        assertThatThrownBy(() -> jdbc.update("""
                UPDATE sales_orders SET requoted_to_id=?,requoted_at=now(),requoted_by=?,total_original=11 WHERE id=?
                """, f.replacement(), f.actor(), f.order())).hasMessageContaining("already terminated");
        UUID anotherClient = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO clients(id,code,name,status,code_sequence)
                VALUES (?,?,'另一个客户','使用',(SELECT COALESCE(MAX(code_sequence),0)+1 FROM clients))
                """, anotherClient, "RF-OTHER-" + anotherClient);
        assertThatThrownBy(() -> jdbc.update("""
                UPDATE sales_orders SET requoted_to_id=?,requoted_at=now(),requoted_by=?,client_id=? WHERE id=?
                """, f.replacement(), f.actor(), anotherClient, f.order())).hasMessageContaining("already terminated");
        assertThat(jdbc.queryForObject("SELECT requoted_to_id FROM sales_orders WHERE id=?", UUID.class, f.order())).isNull();
        seal(f);
        assertThatThrownBy(() -> jdbc.update("UPDATE sales_orders SET is_stopped=false WHERE id=?", f.order()))
                .hasMessageContaining("permanently read-only");
        assertThatThrownBy(() -> jdbc.update("""
                UPDATE sales_orders SET requoted_to_id=NULL,requoted_at=NULL,requoted_by=NULL WHERE id=?
                """, f.order())).hasMessageContaining("permanently read-only");
        jdbc.update("UPDATE sales_quotes SET is_deleted=true,deleted_at=now() WHERE id=?", f.replacement());
        assertThatThrownBy(() -> jdbc.update("UPDATE sales_orders SET status=0 WHERE id=?", f.order()))
                .hasMessageContaining("permanently read-only");
        assertThat(jdbc.queryForObject("SELECT total_original FROM sales_orders WHERE id=?", java.math.BigDecimal.class, f.order()))
                .isEqualByComparingTo("10");
    }

    @Test void controlledResetClearsReplacementBusinessGraphAndKeepsCustomerMaster() throws Exception {
        Fixture f = fixture();
        seal(f);
        try (var connection = source.getConnection(); var statement = connection.createStatement()) {
            String role = "requote_runtime_" + UUID.randomUUID().toString().replace("-", "");
            statement.execute("CREATE ROLE " + role + " NOLOGIN");
            statement.execute("GRANT USAGE ON SCHEMA public TO " + role);
            statement.execute("GRANT SELECT ON ALL TABLES IN SCHEMA public TO " + role);
            statement.execute("GRANT UPDATE ON sales_orders TO " + role);
            try {
                statement.execute("SET ROLE " + role);
                statement.execute("SET app.test_business_reset='CLEAR_TEST_BUSINESS_WITH_HISTORY'");
                assertThatThrownBy(() -> statement.execute("UPDATE sales_orders SET is_stopped=false WHERE id='" + f.order() + "'"))
                        .hasMessageContaining("permanently read-only");
            } finally {
                statement.execute("RESET ROLE");
                statement.execute("RESET app.test_business_reset");
                statement.execute("REVOKE ALL ON ALL TABLES IN SCHEMA public FROM " + role);
                statement.execute("REVOKE ALL ON SCHEMA public FROM " + role);
                statement.execute("DROP ROLE " + role);
            }
        }
        long generation = jdbc.queryForObject("SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1", Long.class);
        jdbc.queryForMap("SELECT * FROM business_data_reset()");
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM sales_orders WHERE id=?", Long.class, f.order())).isZero();
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM sales_quotes WHERE id IN (?,?)", Long.class, f.quote(), f.replacement())).isZero();
        assertThat(jdbc.queryForObject("SELECT name FROM clients WHERE id=?", String.class, f.client())).isEqualTo("保留的客户主档");
        assertThat(jdbc.queryForObject("SELECT business_reset_generation FROM authorization_state WHERE singleton_id=1", Long.class))
                .isEqualTo(generation + 1);
        assertThat(jdbc.queryForObject("SELECT fn_business_test_reset_active()", Boolean.class)).isFalse();
    }

    private void seal(Fixture f) {
        jdbc.update("UPDATE sales_orders SET requoted_to_id=?,requoted_at=now(),requoted_by=? WHERE id=?",
                f.replacement(), f.actor(), f.order());
    }

    private Fixture fixture() {
        assertThat(jdbc.queryForObject("SELECT COUNT(*) FROM flyway_schema_history WHERE version='792' AND success", Long.class)).isEqualTo(1);
        UUID client=UUID.randomUUID(), quote=UUID.randomUUID(), replacement=UUID.randomUUID(), order=UUID.randomUUID(), actor=UUID.randomUUID();
        jdbc.update("""
                INSERT INTO clients(id,code,name,status,code_sequence)
                VALUES (?,?,'保留的客户主档','使用',(SELECT COALESCE(MAX(code_sequence),0)+1 FROM clients))
                """, client, "RF-" + client);
        jdbc.update("""
                INSERT INTO sales_quotes(id,bill_no,bill_date,client_id,status)
                VALUES (?,'XB'||to_char(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Shanghai','YYYYMMDD')||'991501',CURRENT_DATE,?,1)
                """, quote, client);
        jdbc.update("""
                INSERT INTO sales_quotes(id,bill_no,bill_date,client_id,status,origin_quote_id)
                VALUES (?,'XB'||to_char(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Shanghai','YYYYMMDD')||'991502',CURRENT_DATE,?,0,?)
                """, replacement, client, quote);
        jdbc.update("""
                INSERT INTO sales_orders(id,bill_no,bill_date,client_id,status,is_stopped,source_quote_id,total_original)
                VALUES (?,'XD'||to_char(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Shanghai','YYYYMMDD')||'991501',CURRENT_DATE,?,1,true,?,10)
                """, order, client, quote);
        return new Fixture(client, quote, replacement, order, actor);
    }
    private record Fixture(UUID client, UUID quote, UUID replacement, UUID order, UUID actor) {}
}
