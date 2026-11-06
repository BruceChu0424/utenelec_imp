package com.uten.imp.features.finance.application;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccount;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import com.uten.imp.support.MigratedProjectionSchema;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.Supplier;

import static com.uten.imp.features.finance.application.FinanceApplicationContracts.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/**
 * Actual Roles/Journal transactions and V1077 over original V999_11
 * table/check/immutable definitions. Anonymous identity/parent projections use
 * the live migrated catalog; this is not full ERP or global audit-pipeline acceptance.
 */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class FinanceApplicationSettingsReceiptPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    private static final ObjectMapper JSON=new ObjectMapper().findAndRegisterModules();
    private static final UUID ACTOR_A=UUID.fromString("00000000-0000-0000-0000-000000000101");
    private static final UUID ACTOR_B=UUID.fromString("00000000-0000-0000-0000-000000000102");
    private static final UUID EMPLOYEE_A=UUID.fromString("00000000-0000-0000-0000-000000000201");
    private static final UUID EMPLOYEE_B=UUID.fromString("00000000-0000-0000-0000-000000000202");
    private static final UUID APPLICATION=UUID.fromString("00000000-0000-0000-0000-000000000301");
    private static final UUID LEGACY_REQUEST=UUID.fromString("00000000-0000-0000-0000-000000000401");
    private static final Assign LEGACY_ASSIGN=new Assign(LEGACY_REQUEST,7,List.of(EMPLOYEE_B),"匿名旧申请的原指派依据");
    private static JdbcTemplate db;
    private static TransactionTemplate transactions;
    private static String legacyBeforeMigration;
    private static String applicationBeforeMigration;
    private static int immutableTriggersBeforeMigration;
    private final SecurityContextCurrentUser current=new SecurityContextCurrentUser();
    private FinanceApplicationOperationJournal journal;
    private FinanceApplicationRoles roles;
    private FinanceApplicationService applications;
    private FinanceApplicationReadAccess reads;

    @BeforeAll static void start()throws Exception {
        PG.start();
        var source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        db=new JdbcTemplate(source);transactions=new TransactionTemplate(new DataSourceTransactionManager(source));
        // Only the original operation/settings definitions below are the migration subject.
        // Identity and parent-row projections use every column from the real current catalog.
        MigratedProjectionSchema.createCurrentTables(db,"employees","users","departments","finance_applications");
        MigratedProjectionSchema.createCurrentEmployeeIdentityReaders(db);
        db.update("INSERT INTO employees(id,full_name,status) VALUES(?,?,'active'),(?,?,'active')",EMPLOYEE_A,"匿名设置人员甲",EMPLOYEE_B,"匿名设置人员乙");
        db.update("INSERT INTO users(id,employee_id) VALUES(?,?),(?,?)",ACTOR_A,EMPLOYEE_A,ACTOR_B,EMPLOYEE_B);
        db.update("INSERT INTO finance_applications(id,remark) VALUES(?,?)",APPLICATION,"原申请身份和冻结内容保持不变");
        applicationBeforeMigration=db.queryForObject("SELECT to_jsonb(application)::text FROM finance_applications application WHERE id=?",String.class,APPLICATION);
        String original=resource("/db/migration/V999_11__financial_application_original_six_workflows.sql");
        for(String table:List.of("finance_application_settings","finance_application_enable_periods","finance_application_role_bindings","finance_application_operations"))
            MigratedProjectionSchema.createOriginalTables(db,"V999_11__financial_application_original_six_workflows.sql",table);
        db.execute(statement(original,"CREATE UNIQUE INDEX finance_application_one_enable_period"));
        db.execute(statement(original,"CREATE UNIQUE INDEX finance_application_role_person_unique"));
        int functionStart=original.indexOf("CREATE FUNCTION fn_finance_application_events_immutable()");
        int functionEnd=original.indexOf("$$;",functionStart);
        if(functionStart<0||functionEnd<0)throw new AssertionError("Original immutable function missing");
        db.execute(original.substring(functionStart,functionEnd+3));
        db.execute(statement(original,"CREATE TRIGGER finance_application_operations_immutable"));
        seedLegacy();
        legacyBeforeMigration=legacyRow();
        immutableTriggersBeforeMigration=immutableTriggerCount();
        assertThatThrownBy(()->db.update("INSERT INTO finance_application_operations(request_id,application_id,actor_id,operation,payload_hash,result) VALUES(?,NULL,?,'SETTINGS_SAVE',repeat('0',64),'{}')",UUID.randomUUID(),ACTOR_A))
                .isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class);
        db.execute(resource("/db/migration/V1077__finance_application_settings_operation_receipts.sql"));
        assertThat(legacyRow()).isEqualTo(legacyBeforeMigration);
    }
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void reset() {
        db.execute("TRUNCATE finance_application_operations,finance_application_settings,finance_application_enable_periods,finance_application_role_bindings");
        db.update("INSERT INTO finance_application_settings(id) VALUES(1)");seedLegacy();
        var users=mock(UserAccountRepository.class);var permissions=mock(PermissionResolver.class);
        for(UUID actor:List.of(ACTOR_A,ACTOR_B)) {
            var user=mock(UserAccount.class);when(user.getId()).thenReturn(actor);when(users.findById(actor)).thenReturn(Optional.of(user));
            when(permissions.grantedPermsOf(user)).thenReturn(Set.of(FinanceApplicationPermissions.VIEW,FinanceApplicationPermissions.REVIEW,"attachment:view","attachment:download"));
        }
        var tx=mock(TxSessionVars.class);
        doAnswer(call->{db.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,current.requireId().toString());return null;}).when(tx).bind();
        journal=new FinanceApplicationOperationJournal(db,JSON,current);
        roles=new FinanceApplicationRoles(db,users,permissions,current,tx,journal);
        reads=mock(FinanceApplicationReadAccess.class);
        applications=new FinanceApplicationService(db,JSON,roles,current,tx,null,null,null,null,null,null,null,reads,null,journal);
        login(ACTOR_A,true);
    }
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void actualMigrationPreservesOldReceiptsAndOnlyAdmitsTheThreeNullApplicationCommands() {
        assertThat(legacyRow()).isEqualTo(legacyBeforeMigration);
        assertThat(immutableTriggerCount()).isEqualTo(immutableTriggersBeforeMigration).isEqualTo(1);
        assertThat(db.queryForObject("SELECT remark FROM finance_applications WHERE id=?",String.class,APPLICATION)).isEqualTo("原申请身份和冻结内容保持不变");
        assertThat(db.queryForObject("SELECT to_jsonb(application)::text FROM finance_applications application WHERE id=?",String.class,APPLICATION)).isEqualTo(applicationBeforeMigration);
        for(String operation:List.of("SETTINGS_SAVE","ROLE_SAVE","ROLE_REMOVE"))
            inTransaction(()->journal.execute(null,UUID.randomUUID(),operation,Map.of("fixture",operation),ignored->{},()->Map.of("operation",operation)));
        assertThatThrownBy(()->db.update("INSERT INTO finance_application_operations(request_id,application_id,actor_id,operation,payload_hash,result) VALUES(?,NULL,?,'SUBMIT',repeat('0',64),'{}')",UUID.randomUUID(),ACTOR_A))
                .isInstanceOf(org.springframework.dao.DataIntegrityViolationException.class).hasMessageContaining("ck_finance_application_operation_scope");
        assertThatThrownBy(()->db.update("UPDATE finance_application_operations SET result='{}' WHERE request_id=?",LEGACY_REQUEST)).hasMessageContaining("immutable");
        assertThatThrownBy(()->db.update("DELETE FROM finance_application_operations WHERE request_id=?",LEGACY_REQUEST)).hasMessageContaining("immutable");
    }

    @Test void lostSettingsReplyReturnsTheOriginalReceiptAfterAnotherActorChangesTheSettingsWithoutRewritingThem() {
        UUID request=UUID.randomUUID();var command=new SettingsInput(0,false,"匿名第一份流程设置依据",request);
        var original=inTransaction(()->roles.saveSettings(command));
        login(ACTOR_B,true);
        inTransaction(()->roles.saveSettings(new SettingsInput(1,false,"匿名另一人员后续设置依据",UUID.randomUUID())));
        login(ACTOR_A,true);
        var replay=inTransaction(()->roles.saveSettings(command));
        assertSameJson(replay,original);
        assertThat(db.queryForObject("SELECT row_version FROM finance_application_settings WHERE id=1",Long.class)).isEqualTo(2);
        assertThat(db.queryForObject("SELECT source_reference FROM finance_application_settings WHERE id=1",String.class)).isEqualTo("匿名另一人员后续设置依据");
        assertThat(operationCount(request)).isEqualTo(1);
        var receipt=inTransaction(()->roles.settingsReceipt(request));
        assertThat(receipt).containsEntry("found",true).containsEntry("operation","SETTINGS_SAVE");
        assertSameJson(receipt.get("result"),original);
        login(ACTOR_B,true);assertThat(inTransaction(()->roles.settingsReceipt(request))).containsEntry("found",false);
    }

    @Test void reusingASettingsRequestWithAnotherBodyOrActorIsRejectedWithoutAnyAdditionalWrite() {
        UUID request=UUID.randomUUID();var command=new SettingsInput(0,false,"匿名原设置审批核对依据",request);
        inTransaction(()->roles.saveSettings(command));
        assertThatThrownBy(()->inTransaction(()->roles.saveSettings(new SettingsInput(0,false,"匿名不同设置审批依据",request))))
                .isInstanceOf(ApiException.class).hasMessageContaining("不同内容");
        login(ACTOR_B,true);
        assertThatThrownBy(()->inTransaction(()->roles.saveSettings(command))).isInstanceOf(ApiException.class).hasMessageContaining("不同内容");
        assertThat(operationCount(request)).isEqualTo(1);
        assertThat(db.queryForObject("SELECT row_version FROM finance_application_settings WHERE id=1",Long.class)).isEqualTo(1);
    }

    @Test void simultaneousRetriesExecuteTheActualSettingsWriteOnce()throws Exception {
        UUID request=UUID.randomUUID();var command=new SettingsInput(0,false,"匿名并发保存同一流程设置",request);
        ExecutorService threads=Executors.newFixedThreadPool(4);var start=new CountDownLatch(1);
        try {
            List<Future<Map<String,Object>>> results=new ArrayList<>();
            for(int i=0;i<4;i++)results.add(threads.submit(()->{login(ACTOR_A,true);try{start.await();return inTransaction(()->roles.saveSettings(command));}finally{SecurityContextHolder.clearContext();}}));
            start.countDown();Object first=results.getFirst().get(40,TimeUnit.SECONDS);
            for(var result:results)assertSameJson(result.get(40,TimeUnit.SECONDS),first);
        } finally {start.countDown();threads.shutdownNow();assertThat(threads.awaitTermination(5,TimeUnit.SECONDS)).isTrue();}
        assertThat(db.queryForObject("SELECT row_version FROM finance_application_settings WHERE id=1",Long.class)).isEqualTo(1);
        assertThat(operationCount(request)).isEqualTo(1);
    }

    @Test void failingToPersistTheReceiptRollsBackTheActualSettingsWriteAndLeavesNoFalseSuccess() {
        UUID request=UUID.randomUUID();
        db.execute("""
                CREATE FUNCTION fixture_reject_receipt() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN RAISE EXCEPTION 'anonymous injected receipt storage failure'; END; $$;
                CREATE TRIGGER fixture_reject_receipt BEFORE INSERT ON finance_application_operations FOR EACH ROW EXECUTE FUNCTION fixture_reject_receipt();
                """);
        try {
            assertThatThrownBy(()->inTransaction(()->roles.saveSettings(new SettingsInput(0,false,"匿名回执写入失败回滚依据",request))))
                    .hasMessageContaining("injected receipt storage failure");
            assertThat(db.queryForObject("SELECT row_version FROM finance_application_settings WHERE id=1",Long.class)).isZero();
            assertThat(db.queryForObject("SELECT source_reference FROM finance_application_settings WHERE id=1",String.class)).isEmpty();
            assertThat(operationCount(request)).isZero();
            assertThat(inTransaction(()->roles.settingsReceipt(request))).containsEntry("found",false);
            assertThat(legacyRow()).isEqualTo(legacyBeforeMigration);
        } finally {
            db.execute("DROP TRIGGER fixture_reject_receipt ON finance_application_operations");
            db.execute("DROP FUNCTION fixture_reject_receipt()");
        }
    }

    @Test void roleSaveAndRemovalReplayTheirOwnSnapshotsAfterInterveningChangesAndRemovalHashHasStableFieldOrder() {
        UUID role=UUID.randomUUID(),saveRequest=UUID.randomUUID(),removeRequest=UUID.randomUUID();
        var save=new RoleInput(role,-1,"TRAVEL_APPROVAL",null,EMPLOYEE_B,"匿名明确岗位指派依据",saveRequest);
        var saved=inTransaction(()->roles.saveRole(save));
        inTransaction(()->roles.saveRole(new RoleInput(role,0,"TRAVEL_APPROVAL",null,EMPLOYEE_A,"匿名后续岗位指派依据",UUID.randomUUID())));
        assertSameJson(inTransaction(()->roles.saveRole(save)),saved);
        assertThat(db.queryForObject("SELECT employee_id FROM finance_application_role_bindings WHERE id=?",UUID.class,role)).isEqualTo(EMPLOYEE_A);
        var removed=inTransaction(()->roles.removeRole(role,1,removeRequest));
        inTransaction(()->roles.saveRole(new RoleInput(role,-1,"TRAVEL_APPROVAL",null,EMPLOYEE_B,"匿名重新新增岗位依据",UUID.randomUUID())));
        assertSameJson(inTransaction(()->roles.removeRole(role,1,removeRequest)),removed);
        assertThat(db.queryForObject("SELECT employee_id FROM finance_application_role_bindings WHERE id=?",UUID.class,role)).isEqualTo(EMPLOYEE_B);
        String canonical="[\"ROLE_REMOVE\",null,{\"id\":\""+role+"\",\"expectedVersion\":1}]";
        assertThat(db.queryForObject("SELECT payload_hash FROM finance_application_operations WHERE request_id=?",String.class,removeRequest))
                .isEqualTo(ImmutableDocumentStore.digest(canonical.getBytes(StandardCharsets.UTF_8)));
        assertThat(operationCount(saveRequest)).isEqualTo(1);assertThat(operationCount(removeRequest)).isEqualTo(1);
    }

    @Test void settingsPermissionIsRequiredForNewCommandsAndForReplayingAnAlreadyStoredReceipt() {
        UUID request=UUID.randomUUID();var command=new SettingsInput(0,false,"匿名设置权限核对的原依据",request);
        inTransaction(()->roles.saveSettings(command));
        login(ACTOR_A,false);
        assertThatThrownBy(()->inTransaction(()->roles.saveSettings(command))).isInstanceOf(ApiException.class).hasMessageContaining(FinanceApplicationPermissions.SETTINGS);
        assertThatThrownBy(()->inTransaction(()->roles.saveSettings(new SettingsInput(1,false,"匿名无权限的新设置依据",UUID.randomUUID())))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->inTransaction(()->roles.settingsReceipt(request))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->inTransaction(()->roles.saveRole(new RoleInput(UUID.randomUUID(),-1,"TRAVEL_APPROVAL",null,EMPLOYEE_B,"匿名无权指派依据",UUID.randomUUID())))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->inTransaction(()->roles.removeRole(UUID.randomUUID(),0,UUID.randomUUID()))).isInstanceOf(ApiException.class);
        assertThat(operationCount(request)).isEqualTo(1);
        assertThat(db.queryForObject("SELECT row_version FROM finance_application_settings WHERE id=1",Long.class)).isEqualTo(1);
    }

    @Test void aMissingRequestIdentityNeverWritesSettingsOrRoleChanges() {
        assertThatThrownBy(()->inTransaction(()->roles.saveSettings(new SettingsInput(0,false,"匿名缺原请求编号设置依据",null)))).isInstanceOf(ApiException.class).hasMessageContaining("原请求编号");
        assertThatThrownBy(()->inTransaction(()->roles.saveRole(new RoleInput(UUID.randomUUID(),-1,"TRAVEL_APPROVAL",null,EMPLOYEE_B,"匿名缺原请求指派依据",null)))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->inTransaction(()->roles.removeRole(UUID.randomUUID(),0,null))).isInstanceOf(ApiException.class);
        assertThat(db.queryForObject("SELECT row_version FROM finance_application_settings WHERE id=1",Long.class)).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM finance_application_role_bindings",Integer.class)).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM finance_application_operations",Integer.class)).isEqualTo(1);
    }

    @Test void originalAssignmentFingerprintAndItsReplayAuthorizationRemainCompatible() {
        var replay=inTransaction(()->applications.assign(APPLICATION,LEGACY_ASSIGN));
        assertThat(replay).containsEntry("reassigned",true);
        verifyNoInteractions(reads);
        assertThat(legacyRow()).isEqualTo(legacyBeforeMigration);
        login(ACTOR_A,false);
        assertThatThrownBy(()->inTransaction(()->applications.assign(APPLICATION,LEGACY_ASSIGN))).isInstanceOf(ApiException.class).hasMessageContaining(FinanceApplicationPermissions.SETTINGS);
    }

    @Test void originalNonAssignmentReplayStillChecksCurrentApplicationReadAuthority() {
        UUID request=UUID.randomUUID();Map<String,Object> payload=new LinkedHashMap<>();payload.put("anonymous","old source");
        insertLegacy(request,"SAVE",payload,Map.of("id",APPLICATION.toString(),"saved",true));
        doThrow(new ApiException(com.uten.imp.common.web.ErrorCode.FORBIDDEN,"匿名当前申请读取权限已撤回")).when(reads).require(eq(APPLICATION),any(AuthUser.class));
        assertThatThrownBy(()->inTransaction(()->applications.operation(APPLICATION,request,"SAVE",payload,()->{throw new AssertionError("Replay must never rerun work");})))
                .isInstanceOf(ApiException.class).hasMessageContaining("读取权限已撤回");
        assertThat(operationCount(request)).isEqualTo(1);verify(reads).require(eq(APPLICATION),any(AuthUser.class));
    }

    @Test void anUnreadableOriginalReceiptRetainsThePriorConflictContractAndNeverRerunsTheApplication() {
        UUID request=UUID.randomUUID();var command=new Assign(request,7,List.of(EMPLOYEE_B),"匿名旧回执损坏核对依据");
        insertLegacy(request,"ASSIGN",command,List.of());
        assertThatThrownBy(()->inTransaction(()->applications.assign(APPLICATION,command)))
                .isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(com.uten.imp.common.web.ErrorCode.CONFLICT))
                .hasMessageContaining("无法完整读取");
        assertThat(operationCount(request)).isEqualTo(1);verifyNoInteractions(reads);
    }

    @Test void settingsRoleSaveAndRoleRemovalSealTheirOriginalHashesAndLateMutationsNeverExecute(){
        UUID settingsId=UUID.randomUUID(),roleId=UUID.randomUUID(),saveId=UUID.randomUUID(),removeId=UUID.randomUUID();
        var setting=new SettingsInput(0,false,"匿名尚未写入的流程设置依据",settingsId);
        var role=new RoleInput(roleId,-1,"TRAVEL_APPROVAL",null,EMPLOYEE_B,"匿名尚未写入的岗位依据",saveId);
        var removal=new FinanceApplicationOperationJournal.RoleRemovalCancellation(removeId,roleId,0);
        var stopped=inTransaction(()->roles.cancelSettings(settingsId,cancellation(settingsId,"SETTINGS_SAVE","POST","/finance/applications/settings",setting)));
        var stoppedRole=inTransaction(()->roles.cancelSettings(saveId,cancellation(saveId,"ROLE_SAVE","POST","/finance/applications/settings/roles",role)));
        var stoppedRemoval=inTransaction(()->roles.cancelSettings(removeId,cancellation(removeId,"ROLE_REMOVE","DELETE","/finance/applications/settings/roles/"+roleId,removal)));
        for(var result:List.of(stopped,stoppedRole,stoppedRemoval))assertThat(result).containsEntry("outcome","CANCELLED_UNWRITTEN");
        assertSameJson(inTransaction(()->roles.saveSettings(setting)),stopped);assertSameJson(inTransaction(()->roles.saveRole(role)),stoppedRole);
        assertSameJson(inTransaction(()->roles.removeRole(roleId,0,removeId)),stoppedRemoval);
        assertSameJson(inTransaction(()->roles.settingsReceipt(removeId)),stoppedRemoval);
        assertThat(db.queryForObject("SELECT row_version FROM finance_application_settings WHERE id=1",Long.class)).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM finance_application_role_bindings",Integer.class)).isZero();
        String old="[\"ROLE_REMOVE\",null,{\"id\":\""+roleId+"\",\"expectedVersion\":0}]";
        assertThat(db.queryForObject("SELECT payload_hash FROM finance_application_operations WHERE request_id=?",String.class,removeId))
                .isEqualTo(ImmutableDocumentStore.digest(old.getBytes(StandardCharsets.UTF_8)));
    }

    @Test void oldSuccessfulSettingsReceiptIsOnlyDecoratedByCancellationAndItsStoredBytesStayUnchanged(){
        UUID id=UUID.randomUUID();var command=new SettingsInput(0,false,"匿名成功后丢失回包的旧设置",id);
        var saved=inTransaction(()->roles.saveSettings(command));String bytes=storedOperation(id);
        login(ACTOR_B,true);inTransaction(()->roles.saveSettings(new SettingsInput(1,false,"匿名另一人员后续设置内容",UUID.randomUUID())));
        login(ACTOR_A,true);var verified=inTransaction(()->roles.cancelSettings(id,cancellation(id,"SETTINGS_SAVE","POST","/finance/applications/settings",command)));
        assertThat(verified).containsEntry("outcome","SUCCEEDED");assertSameJson(verified.get("requestBody"),command);assertSameJson(verified.get("result"),saved);
        assertThat(storedOperation(id)).isEqualTo(bytes);assertThat(db.queryForObject("SELECT row_version FROM finance_application_settings WHERE id=1",Long.class)).isEqualTo(2);
    }

    @Test void cancelledSettingsCannotBeReinterpretedByAnotherBodyActorOrLostSettingsAuthority(){
        UUID id=UUID.randomUUID();var command=new SettingsInput(0,false,"匿名本人原流程设置核对依据",id);
        var cancel=cancellation(id,"SETTINGS_SAVE","POST","/finance/applications/settings",command);
        inTransaction(()->roles.cancelSettings(id,cancel));
        assertThatThrownBy(()->inTransaction(()->roles.cancelSettings(id,cancellation(id,"SETTINGS_SAVE","POST",cancel.path(),new SettingsInput(0,true,"匿名不同的原请求正文依据",id)))))
                .isInstanceOf(ApiException.class).hasMessageContaining("不同内容");
        login(ACTOR_B,true);assertThatThrownBy(()->inTransaction(()->roles.cancelSettings(id,cancel))).isInstanceOf(ApiException.class).hasMessageContaining("本人原请求");
        login(ACTOR_A,false);assertThatThrownBy(()->inTransaction(()->roles.cancelSettings(id,cancel))).isInstanceOf(ApiException.class).hasMessageContaining(FinanceApplicationPermissions.SETTINGS);
        assertThatThrownBy(()->inTransaction(()->roles.settingsReceipt(id))).isInstanceOf(ApiException.class);
        assertThat(operationCount(id)).isEqualTo(1);
    }

    @Test void cancelledSettingsTransactionRollbackLeavesOriginalIdAvailableForTheOriginalWrite(){
        UUID id=UUID.randomUUID();var command=new SettingsInput(0,false,"匿名取消事务本身回滚的依据",id);
        transactions.executeWithoutResult(status->{roles.cancelSettings(id,cancellation(id,"SETTINGS_SAVE","POST","/finance/applications/settings",command));status.setRollbackOnly();});
        assertThat(operationCount(id)).isZero();inTransaction(()->roles.saveSettings(command));
        assertThat(db.queryForObject("SELECT row_version FROM finance_application_settings WHERE id=1",Long.class)).isEqualTo(1);
    }

    @Test void settingsCancellationAndOriginalCommitChooseOneOutcomeInBothLockOrders()throws Exception{
        for(boolean cancelFirst:List.of(true,false)){
            long version=db.queryForObject("SELECT row_version FROM finance_application_settings WHERE id=1",Long.class);
            UUID id=UUID.randomUUID();var command=new SettingsInput(version,false,"匿名两种提交顺序核对"+cancelFirst,id);
            var cancel=cancellation(id,"SETTINGS_SAVE","POST","/finance/applications/settings",command);
            var entered=new CountDownLatch(1);var release=new CountDownLatch(1);ExecutorService pool=Executors.newFixedThreadPool(2);
            try{
                var first=pool.submit(()->{login(ACTOR_A,true);try{return inTransaction(()->{var result=cancelFirst?roles.cancelSettings(id,cancel):roles.saveSettings(command);entered.countDown();await(release);return result;});}finally{SecurityContextHolder.clearContext();}});
                assertThat(entered.await(20,TimeUnit.SECONDS)).isTrue();
                var second=pool.submit(()->{login(ACTOR_A,true);try{return inTransaction(()->cancelFirst?roles.saveSettings(command):roles.cancelSettings(id,cancel));}finally{SecurityContextHolder.clearContext();}});
                org.awaitility.Awaitility.await().atMost(java.time.Duration.ofSeconds(10)).until(()->db.queryForObject("SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND NOT granted",Long.class)>0);
                release.countDown();var result=first.get(30,TimeUnit.SECONDS);var other=second.get(30,TimeUnit.SECONDS);
                if(cancelFirst)assertSameJson(result,other);else{assertThat(other).containsEntry("outcome","SUCCEEDED");assertSameJson(other.get("result"),result);}
            }finally{release.countDown();pool.shutdownNow();}
            login(ACTOR_A,true);assertThat(operationCount(id)).isEqualTo(1);
            assertThat(db.queryForObject("SELECT row_version FROM finance_application_settings WHERE id=1",Long.class)).isEqualTo(version+(cancelFirst?0:1));
        }
    }

    @Test void aNewSettingsOrRoleIdCannotUseOldCasJustBecauseCurrentValuesAlreadyMatch(){
        UUID id=UUID.randomUUID();inTransaction(()->roles.saveSettings(new SettingsInput(0,false,"匿名严格版本核对设置依据",id)));
        assertThatThrownBy(()->inTransaction(()->roles.saveSettings(new SettingsInput(0,false,"匿名严格版本核对设置依据",UUID.randomUUID())))).isInstanceOf(ApiException.class).hasMessageContaining("已变化");
        UUID role=UUID.randomUUID();inTransaction(()->roles.saveRole(new RoleInput(role,-1,"TRAVEL_APPROVAL",null,EMPLOYEE_B,"匿名严格版本岗位依据",UUID.randomUUID())));
        assertThatThrownBy(()->inTransaction(()->roles.saveRole(new RoleInput(role,-1,"TRAVEL_APPROVAL",null,EMPLOYEE_B,"匿名严格版本岗位依据",UUID.randomUUID())))).isInstanceOf(ApiException.class).hasMessageContaining("已变化");
    }

    private static com.uten.imp.features.finance.FinanceOperationJournal.Cancellation cancellation(UUID id,String operation,String method,String path,Object body){return new com.uten.imp.features.finance.FinanceOperationJournal.Cancellation(id,ACTOR_A,operation,method,path,JSON.valueToTree(body));}
    private static void await(CountDownLatch gate){try{if(!gate.await(20,TimeUnit.SECONDS))throw new AssertionError("commit gate timeout");}catch(InterruptedException error){Thread.currentThread().interrupt();throw new IllegalStateException(error);}}
    private static String storedOperation(UUID id){return db.queryForObject("SELECT to_jsonb(receipt)::text FROM finance_application_operations receipt WHERE request_id=?",String.class,id);}

    private static void seedLegacy(){insertLegacy(LEGACY_REQUEST,"ASSIGN",LEGACY_ASSIGN,Map.of("id",APPLICATION.toString(),"reassigned",true));}
    private static void insertLegacy(UUID request,String operation,Object payload,Object result) {
        // Exact pre-extraction List.of contract, not the new journal implementation.
        String oldHash=ImmutableDocumentStore.digest(encode(List.of(operation,APPLICATION,payload)).getBytes(StandardCharsets.UTF_8));
        db.update("INSERT INTO finance_application_operations(request_id,application_id,actor_id,operation,payload_hash,result,created_at) VALUES(?,?,?,?,?,?::jsonb,TIMESTAMPTZ '2026-01-01 00:00:00+00')",request,APPLICATION,ACTOR_A,operation,oldHash,encode(result));
    }
    private static int operationCount(UUID request){return db.queryForObject("SELECT count(*) FROM finance_application_operations WHERE request_id=?",Integer.class,request);}
    private static String legacyRow(){return db.queryForObject("SELECT to_jsonb(receipt)::text FROM finance_application_operations receipt WHERE request_id=?",String.class,LEGACY_REQUEST);}
    private static int immutableTriggerCount(){return db.queryForObject("SELECT count(*) FROM pg_trigger WHERE tgrelid='finance_application_operations'::regclass AND tgname='finance_application_operations_immutable' AND NOT tgisinternal",Integer.class);}
    private static void login(UUID actor,boolean settings) {
        var user=new AuthUser(actor,actor.equals(ACTOR_A)?EMPLOYEE_A:EMPLOYEE_B,"anonymous-operator",settings?Set.of(FinanceApplicationPermissions.VIEW,FinanceApplicationPermissions.SETTINGS):Set.of(FinanceApplicationPermissions.VIEW),false,true,false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,"",user.getAuthorities()));
    }
    private static <T>T inTransaction(Supplier<T> work){return transactions.execute(status->work.get());}
    private static void assertSameJson(Object actual,Object expected){try{assertThat(JSON.readTree(encode(actual))).isEqualTo(JSON.readTree(encode(expected)));}catch(java.io.IOException error){throw new AssertionError(error);}}
    private static String encode(Object value){try{return JSON.writeValueAsString(value);}catch(Exception error){throw new AssertionError(error);}}
    private static String resource(String name)throws Exception {try(var input=FinanceApplicationSettingsReceiptPostgresTest.class.getResourceAsStream(name)){return new String(Objects.requireNonNull(input,name).readAllBytes(),StandardCharsets.UTF_8);}}
    private static String statement(String sql,String prefix){int start=sql.indexOf(prefix);int end=sql.indexOf(';',start);if(start<0||end<0)throw new AssertionError("Original statement missing: "+prefix);return sql.substring(start,end+1);}
}
