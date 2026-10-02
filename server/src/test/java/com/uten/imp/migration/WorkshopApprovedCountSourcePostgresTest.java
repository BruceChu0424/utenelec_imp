package com.uten.imp.migration;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Executes V768 proof guards on PostgreSQL, including forged movement dimensions and non-bin-ledger history. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class WorkshopApprovedCountSourcePostgresTest {
    private static final PostgreSQLContainer<?> PG=new PostgreSQLContainer<>("postgres:16-alpine");
    private static JdbcTemplate db;
    private static TransactionTemplate transactions;
    private UUID request,line,event,bin,goods,unit,actor,period;

    @BeforeAll static void schema() throws Exception {
        PG.start(); var source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        db=new JdbcTemplate(source); transactions=new TransactionTemplate(new DataSourceTransactionManager(source));
        com.uten.imp.support.MigratedProjectionSchema.createCurrentTables(db,
                "goods", "stock_count_requests", "stock_count_request_lines", "stock_count_request_events",
                "workshop_material_settings", "workshop_material_periods", "stock_movements",
                "workshop_material_count_adjustment_postings");
        // The projection helper intentionally omits generated expressions; this guard needs the exact V768 delta.
        db.execute("ALTER TABLE workshop_material_count_adjustment_postings DROP COLUMN signed_qty");
        db.execute("ALTER TABLE workshop_material_count_adjustment_postings ADD COLUMN signed_qty numeric GENERATED ALWAYS AS(target_qty-before_qty) STORED");
        db.execute("""
                CREATE VIEW v_workshop_material_bin_ledger AS SELECT bin_warehouse_id,goods_id,color_id FROM workshop_material_count_adjustment_postings;
                """);
        String sql=Files.readString(Path.of("src/main/resources/db/migration/V768__approved_workshop_count_sources.sql"));
        for(String function:new String[]{"fn_guard_workshop_count_adjustment","fn_assert_workshop_count_adjustment"}) {
            int start=sql.indexOf("CREATE FUNCTION "+function+"(");
            db.execute(sql.substring(start,sql.indexOf("$$;",start)+3));
        }
        db.execute("CREATE TRIGGER guard BEFORE INSERT OR UPDATE OR DELETE ON workshop_material_count_adjustment_postings FOR EACH ROW EXECUTE FUNCTION fn_guard_workshop_count_adjustment()");
        db.execute("CREATE CONSTRAINT TRIGGER proof AFTER INSERT OR UPDATE ON workshop_material_count_adjustment_postings DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_assert_workshop_count_adjustment()");
    }

    @BeforeEach void facts() {
        db.execute("TRUNCATE goods,stock_count_requests,stock_count_request_lines,stock_count_request_events,workshop_material_settings,workshop_material_periods,stock_movements,workshop_material_count_adjustment_postings");
        request=UUID.randomUUID();line=UUID.randomUUID();event=UUID.randomUUID();bin=UUID.randomUUID();
        goods=UUID.randomUUID();unit=UUID.randomUUID();actor=UUID.randomUUID();period=UUID.randomUUID();
        db.update("INSERT INTO goods(id,unit_id,issue_method,is_deleted) VALUES (?,?,'PERIODIC',FALSE)",goods,unit);
        db.update("INSERT INTO stock_count_requests(id,warehouse_id,reviewed_by,approval_event_id,status,review_route,row_version) VALUES (?,?,?,?,'APPROVED','WAREHOUSE',1)",request,bin,actor,event);
        db.update("INSERT INTO stock_count_request_lines(id,request_id,goods_id,color_id,unit_id,expected_qty,target_qty) VALUES (?,?,?,NULL,?,0,10)",line,request,goods,unit);
        db.update("INSERT INTO stock_count_request_events(id,request_id,actor_id,action,request_version) VALUES (?,?,?,'APPROVE',1)",event,request,actor);
        db.update("INSERT INTO workshop_material_settings(workshop_department_id,periodic_bin_warehouse_id,periodic_enabled) VALUES (gen_random_uuid(),?,TRUE)",bin);
        db.update("INSERT INTO workshop_material_periods(id,bin_warehouse_id,period_no,status,start_date) VALUES (?,?,1,'OPEN',CURRENT_DATE)",period,bin);
    }
    @AfterAll static void stop() { PG.stop(); }

    @Test void onlyAnExactApprovedWarehouseDecisionCanCreateASource() {
        db.update("UPDATE stock_count_requests SET status='PENDING'");
        assertThrows(DataAccessException.class,()->post("OPENING",unit,1));
        db.update("UPDATE stock_count_requests SET status='APPROVED'");
        db.update("UPDATE stock_count_request_events SET request_version=2");
        assertThrows(DataAccessException.class,()->post("OPENING",unit,1));
        db.update("UPDATE stock_count_request_events SET request_version=1");
        assertDoesNotThrow(()->post("OPENING",unit,1));
    }

    @Test void nonPeriodicLedgerStockHistoryPreventsAnotherOpening() {
        db.update("INSERT INTO stock_movements(id,warehouse_id,goods_id,movement_type,direction,qty) VALUES (?,?,?,13,1,10)",
                UUID.randomUUID(),bin,goods);
        assertThrows(DataAccessException.class,()->post("OPENING",unit,1));
        assertDoesNotThrow(()->post("ADJUSTMENT",unit,1));
    }

    @Test void movementBaseUnitAndRateArePartOfTheApprovalProof() {
        assertThrows(DataAccessException.class,()->post("OPENING",UUID.randomUUID(),1));
        assertThrows(DataAccessException.class,()->post("OPENING",unit,1000));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM workshop_material_count_adjustment_postings",Integer.class));
        assertDoesNotThrow(()->post("OPENING",unit,1));
    }

    private void post(String kind,UUID movementUnit,int rate) {
        transactions.executeWithoutResult(status->{
            UUID posting=UUID.randomUUID(),movement=UUID.randomUUID();
            db.update("""
                    INSERT INTO workshop_material_count_adjustment_postings(id,request_id,line_id,approval_event_id,
                        period_id,bin_warehouse_id,goods_id,unit_id,kind,before_qty,target_qty,business_date,created_by)
                    VALUES (?,?,?,?,?,?,?,?,?,0,10,CURRENT_DATE,?)
                    """,posting,request,line,event,period,bin,goods,unit,kind,actor);
            db.update("""
                    INSERT INTO stock_movements(id,warehouse_id,goods_id,unit_id,unit_rate,source_doc_type,
                        source_doc_id,source_item_id,movement_type,direction,qty)
                    VALUES (?,?,?,?,?,'STOCK_COUNT_REQUEST',?,?,23,1,10)
                    """,movement,bin,goods,movementUnit,rate,request,line);
            db.update("UPDATE workshop_material_count_adjustment_postings SET movement_id=? WHERE id=?",movement,posting);
            db.execute("SET CONSTRAINTS ALL IMMEDIATE");
        });
    }
}
