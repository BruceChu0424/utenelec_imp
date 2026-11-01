package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.report.NativeTaskReadScopeInterceptor;
import com.uten.imp.common.report.ReportReadScopeAdvice;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.execution.*;
import com.uten.imp.features.warehouse.materialbin.WorkshopTaskMaterialStockQueryService;
import com.uten.imp.security.*;
import com.uten.imp.support.BusinessNoticeFixtures;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.util.*;
import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.assertj.core.api.Assertions.*;

/** Actual material-analysis issuance and ordinary users, never legacy-plan insertion. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false", "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false", "uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true", "uten.storage.malware-scan.provider=test-only", "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789", "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test", "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class TaskReadScopesEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PlatformTransactionManager transactions;
    @Autowired TxSessionVars tx;
    @Autowired MaterialAnalysisService analyses;
    @Autowired MaterialAnalysisCommandService commands;
    @Autowired ProductionExecutionWorkbenchService tasks;
    @Autowired ProductionWorkshopTaskController controller;
    @Autowired ProductionExecutionSegmentService segments;
    @Autowired ProductionPlanningUrgeService urges;
    @Autowired ProductionWorkshopTaskExportService exports;
    @Autowired WorkshopTaskMaterialStockQueryService stockFacts;
    @Autowired ReadScopeVersionAuthority scopes;
    @Autowired SecurityContextCurrentUser current;
    FullChainEndToEndTest fixture;
    record Task(UUID plan,UUID segment,UUID workshop,UUID employee) { }
    @BeforeEach void prepare(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);}
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void explicitBrowseReadsAllTasksAndFactsButKeepsTheOriginalWorkAndPublicationUniverses() {
        String tag="task-read-"+UUID.randomUUID().toString().substring(0,8);var world=fixture.seedWorld(tag);
        fixture.loginAs(world.superAdminUserId());
        UUID production=db.queryForObject("SELECT id FROM departments WHERE code='DEPT_PROD'",UUID.class);
        UUID a=workshop(tag+"-a",production),b=workshop(tag+"-b",production);
        UUID workerA=user(world,tag+"-worker-a","production_execution:view","production_execution:start","production_daily_report:view","production_daily_report:create","workshop_material:view");
        UUID workerB=user(world,tag+"-worker-b","production_execution:view","production_execution:start");
        UUID employeeA=employee(workerA),employeeB=employee(workerB);
        db.update("UPDATE employees SET department_id=? WHERE id=?",a,employeeA);db.update("UPDATE employees SET department_id=? WHERE id=?",b,employeeB);
        UUID viewer=user(world,tag+"-viewer","production_execution:view","workshop_material:view","production_workshop_task:view:all");
        UUID scopeOnly=user(world,tag+"-scope-only","production_workshop_task:view:all");
        // Zero-material tasks are a normal frozen SHIP-control route, not forced READY rows.
        db.update("UPDATE goods_bom_items SET control_stage='SHIP',hard_gate=false WHERE goods_id=?",world.goodsA());
        Task own=issue(world,world.goodsA(),a,employeeA,tag+"-own");
        Task other=issue(world,world.goodsA(),b,employeeB,tag+"-other");
        Task material=issue(world,world.goodsB(),b,employeeB,tag+"-material");
        fixture.confirmFullKitRoutes(own.plan());fixture.confirmFullKitRoutes(other.plan());

        fixture.loginAs(scopeOnly);
        assertThatThrownBy(()->controller.list(1,50,tag,"PREPARING",null,null,null,null,null,null,null,null,null))
                .isInstanceOf(org.springframework.security.access.AccessDeniedException.class);
        fixture.loginAs(viewer);
        assertThat(tasks.workshopTasks(1,50,tag,"PREPARING",null,null,null).getItems())
                .extracting(ProductionExecutionWorkbenchSegment::segmentId).contains(own.segment(),other.segment(),material.segment());
        assertThat(tasks.workshopTaskFacets(tag,"PREPARING",null,null,null,null,null).get("segment")).hasSize(3);
        var facts=tasks.workshopTaskMaterials(material.segment());
        assertThat(facts).filteredOn(row->row.goodsCode().equals("C-"+tag)).singleElement().satisfies(row->assertThat(row.requiredQty()).isEqualByComparingTo("6"));
        assertThat(facts).filteredOn(row->row.goodsCode().equals("D-"+tag)).singleElement().satisfies(row->assertThat(row.requiredQty()).isEqualByComparingTo("10"));
        assertThat(tasks.workshopTaskCount()).isZero();
        assertThatThrownBy(controller::count).isInstanceOf(org.springframework.security.access.AccessDeniedException.class);
        assertThatThrownBy(()->exports.export(Map.of("status","PREPARING","keyword",tag),null,null)).isInstanceOf(ApiException.class);
        grant(world.superAdminUserId(),viewer,"production_report:export");fixture.loginAs(viewer);
        assertThat(exports.export(Map.of("status","PREPARING","keyword",tag),null,null).total()).isEqualTo(3);

        grant(world.superAdminUserId(),workerA,"production_workshop_task:view:all");fixture.loginAs(workerA);
        var mixed=tasks.workshopTasks(1,50,tag,"PREPARING",null,null,null).getItems();
        assertThat(mixed).filteredOn(row->row.segmentId().equals(own.segment())).singleElement().satisfies(row->assertThat(row.canStart()).isTrue());
        assertThat(mixed).filteredOn(row->!row.segmentId().equals(own.segment())).allSatisfy(row->{
            assertThat(row.canStart()).isFalse();assertThat(row.canReport()).isFalse();assertThat(row.canRequestDraw()).isFalse();
            assertThat(row.canUrgePlanning()).isFalse();assertThat(row.allowedActions()).isEmpty();
        });
        assertThat(tasks.workshopTaskCount()).isEqualTo(1L);
        assertThat(stockFacts.readiness(other.segment()).allowedActions()).isEmpty();
        assertThatThrownBy(()->urges.urge(material.segment())).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->segments.start(other.plan(),other.segment(),new SegmentTransitionRequest(version(other.segment()),tag+"-forbidden")))
                .isInstanceOf(ApiException.class);
        assertThat(db.queryForObject("SELECT status FROM production_execution_segments WHERE id=?",String.class,other.segment())).isEqualTo("READY");
        segments.start(own.plan(),own.segment(),new SegmentTransitionRequest(version(own.segment()),tag+"-start-own"));
        assertThat(db.queryForObject("SELECT status FROM production_execution_segments WHERE id=?",String.class,own.segment())).isEqualTo("IN_PROGRESS");

        // Same permissions + read-all, but actual assignment shrinks during a read.
        db.update("INSERT INTO employee_secondary_departments(employee_id,department_id) VALUES(?,?)",employeeA,b);
        var req=new org.springframework.mock.web.MockHttpServletRequest("GET","/api/production/workshop-tasks");
        var res=new org.springframework.mock.web.MockHttpServletResponse();
        new NativeTaskReadScopeInterceptor(scopes,current).preHandle(req,res,new Object());
        var old=tasks.workshopTasks(1,50,tag,"PREPARING",null,null,null);
        db.update("DELETE FROM employee_secondary_departments WHERE employee_id=? AND department_id=?",employeeA,b);
        assertThatThrownBy(()->new ReportReadScopeAdvice(scopes).beforeBodyWrite(old,null,org.springframework.http.MediaType.APPLICATION_JSON,
                org.springframework.http.converter.json.JacksonJsonHttpMessageConverter.class,
                new org.springframework.http.server.ServletServerHttpRequest(req),new org.springframework.http.server.ServletServerHttpResponse(res)))
                .isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.READ_SCOPE_CHANGED));

        fixture.loginAs(viewer);String first=scopes.scopeFor("native_workshop_tasks",current.get().orElseThrow());
        var grantRead=new org.springframework.mock.web.MockHttpServletRequest("GET","/api/production/workshop-tasks");
        new NativeTaskReadScopeInterceptor(scopes,current).preHandle(grantRead,res,new Object());
        admin(world.superAdminUserId(),()->db.update("UPDATE user_permission_overrides SET active=false WHERE user_id=? AND permission_id=(SELECT id FROM permissions WHERE code='production_workshop_task:view:all')",viewer));
        assertThatThrownBy(()->new ReportReadScopeAdvice(scopes).beforeBodyWrite(old,null,org.springframework.http.MediaType.APPLICATION_JSON,
                org.springframework.http.converter.json.JacksonJsonHttpMessageConverter.class,
                new org.springframework.http.server.ServletServerHttpRequest(grantRead),new org.springframework.http.server.ServletServerHttpResponse(res)))
                .isInstanceOf(ApiException.class);
        fixture.loginAs(viewer);assertThat(tasks.workshopTasks(1,50,tag,"PREPARING",null,null,null).getItems()).isEmpty();
        grant(world.superAdminUserId(),viewer,"production_workshop_task:view:all");fixture.loginAs(viewer);
        assertThat(scopes.scopeFor("native_workshop_tasks",current.get().orElseThrow())).isNotEqualTo(first);
    }
    private UUID user(FullChainEndToEndTest.World world,String tag,String... codes){
        UUID[] id=new UUID[1];admin(world.superAdminUserId(),()->id[0]=fixture.createUserWithPerms(world,tag,codes));return id[0];
    }
    private void grant(UUID admin,UUID user,String...codes){admin(admin,()->BusinessNoticeFixtures.grant(db,user,codes));}
    private void admin(UUID user,Runnable action){fixture.loginAs(user);new TransactionTemplate(transactions).executeWithoutResult(status->{tx.bind();action.run();});}
    private UUID employee(UUID user){return db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,user);}
    private UUID workshop(String tag,UUID parent){UUID id=UUID.randomUUID();db.update("INSERT INTO departments(id,code,name,parent_id,level) VALUES(?,?,?,?,'二级班组')",id,"WS-"+tag,"Scope workshop "+tag,parent);return id;}
    private long version(UUID segment){return db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?",Long.class,segment);}
    private Task issue(FullChainEndToEndTest.World w,UUID goods,UUID workshop,UUID employee,String tag){
        fixture.loginAs(w.superAdminUserId());
        var date=BusinessTime.today();var preview=analyses.preview(new PreviewRequest(null,null,null,w.warehouseId(),tag+"-preview",
                List.of(new PreviewItem("OTHER",null,goods,null,w.unitId(),tag,"scope workflow",date.plusDays(7),new BigDecimal("2")))));
        var product=preview.products().getFirst();var root=preview.flatMaterials().stream().filter(row->row.materialLineId().equals(product.rootMaterialLineId())).findFirst().orElseThrow();
        analyses.saveRoutes(preview.analysisId(),new RouteRequest(preview.version(),preview.fingerprint(),tag+"-make",List.of(new RouteDecision(root.materialLineId(),root.actionGroupKey(),"MAKE",null))));
        var current=analyses.detail(preview.analysisId());
        var plan=commands.issueWorkshopPlans(preview.analysisId(),new IssueWorkshopPlansRequest(current.version(),current.fingerprint(),tag+"-issue",w.warehouseId(),date,null,true,
                List.of(new IssueWorkshopPlansRequest.IssuePlanLine(null,product.analysisLineId(),new BigDecimal("2"),date,null,workshop,null,employee,null,null)),true)).plans().getFirst();
        return new Task(plan.planId(),plan.segmentIds().getFirst(),workshop,employee);
    }
}
