package com.uten.imp.features.rd_task;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;

import java.sql.Connection;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;

/** Real service SQL over rollback-only migrated column shapes, including its count and paging. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class RdTaskSearchPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private Connection connection;
    private JdbcTemplate db;
    private RdTaskService service;
    private final UUID assignee=UUID.randomUUID();

    @BeforeAll static void baseline() throws Exception { database=MigratedSchemaBaseline.openDatabase("rd_task_search"); }
    @AfterAll static void closeBaseline() throws Exception { if(database!=null) database.close(); }
    @BeforeEach void projection() throws Exception {
        connection=database.openConnection();
        connection.setAutoCommit(false);
        try(var statement=connection.createStatement()) {
            statement.execute("CREATE SCHEMA rd_search_oracle");
            statement.execute("SET LOCAL search_path=rd_search_oracle,public");
        }
        MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(connection,"rd_tasks","goods","colors","employees");
        db=new JdbcTemplate(new SingleConnectionDataSource(connection,true));
        service=new RdTaskService(db,mock(BusinessEventPublisher.class),mock(SecurityContextCurrentUser.class),mock(TxSessionVars.class));
    }
    @AfterEach void rollback() throws Exception { if(connection!=null) { connection.rollback();connection.close(); } }

    @Test void goodsNamesPrecedeBillMatchesAndUrgencyBeforePagingWithAllFiltersKept() {
        UUID near=task("R-NEAR","NEAR","Metric Screw extra","URGENT","BOM",assignee);
        UUID exact=task("R-NAME","PART","Metric Screw","NORMAL","BOM",assignee);
        UUID bill=task("Metric Screw","OTHER","unrelated","NORMAL","BOM",assignee);
        task("Metric Screw","PRIVATE","Metric Screw","URGENT","BOM",UUID.randomUUID());
        task("Metric Screw","OTHER-CATEGORY","Metric Screw","URGENT","DRAWING",assignee);
        var first=service.list("pending","BOM","Metric Screw",assignee,1,1);
        assertThat(first.getTotal()).isEqualTo(3);
        assertThat(first.getTotalPages()).isEqualTo(3);
        assertThat(first.getItems()).extracting(RdTaskContracts.RdTaskRow::id).containsExactly(exact);
        assertThat(service.list("pending","BOM","Metric Screw",assignee,2,1).getItems())
                .extracting(RdTaskContracts.RdTaskRow::id).containsExactly(near);
        assertThat(service.list("pending","BOM","Metric Screw",assignee,3,1).getItems())
                .extracting(RdTaskContracts.RdTaskRow::id).containsExactly(bill);
        assertThat(service.list("pending","BOM","R-NAME Screw",assignee,1,20).getItems())
                .extracting(RdTaskContracts.RdTaskRow::id).containsExactly(exact);
    }

    @Test void wildcardCharactersAreLiteralAndWordsCanMatchTaskGoodsAndVisibleEmployeeIndependently() {
        UUID person=UUID.randomUUID();
        db.update("INSERT INTO employees(id,full_name,is_deleted) VALUES(?,'张工程师',FALSE)",person);
        UUID literal=task("RD-LITERAL","A%_B","特殊物料","NORMAL","BOM",person);
        task("RD-APPROX","AxYB","特殊物料","URGENT","BOM",person);
        assertThat(service.list("open",null,"A%_B",null,1,20).getItems())
                .extracting(RdTaskContracts.RdTaskRow::id).containsExactly(literal);
        assertThat(service.list("open",null,"LITERAL 张工程师 物料",null,1,20).getItems())
                .extracting(RdTaskContracts.RdTaskRow::id).containsExactly(literal);
    }

    private UUID task(String number,String code,String name,String priority,String category,UUID employee) {
        UUID id=UUID.randomUUID(), goods=UUID.randomUUID();
        db.update("INSERT INTO goods(id,code,name,is_deleted) VALUES(?,?,?,FALSE)",goods,code,name);
        db.update("""
                INSERT INTO rd_tasks(id,task_no,title,goods_id,category,status,priority,assignee_employee_id,
                                     created_at,is_deleted,row_version)
                VALUES(?,?,?,? ,?,'OPEN',?,?,'2026-10-16T00:00:00Z',FALSE,0)
                """,id,number,name,goods,category,priority,employee);
        return id;
    }
}
