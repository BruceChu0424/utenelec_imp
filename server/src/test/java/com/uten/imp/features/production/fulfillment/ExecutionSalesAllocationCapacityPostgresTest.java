package com.uten.imp.features.production.fulfillment;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.postgresql.util.PSQLException;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.DriverManager;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

/** Focused real PostgreSQL trigger/isolation mechanics; FullChain verifies the actual package lifecycle. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ExecutionSalesAllocationCapacityPostgresTest {
    static final PostgreSQLContainer<?> DB=new PostgreSQLContainer<>("postgres:16-alpine");
    @BeforeAll static void start() throws Exception {
        DB.start();
        try(var c=connection()) {
            sql(c,"CREATE TABLE production_planning_packages(id uuid PRIMARY KEY,status text NOT NULL,is_deleted boolean NOT NULL DEFAULT false)");
            sql(c,"CREATE TABLE plan_order_item_links(id uuid PRIMARY KEY,plan_item_id uuid NOT NULL,order_item_id uuid NOT NULL,allocated_qty numeric(18,4) NOT NULL,is_deleted boolean NOT NULL DEFAULT false,updated_by uuid)");
            sql(c,"CREATE TABLE production_execution_segments(id uuid PRIMARY KEY,source_plan_item_id uuid NOT NULL,planned_qty numeric(18,4) NOT NULL,status text NOT NULL,package_id uuid NOT NULL REFERENCES production_planning_packages(id),is_deleted boolean NOT NULL DEFAULT false,responsible_employee_id uuid)");
            sql(c,"CREATE TABLE execution_segment_sales_allocations(id uuid PRIMARY KEY,execution_segment_id uuid NOT NULL REFERENCES production_execution_segments(id),plan_order_item_link_id uuid NOT NULL REFERENCES plan_order_item_links(id),sales_order_item_id uuid NOT NULL,allocated_qty numeric(18,4) NOT NULL,UNIQUE(execution_segment_id,plan_order_item_link_id))");
            String original=resource("db/migration/V157__execution_segment_sales_allocations.sql");
            int validator=original.indexOf("CREATE OR REPLACE FUNCTION fn_validate_execution_segment_sales_allocation()");
            int assertion=original.indexOf("CREATE OR REPLACE FUNCTION fn_assert_execution_segment_sales_allocation(");
            sql(c,original.substring(validator,assertion));
            sql(c,resource("db/migration/V508__execution_sales_allocation_active_capacity.sql"));
            int rowTriggers=original.indexOf("CREATE OR REPLACE FUNCTION fn_assert_execution_segment_sales_allocation_row()");
            int linkFunction=original.indexOf("CREATE OR REPLACE FUNCTION fn_assert_plan_link_execution_allocations()");
            sql(c,original.substring(rowTriggers,linkFunction));
            int linkTrigger=original.indexOf("CREATE CONSTRAINT TRIGGER trg_assert_plan_link_execution_allocations");
            int report=original.indexOf("CREATE OR REPLACE FUNCTION fn_validate_daily_report_execution_segment()");
            sql(c,original.substring(linkTrigger,report));
        }
    }
    @AfterAll static void stop(){DB.stop();}

    @Test void cancelledAndReversedHistoryRemainImmutableButDoNotConsumeCurrentCapacity() throws Exception {
        for(String retired:List.of("CANCELLED","REVERSED"))try(var c=connection()) {
            Fixture f=fixture(c); UUID old=allocate(c,f,"10",retired,false);
            allocate(c,f,"10","READY",false);
            assertEquals(0,total(c,f).compareTo(new BigDecimal("20")),"historical rows are retained");
            var update=assertThrows(PSQLException.class,()->sql(c,"UPDATE execution_segment_sales_allocations SET allocated_qty=9 WHERE id=?",old));
            assertEquals("execution_segment_sales_allocation_immutable_guard",update.getServerErrorMessage().getConstraint());
            var delete=assertThrows(PSQLException.class,()->sql(c,"DELETE FROM execution_segment_sales_allocations WHERE id=?",old));
            assertEquals("execution_segment_sales_allocation_immutable_guard",delete.getServerErrorMessage().getConstraint());
        }
    }

    @Test void completedAndHiddenPhysicalHistoryStillConsumesCapacity() throws Exception {
        for(String status:List.of("READY","WAITING","IN_PROGRESS","COMPLETED"))try(var c=connection()) {
            Fixture f=fixture(c); allocate(c,f,"10",status,"COMPLETED".equals(status));
            var error=assertThrows(PSQLException.class,()->allocate(c,f,"1","READY",false));
            assertEquals("execution_segment_sales_link_capacity_guard",error.getServerErrorMessage().getConstraint());
            assertEquals(0,total(c,f).compareTo(new BigDecimal("10")));
        }
    }

    @Test void readCommittedConcurrentSixPlusSixOnTenCommitsExactlyOneWithoutFkLockUpgradeDeadlock() throws Exception {
        Fixture f; try(var c=connection()){f=fixture(c);}
        var inserted=new CountDownLatch(2); var commit=new CountDownLatch(1);
        try(var workers=Executors.newFixedThreadPool(2)) {
            var first=workers.submit(()->concurrentAllocation(f,inserted,commit));
            var second=workers.submit(()->concurrentAllocation(f,inserted,commit));
            assertTrue(inserted.await(8,TimeUnit.SECONDS)); commit.countDown();
            List<String> outcomes=List.of(first.get(10,TimeUnit.SECONDS),second.get(10,TimeUnit.SECONDS));
            assertEquals(1,outcomes.stream().filter("committed"::equals).count());
            assertEquals(1,outcomes.stream().filter("23514:execution_segment_sales_link_capacity_guard"::equals).count());
        } finally {commit.countDown();}
        try(var c=connection()){assertEquals(0,total(c,f).compareTo(new BigDecimal("6")));}
    }

    @Test void snapshotIsolationCapacityWritesAreRejectedWhileMetadataUpdatesRemainAllowed() throws Exception {
        for(int isolation:List.of(Connection.TRANSACTION_REPEATABLE_READ,Connection.TRANSACTION_SERIALIZABLE))try(var c=connection()) {
            Fixture f=fixture(c); UUID old=allocate(c,f,"6","READY",false);
            c.setTransactionIsolation(isolation);
            var insert=assertThrows(PSQLException.class,()->allocate(c,f,"1","READY",false));
            assertEquals("execution_sales_allocation_isolation_guard",insert.getServerErrorMessage().getConstraint());
            c.setAutoCommit(false);
            sql(c,"UPDATE plan_order_item_links SET allocated_qty=5 WHERE id=?",f.link);
            var shrink=assertThrows(PSQLException.class,c::commit); c.rollback(); c.setAutoCommit(true);
            assertEquals("execution_sales_allocation_isolation_guard",shrink.getServerErrorMessage().getConstraint());
            // RR handover/audit metadata is not a new capacity claim.
            sql(c,"UPDATE plan_order_item_links SET updated_by=? WHERE id=?",UUID.randomUUID(),f.link);
            sql(c,"UPDATE production_execution_segments SET responsible_employee_id=? WHERE id=(SELECT execution_segment_id FROM execution_segment_sales_allocations WHERE id=?)",UUID.randomUUID(),old);
            assertEquals(0,total(c,f).compareTo(new BigDecimal("6")));
        }
    }

    static String concurrentAllocation(Fixture f,CountDownLatch inserted,CountDownLatch commit) throws Exception {
        try(var c=connection()) {
            c.setAutoCommit(false); insert(c,f,"6","READY",false); inserted.countDown();
            assertTrue(commit.await(8,TimeUnit.SECONDS));
            try {c.commit();return "committed";}
            catch(PSQLException e){c.rollback();return e.getSQLState()+":"+e.getServerErrorMessage().getConstraint();}
        }
    }
    static UUID allocate(Connection c,Fixture f,String quantity,String status,boolean hidden) throws Exception {
        c.setAutoCommit(false);
        try {UUID id=insert(c,f,quantity,status,hidden);c.commit();return id;}
        catch(Exception e){c.rollback();throw e;}
        finally {c.setAutoCommit(true);}
    }
    static UUID insert(Connection c,Fixture f,String quantity,String status,boolean hidden) throws Exception {
        UUID segment=UUID.randomUUID(),allocation=UUID.randomUUID(),pkg=UUID.randomUUID();
        sql(c,"INSERT INTO production_planning_packages(id,status,is_deleted) VALUES (?,'CONFIRMED',?)",pkg,hidden);
        // A hidden package does not erase a completed segment's physical obligation.
        sql(c,"INSERT INTO production_execution_segments(id,source_plan_item_id,planned_qty,status,package_id) VALUES (?,?,?,?,?)",segment,f.planItem,new BigDecimal(quantity),status,pkg);
        sql(c,"INSERT INTO execution_segment_sales_allocations(id,execution_segment_id,plan_order_item_link_id,sales_order_item_id,allocated_qty) VALUES (?,?,?,?,?)",allocation,segment,f.link,f.orderItem,new BigDecimal(quantity));
        return allocation;
    }
    static Fixture fixture(Connection c) throws Exception {
        Fixture f=new Fixture(UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID());
        sql(c,"INSERT INTO plan_order_item_links(id,plan_item_id,order_item_id,allocated_qty) VALUES (?,?,?,10)",f.link,f.planItem,f.orderItem);return f;
    }
    static BigDecimal total(Connection c,Fixture f) throws Exception {
        try(var p=c.prepareStatement("SELECT COALESCE(SUM(allocated_qty),0) FROM execution_segment_sales_allocations WHERE plan_order_item_link_id=?")) {
            p.setObject(1,f.link);try(var r=p.executeQuery()){assertTrue(r.next());return r.getBigDecimal(1);}
        }
    }
    static void sql(Connection c,String sql,Object...values) throws Exception {
        try(var s=c.prepareStatement(sql)){for(int i=0;i<values.length;i++)s.setObject(i+1,values[i]);s.execute();}
    }
    static Connection connection() throws Exception {return DriverManager.getConnection(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword());}
    static String resource(String name) throws Exception {
        try(var in=ExecutionSalesAllocationCapacityPostgresTest.class.getClassLoader().getResourceAsStream(name)) {
            assertNotNull(in);return new String(in.readAllBytes(),StandardCharsets.UTF_8);
        }
    }
    record Fixture(UUID link,UUID planItem,UUID orderItem){}
}
