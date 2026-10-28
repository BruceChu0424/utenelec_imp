package com.uten.imp.features.org.employee;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;

import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Real current-schema SQL and a two-connection enrollment race, without replacing source tables. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class EmployeeNameReviewPolicyPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private static JdbcTemplate jdbc;
    private static DataSourceTransactionManager transactions;
    @BeforeAll static void open() throws Exception {
        database=MigratedSchemaBaseline.openDatabase("employee_name_review");
        var dataSource=new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword());
        jdbc=new JdbcTemplate(dataSource); transactions=new DataSourceTransactionManager(dataSource);
    }
    @AfterAll static void close() throws Exception {if(database!=null)database.close();}

    @Test void missingSameNameSensitiveRowStillRequiresReviewWhileUnrelatedAndDeletedNamesDoNot() {
        UUID department=department(); String name="同名核验"+UUID.randomUUID();
        employee(department,name,"resigned",false);
        var tx=mock(TxSessionVars.class);var policy=new EmployeeNameReviewPolicy(jdbc,tx);
        assertThrows(ApiException.class,()->transaction().executeWithoutResult(status->
                policy.requireNewIdentity("  "+name+"  ","其他",null,false,null)));
        assertDoesNotThrow(()->transaction().executeWithoutResult(status->
                policy.requireNewIdentity("另一名字"+name,"其他",null,false,null)));
        String deleted="已删同名"+UUID.randomUUID();employee(department,deleted,"resigned",true);
        assertDoesNotThrow(()->transaction().executeWithoutResult(status->
                policy.requireNewIdentity(deleted,"其他",null,false,null)));
        verifyNoInteractions(tx);
    }

    @Test void twoConcurrentUnreviewedEnrollmentsCannotCreateTwoCurrentSameNameIdentities() throws Exception {
        UUID department=department(); String name="并发同名"+UUID.randomUUID();
        var tx=mock(TxSessionVars.class);var policy=new EmployeeNameReviewPolicy(jdbc,tx);
        CountDownLatch firstInserted=new CountDownLatch(1),releaseFirst=new CountDownLatch(1),secondStarted=new CountDownLatch(1);
        AtomicInteger firstPid=new AtomicInteger(),secondPid=new AtomicInteger();
        try(var workers=Executors.newFixedThreadPool(2)) {
            var first=workers.submit(()->transaction().execute(status->{
                firstPid.set(jdbc.queryForObject("SELECT pg_backend_pid()",Integer.class));
                policy.requireNewIdentity(name,"其他",null,false,null);
                employee(department,name,"active",false);firstInserted.countDown();
                try {assertTrue(releaseFirst.await(10,TimeUnit.SECONDS));}
                catch(InterruptedException interrupted){throw new IllegalStateException(interrupted);}
                return true;
            }));
            assertTrue(firstInserted.await(10,TimeUnit.SECONDS));
            var second=workers.submit(()->{
                try {
                    transaction().executeWithoutResult(status->{
                        secondPid.set(jdbc.queryForObject("SELECT pg_backend_pid()",Integer.class));secondStarted.countDown();
                        policy.requireNewIdentity(name,"其他",null,false,null);
                        employee(department,name,"active",false);
                    });
                    return null;
                } catch(ApiException conflict){return conflict.getCode();}
            });
            assertTrue(secondStarted.await(5,TimeUnit.SECONDS));
            boolean blocked=false;long deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(5);
            while(System.nanoTime()<deadline) {
                blocked=Boolean.TRUE.equals(jdbc.queryForObject(
                        "SELECT ?=ANY(pg_blocking_pids(?))",Boolean.class,firstPid.get(),secondPid.get()));
                if(blocked)break;
                Thread.sleep(20);
            }
            assertTrue(blocked,"equal-name enrollment must wait on the first transaction's advisory lock");
            releaseFirst.countDown();
            assertTrue(first.get(10,TimeUnit.SECONDS));
            assertEquals(ErrorCode.CONFLICT,second.get(10,TimeUnit.SECONDS));
            assertEquals(1,jdbc.queryForObject("SELECT count(*) FROM employees WHERE btrim(full_name)=?",Integer.class,name));
            verifyNoInteractions(tx);
        } finally {releaseFirst.countDown();}
    }

    private static TransactionTemplate transaction() {
        var transaction=new TransactionTemplate(transactions);
        transaction.setIsolationLevel(TransactionDefinition.ISOLATION_READ_COMMITTED);
        transaction.setTimeout(15);return transaction;
    }
    private static UUID department() {
        UUID id=UUID.randomUUID();jdbc.update("INSERT INTO departments(id,code,name,level) VALUES (?,?,?,'一级部门')",
                id,"NAME-D-"+id,"同名核验测试部门");return id;
    }
    private static void employee(UUID department,String name,String status,boolean deleted) {
        UUID id=UUID.randomUUID();jdbc.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type,is_deleted)
                VALUES (?,?,?,'其他',?,DATE '2026-01-01',?,'regular',?)
                """,id,"NAME-E-"+id,name,department,status,deleted);
    }
}
