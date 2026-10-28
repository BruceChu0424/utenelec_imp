package com.uten.imp.features.rd_task;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;

import java.sql.Connection;
import java.util.UUID;
import java.util.Optional;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** Real service SQL over rollback-only migrated column shapes, including its count and paging. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class RdTaskSearchPostgresTest {
    private static MigratedSchemaBaseline.ScopedDatabase database;
    private Connection connection;
    private JdbcTemplate db;
    private RdTaskService service;
    private SecurityContextCurrentUser currentUser;
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
        currentUser=mock(SecurityContextCurrentUser.class);
        service=new RdTaskService(db,mock(BusinessEventPublisher.class),currentUser,mock(TxSessionVars.class));
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

    @Test void taskCountsUseExactActionsCategoryAndAssigneeWithoutNarrowingNormalBrowsing() {
        task("RD-BOM-POOL","BP","pooled BOM","NORMAL","BOM",null);
        task("RD-BOM-MINE","BM","my BOM","NORMAL","BOM",assignee);
        task("RD-BOM-OTHER","BO","other BOM","NORMAL","BOM",UUID.randomUUID());
        UUID running=task("RD-BOM-RUN","BR","running BOM","NORMAL","BOM",assignee);
        db.update("UPDATE rd_tasks SET status='IN_PROGRESS' WHERE id=?",running);
        task("RD-DRAW-MINE","DM","my drawing","NORMAL","DRAWING",assignee);
        UUID noGoods=task("RD-NO-GOODS","NG","missing goods","NORMAL","BOM",assignee);
        db.update("UPDATE rd_tasks SET goods_id=NULL WHERE id=?",noGoods);

        actor(Set.of("rd_task:view"));
        assertThat(service.counts()).isEqualTo(new RdTaskService.RdTaskCounts(0,0));
        for(String action: java.util.List.of("goods:bom:create","goods:bom:edit")) {
            actor(Set.of("rd_task:view","goods:view",action));
            assertThat(service.counts()).isEqualTo(new RdTaskService.RdTaskCounts(2,1));
            actor(Set.of("rd_task:view",action));
            assertThat(service.counts()).isEqualTo(new RdTaskService.RdTaskCounts(0,0));
        }
        actor(Set.of("rd_task:view","goods:view","goods:bom:delete"));
        assertThat(service.counts()).isEqualTo(new RdTaskService.RdTaskCounts(0,0));
        actor(Set.of("rd_task:view","rd_task:resolve"));
        assertThat(service.counts()).isEqualTo(new RdTaskService.RdTaskCounts(4,1));
        assertThat(service.list("open",null,null,null,1,20).getTotal()).isEqualTo(6);
    }

    @Test void ordinaryHeadersFilterCompleteScopeAndPreserveLocalDueDatesBeforePaging() {
        db.update("INSERT INTO employees(id,full_name,is_deleted) VALUES(?,'列查询工程师',FALSE)",assignee);
        UUID first=task("HEADER-01","P%_A","列查询物料","URGENT","BOM",assignee);
        UUID second=task("HEADER-02","P%_B","列查询物料","URGENT","BOM",assignee);
        UUID nextDay=task("HEADER-03","P%_C","列查询物料","URGENT","BOM",assignee);
        UUID canceled=task("HEADER-04","P%_D","列查询物料","URGENT","BOM",assignee);
        task("HEADER-PRIVATE","P%_E","列查询物料","URGENT","BOM",UUID.randomUUID());
        db.update("UPDATE rd_tasks SET due_date='2026-10-28',created_at='2026-10-27T16:00:00Z',status='DONE' WHERE id IN (?,?,?)",
                first,second,canceled);
        db.update("UPDATE rd_tasks SET status='CANCELED' WHERE id=?",canceled);
        db.update("UPDATE rd_tasks SET due_date='2026-10-29',created_at='2026-10-28T16:00:00Z',status='DONE' WHERE id=?",nextDay);
        var columns=java.util.Map.of("taskNo","HEADER", "goodsCode","P%_", "goods","列查询",
                "assignee","列查询工程师", "dueDate","2026-10-28", "createdAt","2026-10-28",
                "status","DONE", "priority","URGENT");
        var page1=service.list("done","BOM",null,assignee,1,1,columns,"taskNo","asc");
        var page2=service.list("done","BOM",null,assignee,2,1,columns,"taskNo","asc");
        assertThat(page1.getTotal()).isEqualTo(2);
        assertThat(page1.getTotalPages()).isEqualTo(2);
        assertThat(page1.getItems()).extracting(RdTaskContracts.RdTaskRow::id).containsExactly(first);
        assertThat(page2.getItems()).extracting(RdTaskContracts.RdTaskRow::id).containsExactly(second);
        assertThat(page1.getItems().getFirst().dueDate()).isEqualTo(java.time.LocalDate.of(2026,10,28));
        assertThat(service.list("done",null,null,assignee,1,20,java.util.Map.of("status","CANCELED"),null,null).getItems())
                .extracting(RdTaskContracts.RdTaskRow::id).containsExactly(canceled);
        assertThat(service.list("pending",null,null,null,1,20,java.util.Map.of("status","DONE"),null,null).getTotal()).isZero();
        assertThat(service.list("done",null,null,assignee,1,20,java.util.Map.of("createdAt","2026-10-29"),null,null).getItems())
                .extracting(RdTaskContracts.RdTaskRow::id).containsExactly(nextDay);
    }

    @Test void bomMaintainersDoNotAcquireManualResolveAuthority() {
        UUID id=task("RD-BOM-EDIT","BE","BOM edit only","NORMAL","BOM",assignee);
        actor(Set.of("rd_task:view","goods:view","goods:bom:edit"));
        assertThat(service.get(id).allowedActions()).doesNotContain("RESOLVE");
        org.assertj.core.api.Assertions.assertThatThrownBy(() -> service.resolve(id,0,"done"))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class)
                .hasMessageContaining("权限或责任范围");
        assertThat(db.queryForObject("SELECT status FROM rd_tasks WHERE id=?",String.class,id)).isEqualTo("OPEN");
    }

    private void actor(Set<String> permissions) {
        when(currentUser.get()).thenReturn(Optional.of(new AuthUser(UUID.randomUUID(),assignee,
                "engineer",permissions,false,true,false)));
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
