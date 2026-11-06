package com.uten.imp.features.expenseclaim;

import com.uten.imp.testsupport.FixtureDatabaseProperties;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.expenseclaim.dto.*;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.math.BigDecimal;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Actual migrated storage, row locking, permission scope and staged transitions. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
    "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
    "uten.reporting.materialized-view-refresh.enabled=false",
    "uten.features.goods-owner-scope-enabled=false",
    "uten.jwt.secret=expense-workflow-test-jwt-key-0123456789-0123456789",
    "uten.crypto.pgp-master-key=expense-workflow-test-pgp-key-0123456789-0123456789",
    "uten.crypto.hmac-key=expense-workflow-test-hmac-key-0123456789",
    "uten.bootstrap.admin-login=expense-workflow-admin",
    "uten.bootstrap.admin-password=ExpenseWorkflowAdmin-1!"})
class ExpenseApprovalWorkflowPostgresTest {
    static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine")
        .withDatabaseName("expense_workflow").withUsername("fixture_admin").withPassword("uten");
    @DynamicPropertySource static void database(DynamicPropertyRegistry r) {
        PG.start();FixtureDatabaseProperties.bindSameRole(r,PG::getJdbcUrl,PG::getUsername,PG::getPassword);
    }
    @Autowired JdbcTemplate jdbc;
    @Autowired ExpenseClaimService claims;
    @Autowired com.uten.imp.common.readsnapshot.VersionedSummaryPages summaryPages;
    @Autowired com.uten.imp.features.notice.outbox.BusinessOutboxProcessor outbox;
    @Autowired com.uten.imp.features.approvalpolicy.DepartmentApprovalPolicyService approvalSettings;
    @Autowired org.springframework.transaction.PlatformTransactionManager transactions;
    @Autowired com.uten.imp.features.common.taskclaim.TaskClaimService leases;
    @BeforeEach void configureIndependentApprovalPool() {
        login(actor("configured-manager","DEPT_HR"),"expense:approve:department","attachment:view","attachment:download");
        login(actor("configured-initial","DEPT_FIN"),"expense:approve:finance_initial","attachment:view","attachment:download");
        login(actor("configured-review","DEPT_FIN"),"expense:approve:finance_review","attachment:view","attachment:download");
        login(actor("configured-executive","GM"),"expense:approve:executive","attachment:view","attachment:download");
        login(actor("configured-cashier","DEPT_FIN"),"expense:pay","attachment:view","attachment:download","attachment:upload");
    }
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void fourDifferentEmployeesMustApproveInOrderAndCountsFollowTheCurrentGate() {
        Actor owner=actor("owner","DEPT_HR"),manager=actor("manager","DEPT_HR"),initial=actor("initial","DEPT_FIN"),
                review=actor("review","DEPT_FIN"),executive=actor("executive","GM"),outsider=actor("outside","DEPT_FIN"),peer=actor("peer-reviewer","DEPT_HR");
        ExpenseClaimDto doc=draft(owner,"TRAVEL");login(owner,"expense:apply");doc=claims.submit(doc.id(),doc.version());
        UUID id=doc.id();long submitted=doc.version();
        assertThat(doc.expenseKind()).isEqualTo("TRAVEL");assertThat(doc.approvalRound()).isEqualTo(1);
        login(outsider,"expense:approve:department");
        assertThat(claims.counts().pendingApprovalCount()).isZero();
        assertThat(claims.listScoped("pending",null,null,null,null,1,50,null,null,null,"DEPARTMENT","DEPT_HR").getItems()).isEmpty();
        assertNativeListParity("pending",null,"DEPARTMENT","DEPT_HR",false);
        assertThatThrownBy(()->claims.approve(id,submitted)).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->leases.claim("EXPENSE_APPROVE",id.toString())).isInstanceOf(ApiException.class);
        login(initial,"expense:approve:finance_initial","attachment:view","attachment:download");
        long initialBaseline=claims.counts().financeInitialPendingApprovalCount();
        assertThat(claims.listScoped("pending",null,null,null,null,1,50,null,null,doc.claimNo(),null,null).getItems()).isEmpty();
        assertNativeListParity("pending",null,null,null,false);
        assertThatThrownBy(()->claims.approve(id,submitted)).isInstanceOf(ApiException.class);
        login(peer,"expense:approve:department","attachment:view","attachment:download");
        assertThat(claims.detail(id).canApprove()).isTrue();
        long phaseScopeGeneration=jdbc.queryForObject("SELECT generation FROM read_scope_generations WHERE domain='expense'",Long.class);
        login(manager,"expense:approve:department","expense:approve:finance_initial","attachment:view","attachment:download");
        assertThat(claims.counts().departmentPendingByCode()).containsEntry("DEPT_HR",1L);
        leases.claim("EXPENSE_APPROVE",id.toString());doc=claims.approve(id,submitted);
        assertThat(doc.status()).isEqualTo("REVIEWING");assertThat(doc.approvalStage()).isEqualTo("FINANCE_INITIAL");
        assertThat(jdbc.queryForObject("SELECT generation FROM read_scope_generations WHERE domain='expense'",Long.class)).isGreaterThan(phaseScopeGeneration);
        login(peer,"expense:approve:department","attachment:view","attachment:download");assertThatThrownBy(()->claims.detail(id)).isInstanceOf(ApiException.class);
        login(manager,"expense:approve:department","expense:approve:finance_initial","attachment:view","attachment:download");
        assertThat(claims.listScoped("pending",null,null,null,null,1,50,null,null,doc.claimNo(),null,null).getItems()).isEmpty();
        assertNativeListParity("pending",null,null,null,false);
        assertThat(claims.listHistory(null,null,null,null,1,50).getItems()).extracting(ExpenseClaimDto::id).contains(id);
        long firstVersion=doc.version();
        assertThatThrownBy(()->claims.approve(id,firstVersion)).isInstanceOf(ApiException.class);
        login(initial,"expense:approve:finance_initial","attachment:view","attachment:download");
        assertThat(claims.counts().financeInitialPendingApprovalCount()).isEqualTo(initialBaseline+1);
        doc=claims.approve(id,firstVersion);assertThat(doc.approvalStage()).isEqualTo("FINANCE_REVIEW");
        login(review,"expense:approve:finance_review","attachment:view","attachment:download");
        doc=claims.approve(id,doc.version());assertThat(doc.approvalStage()).isEqualTo("EXECUTIVE");
        login(executive,"expense:approve:executive","attachment:view","attachment:download");
        doc=claims.approve(id,doc.version());assertThat(doc.status()).isEqualTo("APPROVED");assertThat(doc.approvalStage()).isNull();
        assertThat(jdbc.queryForList("SELECT approval_stage FROM expense_claim_events WHERE claim_id=? AND event_type IN('STAGE_APPROVED','APPROVED') ORDER BY created_at,id",String.class,id))
                .containsExactly("DEPARTMENT","FINANCE_INITIAL","FINANCE_REVIEW","EXECUTIVE");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM finance_expenses WHERE remark=?",Long.class,"员工报销 "+id)).isZero();
        login(owner,"expense:apply");assertThat(claims.detail(id).events()).filteredOn(e->e.approvalRound()!=null).hasSize(4);
    }

    @Test void rejectionResubmissionWithdrawalAndRapidDuplicateDecisionsPreserveRounds() throws Exception {
        Actor owner=actor("revision-owner","DEPT_HR"),manager=actor("revision-manager","DEPT_HR"),other=actor("revision-other","DEPT_HR"),
                finance=actor("revision-finance","DEPT_FIN");
        var doc=draft(owner,"GENERAL");login(owner,"expense:apply");doc=claims.submit(doc.id(),doc.version());UUID id=doc.id();
        login(manager,"expense:approve:department","attachment:view","attachment:download");doc=claims.approve(id,doc.version());
        login(finance,"expense:approve:finance_initial");doc=claims.reject(id,"补齐出差依据",doc.version());
        login(owner,"expense:apply");doc=claims.editVersioned(id,request("补齐后的报销",doc.version(),"GENERAL"));doc=claims.submit(id,doc.version());
        assertThat(doc.approvalRound()).isEqualTo(2);assertThat(doc.approvalStage()).isEqualTo("DEPARTMENT");
        long version=doc.version();
        try(var pool=java.util.concurrent.Executors.newFixedThreadPool(2)) {
            var futures=List.of(pool.submit(()->decide(manager,id,version)),pool.submit(()->decide(other,id,version)));
            int successes=0;for(var future:futures)if(future.get(30,java.util.concurrent.TimeUnit.SECONDS))successes++;
            assertThat(successes).isEqualTo(1);
        }
        login(owner,"expense:apply");doc=claims.detail(id);doc=claims.withdraw(id,doc.version());
        assertThat(doc.status()).isEqualTo("DRAFT");assertThat(doc.approvalStage()).isEqualTo("DEPARTMENT");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM expense_claim_events WHERE claim_id=? AND approval_round=1 AND event_type='STAGE_APPROVED'",Long.class,id)).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT count(*) FROM expense_claim_events WHERE claim_id=? AND approval_round=2 AND event_type='STAGE_APPROVED'",Long.class,id)).isEqualTo(1);
        login(finance,"expense:approve:finance_initial");assertThat(claims.counts().pendingApprovalCount()).isZero();
        assertThatThrownBy(()->claims.approve(id,version)).isInstanceOf(ApiException.class);
    }

    @Test void notificationSqlAndLegacyPermissionCannotWidenTheCurrentNode() {
        Actor owner=actor("notice-owner","DEPT_HR"),manager=actor("notice-manager","DEPT_HR"),foreign=actor("notice-foreign","DEPT_FIN");
        var doc=draft(owner,"GENERAL");login(owner,"expense:apply");doc=claims.submit(doc.id(),doc.version());UUID id=doc.id();long version=doc.version();
        assertThat(sqlEligible(manager,"expense:approve:department",id)).isTrue();
        assertThat(sqlEligible(foreign,"expense:approve:department",id)).isFalse();
        assertThat(sqlEligible(owner,"expense:approve:department",id)).isFalse();
        assertThat(sqlEligible(manager,"expense:approve:executive",id)).isFalse();
        login(manager,"expense:approve");assertThatThrownBy(()->claims.approve(id,version)).isInstanceOf(ApiException.class);
        login(manager,"expense:approve:department","attachment:view","attachment:download");claims.approve(id,version);
        assertThat(sqlEligible(manager,"expense:approve:finance_initial",id)).isFalse();
        assertThat(sqlEligible(foreign,"expense:approve:finance_initial",id)).isTrue();
        login(owner,"expense:apply");var current=claims.detail(id);claims.withdraw(id,current.version());
    }

    @Test void missingCurrentOperatorOrOnlyTheCurrentParticipantRollsBackWithoutPublishingATask() {
        String departmentCode="UNASSIGNED-"+UUID.randomUUID();
        jdbc.update("INSERT INTO departments(id,code,name,level) VALUES(?,?,'审批配置测试部门','一级部门')",UUID.randomUUID(),departmentCode);
        Actor owner=actor("unassigned-owner",departmentCode);var draft=draft(owner,"GENERAL");
        login(owner,"expense:apply");
        assertThatThrownBy(()->claims.submit(draft.id(),draft.version())).isInstanceOf(ApiException.class).hasMessageContaining("配置对应岗位审批权限");
        assertThat(claims.detail(draft.id()).status()).isEqualTo("DRAFT");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM expense_claim_events WHERE claim_id=? AND event_type='SUBMITTED'",Long.class,draft.id())).isZero();
        Actor manager=actor("only-initial-participant",departmentCode);login(manager,"expense:approve:department","expense:approve:finance_initial","attachment:view","attachment:download");
        new org.springframework.transaction.support.TransactionTemplate(transactions).executeWithoutResult(status->{
            jdbc.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,manager.user().toString());
            jdbc.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect) SELECT ?,id,'revoke' FROM permissions WHERE code='notice:read' ON CONFLICT(user_id,permission_id) DO UPDATE SET effect='revoke',active=true",manager.user());
        });
        login(owner,"expense:apply");var submitted=claims.submit(draft.id(),draft.version());
        var changed=jdbc.queryForList("SELECT user_id FROM user_permission_overrides o JOIN permissions p ON p.id=o.permission_id WHERE p.code='expense:approve:finance_initial' AND o.active AND o.user_id<>?",UUID.class,manager.user());
        try {
            new org.springframework.transaction.support.TransactionTemplate(transactions).executeWithoutResult(status->{
                jdbc.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,manager.user().toString());
                jdbc.update("UPDATE user_permission_overrides o SET active=false FROM permissions p WHERE p.id=o.permission_id AND p.code='expense:approve:finance_initial' AND o.user_id<>?",manager.user());
            });
            login(manager,"expense:approve:department","expense:approve:finance_initial","attachment:view","attachment:download");
            assertThatThrownBy(()->claims.approve(draft.id(),submitted.version())).isInstanceOf(ApiException.class).hasMessageContaining("财务初核");
            login(owner,"expense:apply");assertThat(claims.detail(draft.id()).approvalStage()).isEqualTo("DEPARTMENT");
            assertThat(jdbc.queryForObject("SELECT count(*) FROM expense_claim_events WHERE claim_id=? AND event_type='STAGE_APPROVED'",Long.class,draft.id())).isZero();
        } finally {
            new org.springframework.transaction.support.TransactionTemplate(transactions).executeWithoutResult(status->{
                jdbc.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,manager.user().toString());
                for(UUID user:changed)jdbc.update("UPDATE user_permission_overrides o SET active=true FROM permissions p WHERE p.id=o.permission_id AND p.code='expense:approve:finance_initial' AND o.user_id=?",user);
            });
        }
    }

    @Test void managerOwnRecusalIsConfiguredFrozenAndNeverWidensOrdinaryDepartmentAccess() throws Exception {
        String code="RECUSE-"+UUID.randomUUID();UUID department=UUID.randomUUID();
        jdbc.update("INSERT INTO departments(id,code,name,level) VALUES(?,?,'负责人回避测试部门','一级部门')",department,code);
        Actor manager=actor("recusing-manager",code),employee=actor("ordinary-colleague",code),substitute=actor("cross-department-substitute","DEPT_FIN"),administrator=actor("routing-administrator","GM");
        jdbc.update("UPDATE departments SET manager_id=? WHERE id=?",manager.employee(),department);
        var own=draft(manager,"GENERAL");login(manager,"expense:apply","expense:approve:department","attachment:view","attachment:download");
        assertThatThrownBy(()->claims.submit(own.id(),own.version())).isInstanceOf(ApiException.class).hasMessageContaining("回避审批人");
        login(substitute,"expense:approve:department","attachment:view","attachment:download");
        login(manager,"approval_policy:manage");
        assertThatThrownBy(()->approvalSettings.update(department,new com.uten.imp.features.approvalpolicy.DepartmentApprovalPolicyService.Update(substitute.employee(),0L)))
                .isInstanceOf(ApiException.class).hasMessageContaining("不能为本人申请选择");
        login(administrator,"approval_policy:manage");
        assertThat(approvalSettings.candidates(department,null)).extracting(row->row.id()).contains(substitute.employee()).doesNotContain(manager.employee());
        var configured=approvalSettings.update(department,new com.uten.imp.features.approvalpolicy.DepartmentApprovalPolicyService.Update(substitute.employee(),0L));
        login(substitute,"expense:approve:department","attachment:view","attachment:download");
        assertThat(claims.counts().departmentApprovalScopeByCode()).containsEntry(code,1L);
        assertThat(claims.counts().departmentPendingByCode()).containsEntry(code,0L);
        login(manager,"expense:apply","expense:approve:department","attachment:view","attachment:download");var submitted=claims.submit(own.id(),own.version());
        assertThatThrownBy(()->claims.approve(own.id(),submitted.version())).isInstanceOf(ApiException.class).hasMessageContaining("不能审批自己");
        var colleague=draft(employee,"GENERAL");login(employee,"expense:apply");colleague=claims.submit(colleague.id(),colleague.version());
        login(substitute,"expense:approve:department","attachment:view","attachment:download");
        assertThat(claims.listScoped("pending",null,null,null,null,1,50,null,null,null,"DEPARTMENT",code).getItems()).extracting(ExpenseClaimDto::id).containsExactly(submitted.id());
        assertNativeListParity("pending",null,"DEPARTMENT",code,false);
        assertThat(claims.counts().departmentPendingByCode()).containsEntry(code,1L);
        UUID colleagueId=colleague.id();assertThatThrownBy(()->claims.detail(colleagueId)).isInstanceOf(ApiException.class);
        assertThat(sqlEligible(substitute,"expense:approve:department",own.id())).isTrue();
        long scopeGeneration=jdbc.queryForObject("SELECT generation FROM read_scope_generations WHERE domain='expense'",Long.class);
        login(administrator,"approval_policy:manage");var cleared=approvalSettings.update(department,new com.uten.imp.features.approvalpolicy.DepartmentApprovalPolicyService.Update(null,configured.version()));
        approvalSettings.update(department,new com.uten.imp.features.approvalpolicy.DepartmentApprovalPolicyService.Update(substitute.employee(),cleared.version()));
        assertThat(jdbc.queryForObject("SELECT generation FROM read_scope_generations WHERE domain='expense'",Long.class)).isGreaterThan(scopeGeneration);
        login(manager,"expense:apply");assertThat(claims.detail(own.id()).approvalRoutingStale()).isTrue();
        assertThat(claims.counts().mineRoutingStaleCount()).isEqualTo(1);
        assertThat(claims.listMine("ACTION_REQUIRED",null,null,null,null,1,50).getItems()).extracting(ExpenseClaimDto::id).contains(own.id());
        assertNativeListParity("mineActive",null,null,null,true);
        assertThat(claims.listMine("SUBMITTED,REVIEWING,APPROVED",null,null,null,null,1,50).getItems()).extracting(ExpenseClaimDto::id).doesNotContain(own.id());
        assertNativeListParity("mineActive","SUBMITTED,REVIEWING,APPROVED",null,null,false);
        for(int retry=0;retry<100;retry++) {
            if(jdbc.queryForObject("SELECT count(*) FROM notices WHERE audience_user_id=? AND action_route=? AND title='审批安排已变化，请撤回重提'",Long.class,manager.user(),"/expense/"+own.id())>0)break;
            outbox.processNext();Thread.sleep(100);
        }
        assertThat(jdbc.queryForObject("SELECT count(*) FROM notices WHERE audience_user_id=? AND action_route=? AND title='审批安排已变化，请撤回重提'",Long.class,manager.user(),"/expense/"+own.id())).isEqualTo(1);
        login(substitute,"expense:approve:department","attachment:view","attachment:download");
        assertThat(sqlEligible(substitute,"expense:approve:department",own.id())).isFalse();
        assertThatThrownBy(()->claims.detail(own.id())).isInstanceOf(ApiException.class);
        login(manager,"expense:apply");var withdrawn=claims.withdraw(own.id(),submitted.version());var resubmitted=claims.submit(own.id(),withdrawn.version());
        login(substitute,"expense:approve:department","attachment:view","attachment:download");
        assertThat(claims.approve(own.id(),resubmitted.version()).approvalStage()).isEqualTo("FINANCE_INITIAL");
    }

    private boolean decide(Actor actor,UUID id,long version) {login(actor,"expense:approve:department","attachment:view","attachment:download");try{claims.approve(id,version);return true;}catch(ApiException conflict){return false;}finally{logout();}}
    private boolean sqlEligible(Actor actor,String permission,UUID id){return Boolean.TRUE.equals(jdbc.queryForObject("SELECT fn_expense_approval_eligible(?,ARRAY[?]::text[],?)",Boolean.class,actor.employee(),permission,id));}
    private ExpenseClaimDto draft(Actor owner,String kind){login(owner,"expense:apply");var doc=claims.create(request("公司业务报销",null,kind));UUID attachment=UUID.randomUUID();jdbc.update("""
        INSERT INTO attachments(id,owner_type,owner_id,storage_key,original_name,content_type,size_bytes,sha256,storage_provider,lifecycle_state,scan_engine,scanned_at,promoted_at)
        VALUES(?,'EXPENSE_CLAIM',?,?,'原始凭证.pdf','application/pdf',100,?,'local','CLEAN','fixture',now(),now())
        """,attachment,doc.id(),attachment+".pdf","a".repeat(64));return doc;}
    private ExpenseClaimCreateRequest request(String title,Long version,String kind){return new ExpenseClaimCreateRequest(title,"原始费用凭证和业务依据见附件",List.of(new ExpenseClaimItemInput("TRAVEL",new BigDecimal("100.00"),BusinessTime.today(),"客户拜访交通费用")),version,kind);}
    private Actor actor(String name,String code){UUID employee=UUID.randomUUID(),user=UUID.randomUUID();UUID department=jdbc.queryForObject("SELECT id FROM departments WHERE code=?",UUID.class,code);String login="expense-workflow-"+user;
        jdbc.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',?,DATE '2026-01-01','active','regular')",employee,"E-"+employee,name+"-"+employee.toString().substring(0,8),department);
        jdbc.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,is_super_admin,status) VALUES(?,?,?,'test-not-used',false,false,'active')",user,employee,login);return new Actor(user,employee,login);}
    private void login(Actor actor,String... permissions){
        new org.springframework.transaction.support.TransactionTemplate(transactions).executeWithoutResult(status->{
            UUID administrator=jdbc.queryForObject("SELECT id FROM users WHERE login_account='expense-workflow-admin'",UUID.class);
            jdbc.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,administrator.toString());
            for(String permission:permissions)jdbc.update("""
                INSERT INTO user_permission_overrides(user_id,permission_id,effect,authority_source,source_actor_user_id)
                SELECT ?,id,'grant','SUPER_ADMIN_CONFIRMED',? FROM permissions WHERE code=?
                ON CONFLICT(user_id,permission_id) DO UPDATE SET effect='grant',authority_source='SUPER_ADMIN_CONFIRMED',source_actor_user_id=excluded.source_actor_user_id,active=true
                """,actor.user(),administrator,permission);
        });
        var user=new AuthUser(actor.user(),actor.employee(),actor.login(),Set.of(permissions),false,true,false);SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,"",user.getAuthorities()));
    }
    private record Actor(UUID user,UUID employee,String login){}

    /** Both reads execute the original shared Specification; fixtures above exercise live approval, self-recusal and stale routing. */
    private void assertNativeListParity(String queue,String status,String stage,String departmentCode,boolean actionRequired) {
        var expected="mineActive".equals(queue)
                ?claims.listMine(actionRequired?"ACTION_REQUIRED":status,null,null,null,null,1,100).getItems()
                :claims.listScoped(queue,null,null,null,null,1,100,null,null,null,stage,departmentCode).getItems();
        Map<String,Object> query=new LinkedHashMap<>();query.put("queue",queue);query.put("status",status);query.put("stage",stage);query.put("departmentCode",departmentCode);query.put("actionRequired",actionRequired);
        List<String> actual=new ArrayList<>();String revision=null;boolean hasMore;
        for(int page=1;;page++) {
            try(var scope=com.uten.imp.common.web.NativeFacetCandidates.open("claimNo","",page,100)) {
                var request=new com.uten.imp.common.readsnapshot.VersionedSummaryPages.Request("native-facet-expense-claim-no","expense",query,"all",page,100,100,revision);
                var snapshot=summaryPages.read(request,()->{},()->claims.nativeClaimNoFacets(queue,status,null,null,null,null,false,false,stage,departmentCode,actionRequired,false));
                scope.snapshot(snapshot.readScopeVersion(),snapshot.readSnapshotRevision(),snapshot.readDataVersion());
                var result=scope.result(snapshot.value(),snapshot.readScopeVersion());
                if(revision==null)revision=result.readSnapshotRevision();else assertThat(result.readSnapshotRevision()).isEqualTo(revision);
                result.items().forEach(row->{assertThat(row.get("count")).isEqualTo(1L);actual.add(row.get("value").toString());});hasMore=result.hasMore();
            }
            if(!hasMore)break;
        }
        assertThat(actual).containsExactlyInAnyOrderElementsOf(expected.stream().map(ExpenseClaimDto::claimNo).toList());
        assertThat(com.uten.imp.common.web.NativeFacetCandidates.active()).isFalse();
    }
}
