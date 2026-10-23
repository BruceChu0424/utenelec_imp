package com.uten.imp.features.warehouse.materialbin;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.*;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseDtos.*;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.support.MigratedProjectionSchema;
import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.springframework.transaction.PlatformTransactionManager;

import java.util.*;
import java.util.function.Supplier;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Exercises real PostgreSQL scope resolution and receipt replay; no business state/version is replayed. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class WorkshopMaterialReplayScopePostgresTest {
    record Replay(String name,Supplier<?> call,Object expected) {}

    @Test void allExistingObjectCommandsRecheckCurrentWorkshopBeforeReturningTheirStoredReceipt() throws Exception {
        try(var database=MigratedSchemaBaseline.openDatabase("wm_replay_object_scope");var connection=database.openConnection()) {
            connection.setAutoCommit(false);
            try(var statement=connection.createStatement()) {
                statement.execute("CREATE SCHEMA wm_replay_oracle");
                statement.execute("SET LOCAL search_path=wm_replay_oracle,public");
            }
            MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(connection,"departments","employees",
                    "employee_secondary_departments","workshop_machines","workshop_machine_containers",
                    "production_execution_segments","workshop_material_periods","workshop_material_counts","workshop_material_commands");
            var db=new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection,true));
            UUID root=UUID.randomUUID(),a=UUID.randomUUID(),b=UUID.randomUUID(),employee=UUID.randomUUID();
            UUID machine=UUID.randomUUID(),otherMachine=UUID.randomUUID(),container=UUID.randomUUID();
            UUID segment=UUID.randomUUID(),period=UUID.randomUUID(),count=UUID.randomUUID(),actor=UUID.randomUUID();
            db.update("INSERT INTO departments(id,code,name,parent_id,is_deleted) VALUES(:id,'DEPT_PROD','生产部',NULL,FALSE)",Map.of("id",root));
            db.update("INSERT INTO departments(id,code,name,parent_id,is_deleted) VALUES(:a,'WS-A','A车间',:root,FALSE),(:b,'WS-B','B车间',:root,FALSE)",Map.of("a",a,"b",b,"root",root));
            db.update("INSERT INTO employees(id,department_id,status,is_deleted) VALUES(:id,:a,'active',FALSE)",Map.of("id",employee,"a",a));
            db.update("INSERT INTO workshop_machines(id,workshop_department_id,row_version,is_deleted) VALUES(:id,:a,91,TRUE),(:other,:b,81,FALSE)",Map.of("id",machine,"a",a,"other",otherMachine,"b",b));
            db.update("INSERT INTO workshop_machine_containers(id,machine_id,row_version,is_deleted) VALUES(:id,:machine,78,TRUE)",Map.of("id",container,"machine",machine));
            db.update("INSERT INTO production_execution_segments(id,workshop_department_id,lock_version,status,is_deleted) VALUES(:id,:a,101,'COMPLETED',TRUE)",Map.of("id",segment,"a",a));
            db.update("INSERT INTO workshop_material_periods(id,workshop_department_id,row_version,status) VALUES(:id,:a,123,'CLOSED')",Map.of("id",period,"a",a));
            db.update("INSERT INTO workshop_material_counts(id,period_id,row_version,status) VALUES(:id,:period,321,'SUPERSEDED')",Map.of("id",count,"period",period));
            var current=mock(SecurityContextCurrentUser.class);
            when(current.get()).thenReturn(Optional.of(new AuthUser(actor,employee,"operator",Set.of(),false,false,false)));
            when(current.requireId()).thenReturn(actor);
            var scope=new WorkshopMaterialScope(db,current);
            var json=new ObjectMapper().findAndRegisterModules();
            var ledger=new WorkshopMaterialCommandLedger(db,json,current);
            var machines=new WorkshopMachineService(db,ledger,scope,current);
            var choice=new WorkshopMaterialChoiceAdapter(db,null,ledger,scope,current);
            var counts=new WorkshopMaterialCountService(db,null,null,ledger,scope,null,null,null,current);
            var periods=new WorkshopMaterialPeriodService(db,null,ledger,scope,null,null,current,null);
            var close=new WorkshopMaterialCloseService(db,mock(PlatformTransactionManager.class),null,null,null,ledger,scope,null,current,null,json);
            var settings=new WorkshopMaterialSettingsService(db,null,ledger,scope,null,null,null,current);
            List<Replay> cases=new ArrayList<>();
            var machineRequest=new MachineBatchUpdate(List.of(new MachineEdit(machine,0L,"A",null,null,null,null,null)),"replay-machine");
            cases.add(seed(ledger,json,"MACHINE_BATCH_UPDATE",machineRequest.idempotencyKey(),machineRequest,MachineList.class,()->machines.updateBatch(machineRequest)));
            var containerRequest=new ContainerBatchUpdate(List.of(new ContainerEdit(container,machine,0L,"桶",java.math.BigDecimal.ONE,null,null)),"replay-container");
            cases.add(seed(ledger,json,"CONTAINER_BATCH_UPDATE",containerRequest.idempotencyKey(),containerRequest,MachineList.class,()->machines.updateContainers(containerRequest)));
            var materialRequest=new MaterialChangeRequest(0L,null,UUID.randomUUID(),null,null,null,"换料","replay-material");
            cases.add(seed(ledger,json,"MATERIAL_CHANGE",materialRequest.idempotencyKey(),List.of(segment,materialRequest),SegmentMaterials.class,()->choice.changeMaterial(segment,materialRequest)));
            var zeroRequest=new ZeroRestRequest("replay-zero-rest");
            cases.add(seed(ledger,json,"COUNT_ZERO_REST",zeroRequest.idempotencyKey(),List.of(count,zeroRequest),ZeroRestResult.class,()->counts.zeroRest(count,zeroRequest)));
            var submitRequest=new VersionRequest(0L,"replay-count-submit");
            cases.add(seed(ledger,json,"COUNT_SUBMIT",submitRequest.idempotencyKey(),List.of(count,submitRequest),PeriodView.class,()->counts.submit(count,submitRequest)));
            var correctRequest=new CorrectCountRequest(0L,"更正测试","replay-correct");
            cases.add(seed(ledger,json,"COUNT_CORRECT",correctRequest.idempotencyKey(),List.of(period,correctRequest),CountDetail.class,()->counts.correct(period,correctRequest)));
            var startRequest=new StartCountRequest(0L,null,"replay-start");
            cases.add(seed(ledger,json,"COUNT_START",startRequest.idempotencyKey(),List.of(period,startRequest),StartCountResult.class,()->periods.startCount(period,startRequest)));
            var withdrawRequest=new VersionRequest(0L,"replay-withdraw");
            cases.add(seed(ledger,json,"COUNT_WITHDRAW",withdrawRequest.idempotencyKey(),List.of(period,withdrawRequest),PeriodView.class,()->periods.withdrawCount(period,withdrawRequest)));
            var retryRequest=new RetryRequest("replay-retry-close");
            cases.add(seed(ledger,json,"CLOSE_RETRY",retryRequest.idempotencyKey(),List.of(period,retryRequest.idempotencyKey()),CloseStatusView.class,()->close.retry(period,retryRequest)));
            var reopenRequest=new ReopenRequest(0L,"撤销测试","replay-reopen");
            cases.add(seed(ledger,json,"CLOSE_REOPEN",reopenRequest.idempotencyKey(),List.of(period,reopenRequest),CloseStatusView.class,()->close.reopen(period,reopenRequest)));
            var enableRequest=new BatchEnableRequest(List.of(new BinItem(a,"NOT_OPEN",0L)),null,false,false,null,List.of(),"replay-enable");
            cases.add(seed(ledger,json,"BIN_BATCH_ENABLE",enableRequest.idempotencyKey(),enableRequest,BatchResult.class,()->settings.batchEnable(enableRequest)));
            var disableRequest=new BatchDisableRequest(List.of(new BinItem(a,"OPEN",0L)),"replay-disable");
            cases.add(seed(ledger,json,"BIN_BATCH_DISABLE",disableRequest.idempotencyKey(),disableRequest,BatchResult.class,()->settings.batchDisable(disableRequest)));
            assertThat(cases).hasSize(12);
            assertThat(scope.restrictedWorkshops()).contains(Set.of(a));
            // Completed, superseded, soft-deleted, and newer-version facts do not invalidate an authorized replay.
            for(Replay replay:cases) assertThat(replay.call().get()).as(replay.name()).isEqualTo(replay.expected());
            Long receipts=db.queryForObject("SELECT count(*) FROM workshop_material_commands",Map.of(),Long.class);
            db.update("UPDATE employees SET department_id=:b WHERE id=:id",Map.of("b",b,"id",employee));
            assertThat(scope.restrictedWorkshops()).contains(Set.of(b));
            for(Replay replay:cases) assertThatThrownBy(()->replay.call().get()).as(replay.name())
                    .isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.FORBIDDEN));
            assertThat(db.queryForObject("SELECT count(*) FROM workshop_material_commands",Map.of(),Long.class)).isEqualTo(receipts);
            assertThat(db.queryForObject("SELECT row_version FROM workshop_material_periods WHERE id=:id",Map.of("id",period),Long.class)).isEqualTo(123);
            db.update("UPDATE employees SET department_id=:a WHERE id=:id",Map.of("a",a,"id",employee));
            for(Replay replay:cases) assertThat(replay.call().get()).as(replay.name()).isEqualTo(replay.expected());
            // The existing container's actual machine is authoritative, even if the request still names A's machine.
            db.update("UPDATE workshop_machine_containers SET machine_id=:other WHERE id=:id",Map.of("other",otherMachine,"id",container));
            assertThatThrownBy(()->machines.updateContainers(containerRequest)).isInstanceOfSatisfying(ApiException.class,
                    error->assertThat(error.getCode()).isEqualTo(ErrorCode.FORBIDDEN));
            connection.rollback();
        }
    }

    private static <T> Replay seed(WorkshopMaterialCommandLedger ledger,ObjectMapper json,String kind,String key,
                                    Object payload,Class<T> resultType,Supplier<T> call) throws Exception {
        T result=json.readValue("{}",resultType);
        ledger.execute(kind,key,payload,resultType,()->new WorkshopMaterialCommandLedger.Outcome<>(null,result));
        return new Replay(kind,call,result);
    }
}
