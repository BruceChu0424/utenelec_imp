package com.uten.imp.features.finance.procurement;

import com.uten.imp.support.MigratedProjectionSchema;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;

/** Real migrated row/read-function shapes and actual production WHERE text.
 * This is a read-projection oracle; unrelated business write triggers are not
 * installed and no submit/approve authorization is inferred from these seeds. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ProcurementApprovalReturnedQueuePostgresTest {
    static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine").withReuse(false);
    static JdbcTemplate db;
    @BeforeAll static void start(){
        PG.start();db=new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()));
        MigratedProjectionSchema.createCurrentTables(db,"procurement_order_approval_cases","purchase_orders","subcontract_orders","imported_document_registry");
        MigratedProjectionSchema.createCurrentFunctions(db,"fn_imported_business_document_roots","fn_imported_business_document_maintenance_allowed","fn_imported_business_document_table","fn_imported_business_document_scope_table","fn_imported_business_document_direct_key","fn_imported_business_document_registered","fn_imported_business_document_row_internal","fn_imported_business_document_row","fn_imported_business_document");
    }
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void empty(){db.update("DELETE FROM procurement_order_approval_cases");db.update("DELETE FROM purchase_orders");db.update("DELETE FROM subcontract_orders");}

    @Test void aRejectedRoundLeavesWorkAfterResubmissionAndRemainsHistoricalAfterApproval(){
        UUID order=order("PURCHASE","PO-A");UUID rejected=round("PURCHASE",order,1,"REJECTED","ORDER","PO-A");
        assertEquals(List.of(rejected),ids("RETURNED"));
        UUID submitted=round("PURCHASE",order,2,"PENDING","ORDER","PO-A");
        assertTrue(ids("RETURNED").isEmpty());assertEquals(List.of(rejected),ids("HISTORY"));assertEquals(List.of(submitted),ids("PENDING"));
        db.update("UPDATE procurement_order_approval_cases SET status='APPROVED' WHERE id=?",submitted);
        db.update("UPDATE purchase_orders SET status=1 WHERE id=?",order);
        assertTrue(ids("RETURNED").isEmpty());assertEquals(Set.of(rejected,submitted),new HashSet<>(ids("HISTORY")));
        String where=predicate("HISTORY");
        var first=db.queryForList("SELECT c.id FROM procurement_order_approval_cases c WHERE "+where+" ORDER BY c.id LIMIT 1",UUID.class);
        var second=db.queryForList("SELECT c.id FROM procurement_order_approval_cases c WHERE "+where+" ORDER BY c.id LIMIT 1 OFFSET 1",UUID.class);
        assertEquals(1,first.size());assertEquals(1,second.size());assertNotEquals(first,second);
        assertEquals(2L,count("HISTORY"));
    }

    @Test void aCurrentCanceledDraftStillNeedsWorkButClosedDeletedTerminatedAndImportedOrdersDoNot(){
        UUID order=order("SUBCONTRACT","SO-B");UUID canceled=round("SUBCONTRACT",order,1,"CANCELED","ORDER","SO-B");
        assertEquals(List.of(canceled),ids("RETURNED"));assertTrue(ids("HISTORY").isEmpty());
        // A closure record never replaces the latest ORDER identity.
        UUID closure=round("SUBCONTRACT",order,2,"CANCELED","CLOSE","SO-B");
        assertEquals(List.of(canceled),ids("RETURNED"));assertEquals(List.of(closure),ids("HISTORY"));
        for(String terminal:List.of("is_closed=TRUE","is_deleted=TRUE","termination_case_id='"+UUID.randomUUID()+"'::uuid")){
            db.update("UPDATE subcontract_orders SET "+terminal+" WHERE id=?",order);
            assertTrue(ids("RETURNED").isEmpty());assertTrue(ids("HISTORY").contains(canceled));
            db.update("UPDATE subcontract_orders SET is_closed=FALSE,is_deleted=FALSE,termination_case_id=NULL WHERE id=?",order);
        }
        db.update("UPDATE subcontract_orders SET legacy_id=771 WHERE id=?",order);
        assertTrue(ids("RETURNED").isEmpty());
        // Imported records keep their separate archive-read contract; this
        // test does not widen the service's existing imported-case WHERE.
    }

    @Test void returnedRowsAreFilteredBeforeLimitsAndUseTheSameCountBillAndTypeSlice(){
        UUID old=order("PURCHASE","PO-A");round("PURCHASE",old,1,"REJECTED","ORDER","PO-A");round("PURCHASE",old,2,"APPROVED","ORDER","PO-A");db.update("UPDATE purchase_orders SET status=1 WHERE id=?",old);
        UUID purchase=order("PURCHASE","PO-B"), subcontract=order("SUBCONTRACT","SO-C");
        UUID work=round("PURCHASE",purchase,1,"CANCELED","ORDER","PO-B");round("SUBCONTRACT",subcontract,1,"REJECTED","ORDER","SO-C");
        String where=predicate("RETURNED");
        assertEquals(List.of(work),db.queryForList("SELECT c.id FROM procurement_order_approval_cases c WHERE "+where+" ORDER BY c.bill_no_snapshot,c.id LIMIT 1",UUID.class));
        assertEquals(2L,count("RETURNED"));
        assertEquals(List.of("PO-B","SO-C"),db.queryForList("SELECT c.bill_no_snapshot FROM procurement_order_approval_cases c WHERE "+where+" GROUP BY c.bill_no_snapshot ORDER BY 1",String.class));
        var types=new LinkedHashMap<String,Long>();db.query("SELECT c.order_type,count(*) FROM procurement_order_approval_cases c WHERE "+where+" GROUP BY c.order_type",row->{types.put(row.getString(1),row.getLong(2));});
        assertEquals(Map.of("PURCHASE",1L,"SUBCONTRACT",1L),types);
        Object filters=ReflectionTestUtils.invokeMethod(ProcurementFinanceApprovalService.class,"taskFilters","PURCHASE",null," PO-B ");
        String sql=ReflectionTestUtils.invokeMethod(filters,"sql");List<?> args=ReflectionTestUtils.invokeMethod(filters,"args");
        assertEquals(List.of(work),db.queryForList("SELECT c.id FROM procurement_order_approval_cases c WHERE "+where+sql,UUID.class,args.toArray()));
        assertEquals(1L,db.queryForObject("SELECT count(*) FROM procurement_order_approval_cases c WHERE "+where+sql,Long.class,args.toArray()));
        assertEquals(List.of("PO-B"),db.queryForList("SELECT c.bill_no_snapshot FROM procurement_order_approval_cases c WHERE "+where+sql+" GROUP BY c.bill_no_snapshot",String.class,args.toArray()));
    }

    private static String predicate(String status){return ReflectionTestUtils.invokeMethod(ProcurementFinanceApprovalService.class,"queueStatusFilter",status);}
    private static List<UUID> ids(String status){return db.queryForList("SELECT c.id FROM procurement_order_approval_cases c WHERE "+predicate(status)+" ORDER BY c.id",UUID.class);}
    private static long count(String status){return db.queryForObject("SELECT count(*) FROM procurement_order_approval_cases c WHERE "+predicate(status),Long.class);}
    private static UUID order(String type,String bill){UUID id=UUID.randomUUID();db.update("INSERT INTO "+(type.equals("PURCHASE")?"purchase":"subcontract")+"_orders(id,bill_no,bill_date,status,is_deleted,is_closed) VALUES(?,?,current_date,0,false,false)",id,bill);return id;}
    private static UUID round(String type,UUID order,int attempt,String status,String request,String bill){UUID id=UUID.randomUUID();String snapshot="{\"orderType\":\""+type+"\",\"orderId\":\""+order+"\",\"items\":[]}";db.update("INSERT INTO procurement_order_approval_cases(id,order_type,order_id,attempt,status,request_type,bill_no_snapshot,submission_snapshot,snapshot_hash,version) VALUES(?,?,?,?,?,?,?,?::jsonb,?,1)",id,type,order,attempt,status,request,bill,snapshot,"0".repeat(64));return id;}
}
