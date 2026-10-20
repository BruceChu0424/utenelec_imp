package com.uten.imp.features.rd_task;

import com.uten.imp.application.port.RdMaterialIssuePort;
import com.uten.imp.common.docnumber.DocNumberService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;

import java.util.List;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;

/** Real migrated tables: a master repair must never merge with, or auto-complete as, a missing-BOM task. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class RdMaterialIssuePostgresTest {
    static MigratedSchemaBaseline.ScopedDatabase database;
    static DriverManagerDataSource dataSource;
    JdbcTemplate jdbc;
    SecurityContextCurrentUser current;
    RdMaterialIssueService service;
    UUID reporter;
    UUID actor;
    com.uten.imp.application.port.GoodsMasterWriteAccessPort goodsAccess;
    static final AtomicInteger TASK_SEQUENCE=new AtomicInteger(900000);

    @BeforeAll static void database() throws Exception {
        database = MigratedSchemaBaseline.openDatabase("material_issue");
        dataSource = new DriverManagerDataSource(database.getJdbcUrl(),database.getUsername(),database.getPassword());
    }
    @AfterAll static void close() throws Exception { if(database!=null) database.close(); }
    @BeforeEach void fixture() {
        jdbc = new JdbcTemplate(dataSource);
        current = mock(SecurityContextCurrentUser.class);
        reporter = UUID.randomUUID();
        when(current.requireEmployeeId()).thenReturn(reporter);
        actor=UUID.randomUUID();
        when(current.requireId()).thenReturn(actor);
        when(current.get()).thenReturn(java.util.Optional.of(new com.uten.imp.security.AuthUser(actor,reporter,"engineer",
                java.util.Set.of("rd_task:view","goods:view","goods:edit","unit:view"),false,true,false)));
        DocNumberService numbers = mock(DocNumberService.class);
        when(numbers.nextNumber(any())).thenAnswer(call -> jdbc.queryForObject("""
                SELECT fixed_prefix || to_char(CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Shanghai','YYYYMMDD')
                    || lpad(CAST(? AS text),6,'0')
                FROM business_identifier_namespaces WHERE namespace_key='RD_TASK'
                """,String.class,TASK_SEQUENCE.incrementAndGet()));
        goodsAccess=mock(com.uten.imp.application.port.GoodsMasterWriteAccessPort.class);
        service = new RdMaterialIssueService(jdbc,numbers,current,mock(TxSessionVars.class),new DataSourceTransactionManager(dataSource),goodsAccess);
    }

    @Test void repeatedAndCrossPlannerForwardsReuseOneTaskAndKeepAllWaitersAndSources() {
        UUID goods=goods();
        var target=new RdMaterialIssuePort.Target(goods,true);
        UUID analysis=UUID.randomUUID();
        String first=service.forward(target,analysis,"销售明细=SOURCE-A；组件缺少基本单位");
        assertThat(service.forward(target,analysis,"销售明细=SOURCE-A；组件缺少基本单位")).isEqualTo(first);
        UUID secondReporter=UUID.randomUUID();
        when(current.requireEmployeeId()).thenReturn(secondReporter);
        assertThat(service.forward(target,UUID.randomUUID(),"手工需求=SOURCE-B；组件缺少基本单位")).isEqualTo(first);

        assertThat(jdbc.queryForObject("SELECT count(*) FROM rd_tasks WHERE goods_id=?",Integer.class,goods)).isEqualTo(1);
        UUID task=jdbc.queryForObject("SELECT id FROM rd_tasks WHERE goods_id=?",UUID.class,goods);
        assertThat(jdbc.queryForList("SELECT reporter_employee_id FROM rd_task_forwarders WHERE rd_task_id=?",UUID.class,task))
                .containsExactlyInAnyOrder(reporter,secondReporter);
        assertThat(jdbc.queryForObject("SELECT description FROM rd_tasks WHERE id=?",String.class,task))
                .contains("SOURCE-A","SOURCE-B");
        assertThat(service.openTaskNos(List.of(target))).containsEntry(target.key(),first);
        // The ordinary BOM-save auto-completion only completes category BOM; master repairs remain current work.
        new RdTaskService(jdbc,mock(com.uten.imp.application.port.BusinessEventPublisher.class),current,mock(TxSessionVars.class))
                .resolveOpenBomTasksForGoods(goods,"BOM已保存");
        assertThat(jdbc.queryForObject("SELECT status FROM rd_tasks WHERE id=?",String.class,task)).isEqualTo("OPEN");
    }

    @Test void structureAndMasterIssuesAreSeparateAndCompletedTasksDoNotBlockARealNewIssue() {
        UUID goods=goods();
        var master=new RdMaterialIssuePort.Target(goods,true);
        var bom=new RdMaterialIssuePort.Target(goods,false);
        String first=service.forward(master,null,"缺单位");
        String structure=service.forward(bom,null,"BOM循环");
        assertThat(structure).isNotEqualTo(first);
        jdbc.update("UPDATE rd_tasks SET status='DONE',completed_at=now() WHERE task_no=?",first);
        assertThat(service.openTaskNos(List.of(master,bom))).doesNotContainKey(master.key()).containsEntry(bom.key(),structure);
        assertThat(service.forward(master,null,"再次发现缺单位")).isNotEqualTo(first);
    }

    @Test void concurrentForwardsCommitExactlyOneOpenTask() throws Exception {
        UUID goods=goods();
        var target=new RdMaterialIssuePort.Target(goods,true);
        try(var workers=java.util.concurrent.Executors.newFixedThreadPool(4)) {
            var gate=new java.util.concurrent.CountDownLatch(1);
            var futures=new java.util.ArrayList<java.util.concurrent.Future<String>>();
            for(int index=0;index<4;index++) futures.add(workers.submit(() -> {
                gate.await();
                return service.forward(target,null,"并发登记同一缺单位问题");
            }));
            gate.countDown();
            var numbers=new java.util.HashSet<String>();
            for(var future:futures) numbers.add(future.get(20,java.util.concurrent.TimeUnit.SECONDS));
            assertThat(numbers).hasSize(1);
            assertThat(jdbc.queryForObject("SELECT count(*) FROM rd_tasks WHERE goods_id=?",Integer.class,goods)).isEqualTo(1);
        }
    }

    @Test void aLaterTargetFailureRollsBackTheWholeForwardBatch() {
        UUID first=goods();
        var transaction=new org.springframework.transaction.support.TransactionTemplate(new DataSourceTransactionManager(dataSource));
        org.assertj.core.api.Assertions.assertThatThrownBy(() -> transaction.execute(status -> {
            service.forward(new RdMaterialIssuePort.Target(first,true),null,"第一组问题");
            // A master was removed between diagnostics and creation of the next target.
            service.forward(new RdMaterialIssuePort.Target(UUID.randomUUID(),false),null,"第二组问题");
            return null;
        })).isInstanceOf(com.uten.imp.common.web.ApiException.class);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM rd_tasks WHERE goods_id=?",Integer.class,first)).isZero();
        assertThat(service.openTaskNos(List.of(new RdMaterialIssuePort.Target(first,true)))).isEmpty();
    }

    @Test void bomOnlyInitialAssignmentIsAuditableIdempotentAndCannotChangeAnExistingUnit() {
        UUID goods=bomOnlyGoods(), unit=unit(null);
        UUID task=task(goods);
        long originalVersion=jdbc.queryForObject("SELECT version FROM goods WHERE id=?",Long.class,goods);
        var request=new RdTaskContracts.InitialBasicUnitRequest(1L,unit,"核对原始组件图纸，数量以个计");
        service.reconcileBasicUnit(task,request);
        assertThat(jdbc.queryForObject("SELECT version FROM goods WHERE id=?",Long.class,goods)).isEqualTo(originalVersion+1);
        org.assertj.core.api.Assertions.assertThatThrownBy(()->com.uten.imp.common.concurrency.OptimisticLocks.requireUpToDate(
                jdbc.queryForObject("SELECT version FROM goods WHERE id=?",Long.class,goods),originalVersion))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class);
        assertThat(jdbc.queryForObject("SELECT unit_id FROM goods WHERE id=?",UUID.class,goods)).isEqualTo(unit);
        assertThat(jdbc.queryForObject("SELECT status FROM rd_tasks WHERE id=?",String.class,task)).isEqualTo("DONE");
        assertThat(jdbc.queryForObject("SELECT close_note FROM rd_tasks WHERE id=?",String.class,task))
                .contains("核对原始组件图纸",unit.toString());
        service.reconcileBasicUnit(task,request);
        assertThat(jdbc.queryForObject("SELECT row_version FROM rd_tasks WHERE id=?",Long.class,task)).isEqualTo(2L);
        // Display names and mutable task editor metadata are not receipt identities.
        jdbc.update("UPDATE units SET name='只' WHERE id=?",unit);
        jdbc.update("UPDATE rd_tasks SET updated_by=? WHERE id=?",UUID.randomUUID(),task);
        service.reconcileBasicUnit(task,request);
        assertThat(jdbc.queryForObject("SELECT row_version FROM rd_tasks WHERE id=?",Long.class,task)).isEqualTo(2L);
        UUID other=unit(null);
        org.assertj.core.api.Assertions.assertThatThrownBy(() -> jdbc.update("UPDATE goods SET unit_id=? WHERE id=?",other,goods))
                .isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
    }

    @Test void existingQuantityFactsAndConflictingLegacyBridgesRemainBlocked() {
        UUID withHistory=bomOnlyGoods(), unit=unit(null), warehouse=warehouse();
        jdbc.update("INSERT INTO stock_balances(warehouse_id,goods_id,qty) VALUES(?,?,3)",warehouse,withHistory);
        UUID task=task(withHistory);
        org.assertj.core.api.Assertions.assertThatThrownBy(() -> service.reconcileBasicUnit(task,
                new RdTaskContracts.InitialBasicUnitRequest(1L,unit,"原始资料核对")))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("数量事实");
        assertThat(jdbc.queryForObject("SELECT unit_id FROM goods WHERE id=?",UUID.class,withHistory)).isNull();
        var context=service.initialBasicUnitContext(task);
        assertThat(context.allowed()).isFalse();
        assertThat(context.reason()).contains("数量事实");
        int legacy=500000+Math.abs(UUID.randomUUID().hashCode()%1000000);
        UUID legacyGoods=bomOnlyGoods(legacy);
        UUID bridged=unit(legacy);
        UUID legacyTask=task(legacyGoods);
        org.assertj.core.api.Assertions.assertThatThrownBy(() -> service.reconcileBasicUnit(legacyTask,
                new RdTaskContracts.InitialBasicUnitRequest(1L,unit,"核对原始单位")))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("桥接不一致");
        service.reconcileBasicUnit(legacyTask,new RdTaskContracts.InitialBasicUnitRequest(1L,bridged,"核对原始单位桥接"));
        assertThat(jdbc.queryForObject("SELECT unit_legacy_id FROM goods WHERE id=?",Integer.class,legacyGoods)).isEqualTo(legacy);
        int retiredLegacy=legacy+2000000;
        UUID retiredGoods=bomOnlyGoods(retiredLegacy),retiredUnit=unit(retiredLegacy),retiredTask=task(retiredGoods);
        jdbc.update("UPDATE units SET is_deleted=TRUE WHERE id=?",retiredUnit);
        assertThat(service.initialBasicUnitContext(retiredTask).allowed()).isFalse();
        org.assertj.core.api.Assertions.assertThatThrownBy(()->service.reconcileBasicUnit(retiredTask,
                new RdTaskContracts.InitialBasicUnitRequest(1L,unit,"对照原始资料的人工核对")))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("桥接不一致");
    }

    @Test void unitRepairDoesNotCloseAnIndependentColorProblemAndRollbackLeavesNoPartialDecision() {
        UUID goods=bomOnlyGoods(),unit=unit(null),task=task(goods);
        // An unresolved old color has no UUID bridge and remains a separate master-data problem.
        jdbc.update("UPDATE goods SET color_legacy_id=999999 WHERE id=?",goods);
        service.reconcileBasicUnit(task,new RdTaskContracts.InitialBasicUnitRequest(1L,unit,"原图纸单位为个"));
        assertThat(jdbc.queryForObject("SELECT status FROM rd_tasks WHERE id=?",String.class,task)).isEqualTo("IN_PROGRESS");
        assertThat(jdbc.queryForObject("SELECT completed_at FROM rd_tasks WHERE id=?",java.time.OffsetDateTime.class,task)).isNull();
        var taskService=new RdTaskService(jdbc,mock(com.uten.imp.application.port.BusinessEventPublisher.class),current,mock(TxSessionVars.class));
        when(current.get()).thenReturn(java.util.Optional.of(new com.uten.imp.security.AuthUser(actor,reporter,"engineer",
                java.util.Set.of("rd_task:resolve","rd_task:view","goods:view","goods:edit","unit:view"),false,true,false)));
        org.assertj.core.api.Assertions.assertThatThrownBy(()->taskService.resolve(task,2,null))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("仍有问题");
        UUID rollbackGoods=bomOnlyGoods(),rollbackTask=task(rollbackGoods);
        var transaction=new org.springframework.transaction.support.TransactionTemplate(new DataSourceTransactionManager(dataSource));
        transaction.executeWithoutResult(status->{
            service.reconcileBasicUnit(rollbackTask,new RdTaskContracts.InitialBasicUnitRequest(1L,unit,"原始资料核对后回滚"));
            status.setRollbackOnly();
        });
        assertThat(jdbc.queryForObject("SELECT unit_id FROM goods WHERE id=?",UUID.class,rollbackGoods)).isNull();
        assertThat(jdbc.queryForObject("SELECT status FROM rd_tasks WHERE id=?",String.class,rollbackTask)).isEqualTo("OPEN");
        assertThat(jdbc.queryForObject("SELECT close_note FROM rd_tasks WHERE id=?",String.class,rollbackTask)).isNull();
    }

    @Test void goodsOwnerWriteScopeAndTaskResponsibilityAreRecheckedBeforeAnyAssignment() {
        UUID goods=bomOnlyGoods(),unit=unit(null),task=task(goods);
        doThrow(new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.NOT_FOUND,"货品不存在"))
                .when(goodsAccess).requireWritable(goods);
        org.assertj.core.api.Assertions.assertThatThrownBy(()->service.reconcileBasicUnit(task,
                new RdTaskContracts.InitialBasicUnitRequest(1L,unit,"核对原始资料")))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("货品不存在");
        assertThat(jdbc.queryForObject("SELECT unit_id FROM goods WHERE id=?",UUID.class,goods)).isNull();
        reset(goodsAccess);
        UUID otherEmployee=UUID.randomUUID();
        assertThat(jdbc.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                SELECT ?,?,'其它有效工程办理人','其他',id,CURRENT_DATE,'active','regular'
                FROM departments WHERE code='DEPT_ENG' AND NOT is_deleted
                """,otherEmployee,"UNIT-ENGINEER-"+otherEmployee)).isEqualTo(1);
        jdbc.update("UPDATE rd_tasks SET assignee_employee_id=? WHERE id=?",otherEmployee,task);
        org.assertj.core.api.Assertions.assertThatThrownBy(()->service.reconcileBasicUnit(task,
                new RdTaskContracts.InitialBasicUnitRequest(1L,unit,"核对原始资料")))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("其他办理人");
    }

    @Test void concurrentQuantityReferenceWinsBeforeRepairAndItsRollbackAllowsRepair() throws Exception {
        for(boolean commit:List.of(true,false)) {
            UUID goods=bomOnlyGoods(),unit=unit(null),task=task(goods),warehouse=warehouse();
            try(var reference=dataSource.getConnection();var workers=java.util.concurrent.Executors.newSingleThreadExecutor()) {
                reference.setAutoCommit(false);
                try(var statement=reference.prepareStatement("INSERT INTO stock_balances(warehouse_id,goods_id,qty) VALUES(?,?,4)")) {
                    statement.setObject(1,warehouse);statement.setObject(2,goods);statement.executeUpdate();
                }
                var started=new java.util.concurrent.CountDownLatch(1);
                var repair=workers.submit(()->{
                    started.countDown();
                    service.reconcileBasicUnit(task,new RdTaskContracts.InitialBasicUnitRequest(1L,unit,"等待引用事务后核对"));
                });
                started.await();
                Thread.sleep(150);
                assertThat(repair.isDone()).isFalse();
                if(commit) reference.commit();else reference.rollback();
                if(commit) {
                    org.assertj.core.api.Assertions.assertThatThrownBy(()->repair.get(15,java.util.concurrent.TimeUnit.SECONDS))
                            .hasCauseInstanceOf(com.uten.imp.common.web.ApiException.class);
                    assertThat(jdbc.queryForObject("SELECT unit_id FROM goods WHERE id=?",UUID.class,goods)).isNull();
                } else {
                    repair.get(15,java.util.concurrent.TimeUnit.SECONDS);
                    assertThat(jdbc.queryForObject("SELECT unit_id FROM goods WHERE id=?",UUID.class,goods)).isEqualTo(unit);
                }
            }
        }
    }

    private UUID task(UUID goods) {
        String number=service.forward(new RdMaterialIssuePort.Target(goods,true),null,"核对首次基本单位");
        return jdbc.queryForObject("SELECT id FROM rd_tasks WHERE task_no=?",UUID.class,number);
    }

    private UUID bomOnlyGoods() {
        return bomOnlyGoods(null);
    }
    private UUID bomOnlyGoods(Integer legacy) {
        UUID goods=goods(),parent=goods(),unit=unit(null);
        if(legacy!=null) jdbc.update("UPDATE goods SET unit_legacy_id=? WHERE id=?",legacy,goods);
        jdbc.update("UPDATE goods SET unit_id=? WHERE id=?",unit,parent);
        jdbc.update("INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty,sort_order) VALUES(?,?,?,1,1)",UUID.randomUUID(),parent,goods);
        return goods;
    }

    @Test void aConcurrentUnitDisableCannotRaceTheExplicitActiveUnitChoice() throws Exception {
        UUID goods=bomOnlyGoods(),unit=unit(null),task=task(goods);
        try(var change=dataSource.getConnection();var workers=java.util.concurrent.Executors.newSingleThreadExecutor()) {
            change.setAutoCommit(false);
            try(var statement=change.prepareStatement("UPDATE units SET status='禁用' WHERE id=?")) {
                statement.setObject(1,unit);statement.executeUpdate();
            }
            var started=new java.util.concurrent.CountDownLatch(1);
            var repair=workers.submit(()->{started.countDown();service.reconcileBasicUnit(task,
                    new RdTaskContracts.InitialBasicUnitRequest(1L,unit,"原始资料确认单位"));});
            started.await();Thread.sleep(150);assertThat(repair.isDone()).isFalse();
            change.commit();
            org.assertj.core.api.Assertions.assertThatThrownBy(()->repair.get(15,java.util.concurrent.TimeUnit.SECONDS))
                    .hasCauseInstanceOf(com.uten.imp.common.web.ApiException.class);
        }
        assertThat(jdbc.queryForObject("SELECT unit_id FROM goods WHERE id=?",UUID.class,goods)).isNull();
        assertThat(jdbc.queryForObject("SELECT status FROM rd_tasks WHERE id=?",String.class,task)).isEqualTo("OPEN");
    }

    @Test void databaseRejectsPartialReceiptsAndMissingCasEvenWhenCalledDirectly() {
        UUID goods=bomOnlyGoods(),unit=unit(null),task=task(goods);
        org.assertj.core.api.Assertions.assertThatThrownBy(()->jdbc.update("""
                UPDATE rd_tasks SET initial_unit_id=?,initial_unit_actor_id=?,initial_unit_applied_at=now()
                WHERE id=?
                """,unit,actor,task)).isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
        org.assertj.core.api.Assertions.assertThatThrownBy(()->jdbc.queryForObject(
                "SELECT fn_reconcile_goods_initial_basic_unit(?,NULL,?,?,?)",Integer.class,task,unit,"原始资料核对",actor))
                .isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
        service.reconcileBasicUnit(task,new RdTaskContracts.InitialBasicUnitRequest(1L,unit,"原始资料核对"));
        org.assertj.core.api.Assertions.assertThatThrownBy(()->jdbc.update(
                "UPDATE rd_tasks SET initial_unit_evidence='改写依据' WHERE id=?",task))
                .isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
        jdbc.update("UPDATE units SET status='禁用' WHERE id=?",unit);
        // The committed receipt remains replayable after a later dictionary retirement.
        service.reconcileBasicUnit(task,new RdTaskContracts.InitialBasicUnitRequest(1L,unit,"原始资料核对"));
        assertThat(jdbc.queryForObject("SELECT row_version FROM rd_tasks WHERE id=?",Long.class,task)).isEqualTo(2L);
    }

    private UUID unit(Integer legacy) {
        UUID id=UUID.randomUUID();
        jdbc.update("INSERT INTO units(id,code,name,status,legacy_id) VALUES(?,?,?,'使用',?)",id,"UNIT-"+id,"个",legacy);
        return id;
    }

    private UUID warehouse() {
        UUID id=UUID.randomUUID();
        jdbc.update("INSERT INTO warehouses(id,code,name,status) VALUES(?,?,?,'使用')",id,"WH-"+id,"核对仓");
        return id;
    }

    private UUID goods() {
        UUID id=UUID.randomUUID();
        jdbc.update("INSERT INTO goods(id,code,name,code_sequence) VALUES(?,?,?,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))",id,"ISSUE-"+id,"问题组件");
        return id;
    }
}
