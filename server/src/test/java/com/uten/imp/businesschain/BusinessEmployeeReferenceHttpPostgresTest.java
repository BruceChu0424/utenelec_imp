package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.boot.webmvc.test.autoconfigure.MockMvcPrint;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.springframework.web.servlet.mvc.method.annotation.ResponseBodyAdvice;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/** Real PostgreSQL, security interceptors, controllers and immutable publication proof. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.workshop-material.auto-close.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@AutoConfigureMockMvc(print=MockMvcPrint.NONE)
@Import(BusinessEmployeeReferenceHttpPostgresTest.ProbeConfiguration.class)
class BusinessEmployeeReferenceHttpPostgresTest {
    static final String API="/api/org/employee-references";
    static final String WORKSHOP_DEFAULTS="/api/production/workshop-assignment-defaults";
    static final String ARRIVAL="WAREHOUSE_ARRIVAL_RECEIVER";
    static final String OUTBOUND="WAREHOUSE_SUBCONTRACT_OPERATOR";
    static final String MATERIAL="WORKSHOP_MATERIAL_ISSUER";
    static final Set<String> FIELDS=Set.of("id","code","fullName","departmentId","departmentName","positionName","status","accountStatus");
    // Exact 52-code shape independently read by genuine admin on current43.
    // Synthetic fixture identities below, never the production account or token.
    static final String[] ACTUAL_52={
        "ai:use","attachment:download","attachment:upload","attachment:view","color:view","company_file:view","expense:apply",
        "goods:view","material_category:view","mould:view","mould_category:view","notice:read","payroll:view:self",
        "procurement_iqc_rejection:view","profile:edit:self","stock:count:submit","stock:view","stock_doc:approve","stock_doc:create",
        "stock_doc:delete","stock_doc:edit","stock_doc:issue","stock_doc:view","stock_report:export","stock_report:view",
        "subcontract_material_issue:approve","subcontract_material_issue:edit","subcontract_material_issue:view","subcontract_material_return:view",
        "subcontract_outbound:execute","subcontract_outbound:view","subcontract_waste:view","suggestion:submit","unit:view","visitor:host_confirm",
        "warehouse:export","warehouse:view","warehouse_inbound:stock_in","warehouse_inbound:view","warehouse_iqc_return:view",
        "warehouse_iqc_stock_in:confirm","warehouse_iqc_stock_in:view","warehouse_purchase_receipt_history:view","warehouse_sales_outbound:execute",
        "warehouse_sales_outbound:view","warehouse_subcontract_finished_return_history:view","warehouse_subcontract_material_return_history:view",
        "warehouse_subcontract_outbound_history:view","warehouse_subcontract_receipt_history:view","warehouse_subcontract_waste_history:view",
        "workshop_material:issue","workshop_material:view"};
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MockMvc http;
    @Autowired ObjectMapper json;
    @Autowired PlatformTransactionManager transactionManager;
    FullChainEndToEndTest fixture;
    FullChainEndToEndTest.World world;
    String tag;
    UUID operator;
    @BeforeEach void prepare() {
        fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        tag="refs-"+UUID.randomUUID().toString().substring(0,8);
        world=fixture.seedWorld(tag);
        operator=fixture.createUserWithPerms(world,tag+"-actual52",ACTUAL_52);
        fixture.loginAs(operator);
        AuthUser actor=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        assertFalse(actor.isSuperAdmin());assertEquals(52,actor.getPermissions().size());
        assertFalse(actor.getPermissions().contains("employee:view"));
    }
    @AfterEach void clear() {PublicationProbe.PENDING.remove();SecurityContextHolder.clearContext();}
    org.springframework.mock.web.MockHttpServletResponse exchange(
            org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder request) throws Exception {
        var actor=SecurityContextHolder.getContext().getAuthentication();
        if (actor != null) request.with(authentication(actor));
        try {return http.perform(request).andReturn().getResponse();}
        finally {SecurityContextHolder.getContext().setAuthentication(actor);}
    }
    JsonNode read(String path,Map<String,String> parameters,int status) throws Exception {
        var request=get(path);parameters.forEach(request::param);
        var response=exchange(request);assertEquals(status,response.getStatus(),response.getContentAsString());
        return response.getContentAsByteArray().length==0?json.nullNode():json.readTree(response.getContentAsByteArray());
    }
    Map<String,String> query(String purpose) {return Map.of("purpose",purpose);}
    Set<String> fields(JsonNode node) {Set<String> result=new HashSet<>();node.fieldNames().forEachRemaining(result::add);return result;}
    UUID person(UUID department,UUID position,String suffix,String status,String account) {
        UUID id=UUID.randomUUID();String code="EP-"+tag+"-"+suffix;
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,position_id,hire_date,status,employment_type) VALUES (?,?,?,'其他',?,?,DATE '2001-08-17',?,'regular')",
                id,code,"Person "+tag+" "+suffix,department,position,status);
        if(account!=null) {db.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,is_super_admin,status) VALUES (?,?,?,'synthetic-picker-only',false,false,?)",UUID.randomUUID(),id,"REFUSER-"+id,account);}
        return id;
    }
    UUID department(UUID parent,String suffix) {
        UUID id=UUID.randomUUID();db.update("INSERT INTO departments(id,code,name,parent_id,level) SELECT ?,?,?,id,'二级班组' FROM departments WHERE id=?",id,"DP-"+tag+"-"+suffix,"Department "+tag+" "+suffix,parent);return id;
    }
    UUID position(UUID department) {UUID id=UUID.randomUUID();db.update("INSERT INTO positions(id,code,name,department_id) VALUES (?,?,?,?)",id,"POS-"+tag,"Position "+tag,department);return id;}
    void revoke(UUID user,String code) {db.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect) SELECT ?,id,'revoke' FROM permissions WHERE code=? ON CONFLICT(user_id,permission_id) DO UPDATE SET effect='revoke',active=TRUE",user,code);}
    UUID createOperator(String suffix,String... codes) {
        return new TransactionTemplate(transactionManager).execute(status->{
            db.queryForObject("SELECT set_config('app.actor_id',?,true)",String.class,world.superAdminUserId().toString());
            return fixture.createUserWithPerms(world,tag+suffix,codes);
        });
    }

    @Test void actual52OperatorGetsOnlyBusinessLabelsWhileHrRosterAndDetailStayForbidden() throws Exception {
        UUID pos=position(world.departmentId());UUID target=person(world.departmentId(),pos,"visible","active",null);
        JsonNode result=read(API,Map.of("purpose",ARRIVAL,"search","Person "+tag),200);
        assertEquals(1,result.path("total").asInt());JsonNode row=result.path("items").get(0);
        assertEquals(FIELDS,fields(row));assertEquals(target.toString(),row.path("id").asText());
        assertEquals("Position "+tag,row.path("positionName").asText());assertEquals("notProvisioned",row.path("accountStatus").asText());
        read("/api/org/employees",Map.of(),403);read("/api/org/employees/"+target,Map.of(),403);
        assertEquals(0,read(API,Map.of("purpose",ARRIVAL,"search","2001-08-17"),200).path("total").asLong(),"Hidden HR dates must not become a reference search oracle");
    }

    @Test void narrowArrivalActionNeedsNeitherHrNorFullDepartmentOrCompanyFileAuthority() throws Exception {
        UUID minimal=fixture.createUserWithPerms(world,tag+"-minimal","warehouse_inbound:view","warehouse_inbound:stock_in");
        revoke(minimal,"company_file:view");fixture.loginAs(minimal);
        AuthUser actor=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        assertFalse(actor.getPermissions().contains("company_file:view"));assertFalse(actor.getPermissions().contains("department:view"));
        read(API,query(ARRIVAL),200);JsonNode tree=read(API+"/departments",query(ARRIVAL),200);
        assertTrue(tree.isArray());assertFalse(tree.isEmpty());assertTree(tree);
        read("/api/org/departments/tree",Map.of(),403);read("/api/org/departments/employee-picker-tree",Map.of(),403);
    }

    @Test void warehouseDepartmentReceiverCandidatesNeedOnlyTheInboundOperationAndNeverHrRosterAccess() throws Exception {
        UUID warehouse=db.queryForObject("SELECT id FROM departments WHERE code='SUB_WH' AND NOT is_deleted",UUID.class);
        UUID receiver=person(warehouse,null,"warehouse-receiver","active",null);
        UUID minimal=createOperator("-warehouse-receiver-only","warehouse_inbound:view","warehouse_inbound:stock_in");
        fixture.loginAs(minimal);
        AuthUser actor=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        assertFalse(actor.getPermissions().contains("employee:view"));
        assertFalse(actor.getPermissions().contains("department:view"));
        JsonNode tree=read(API+"/departments",query(ARRIVAL),200);
        assertTrue(tree.findValuesAsText("code").contains("SUB_WH"));
        JsonNode result=read(API,Map.of("purpose",ARRIVAL,"departmentId",warehouse.toString(),
                "includeSubtree","true","search",tag+" warehouse-receiver","size","1"),200);
        assertEquals(1,result.path("total").asInt());
        JsonNode row=result.path("items").get(0);
        assertEquals(receiver.toString(),row.path("id").asText());
        assertEquals("EP-"+tag+"-warehouse-receiver",row.path("code").asText());
        assertEquals("Person "+tag+" warehouse-receiver",row.path("fullName").asText());
        assertEquals(warehouse.toString(),row.path("departmentId").asText());
        assertFalse(row.path("departmentName").asText().isBlank());
        assertEquals("notProvisioned",row.path("accountStatus").asText(),"A receiver does not need a login account");
        assertEquals(FIELDS,fields(row));
        read("/api/org/employees",Map.of(),403);
        read("/api/org/employees/"+receiver,Map.of(),403);
        read("/api/org/departments/tree",Map.of(),403);
        read(API,query("PRODUCTION_REPORT_WORKER"),403);

        UUID hrReader=createOperator("-hr-cannot-receive","employee:view");fixture.loginAs(hrReader);
        read(API,query(ARRIVAL),403);
        read(API+"/departments",query(ARRIVAL),403);
    }

    @Test void relatedWarehouseAndProductionPersonPickersUseTheirOwnCommandsWithoutHrAuthority() throws Exception {
        int scenarioIndex=0;
        for(String[] scenario:List.of(
                new String[]{MATERIAL,"workshop_material:issue"},
                new String[]{"PRODUCTION_REPORT_WORKER","production_daily_report:create"},
                new String[]{"PURCHASE_RECEIPT_PERSON","purchase_receipt:create"})) {
            UUID writer=createOperator("-person-operation-"+scenarioIndex++,scenario[1]);fixture.loginAs(writer);
            AuthUser actor=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();
            assertFalse(actor.getPermissions().contains("employee:view"));
            JsonNode candidates=read(API,Map.of("purpose",scenario[0],"search",tag),200);
            assertTrue(candidates.path("total").asLong()>0);
            assertEquals(FIELDS,fields(candidates.path("items").get(0)));
            assertFalse(read(API+"/departments",query(scenario[0]),200).isEmpty());
            read("/api/org/employees",Map.of(),403);
            read("/api/org/employees/"+world.employeeId(),Map.of(),403);
            read(API,query(ARRIVAL),403);
        }
    }

    @Test void existingMinimalOrganizationRolesDoNotOpenHrOrUnrelatedPersonDirectories() throws Exception {
        for(String permission:List.of("client:assign","employee:handover","employee:offboard")) {
            UUID actorId=createOperator("-minimal-tree-"+permission.replace(':','-'),permission);
            fixture.loginAs(actorId);
            AuthUser actor=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();
            assertFalse(actor.getPermissions().contains("employee:view"));
            assertFalse(actor.getPermissions().contains("department:view"));
            JsonNode tree=read("/api/org/departments/employee-picker-tree",Map.of(),200);
            assertTrue(tree.isArray());assertFalse(tree.isEmpty());assertTree(tree);
            read("/api/org/departments/tree",Map.of(),403);
            read("/api/org/employees",Map.of(),403);
            read(API,query(ARRIVAL),403);
        }
        AuthUser visitor=AuthUser.visitor(UUID.randomUUID(),"minimal-tree-visitor","V-MIN-TREE",Set.of("visitor:apply"));
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(visitor,null,visitor.getAuthorities()));
        read("/api/org/departments/employee-picker-tree",Map.of(),403);
    }
    void assertTree(JsonNode nodes) {for(JsonNode row:nodes){assertEquals(Set.of("id","code","name","level","parentId","children"),fields(row));assertTree(row.path("children"));}}

    @Test void pagingVisibleKeywordAndDepartmentSubtreeUseExactSharedFilters() throws Exception {
        UUID child=department(world.departmentId(),"child");UUID grandchild=department(child,"grandchild");UUID outside=department(world.departmentId(),"outside");
        UUID pos=position(child);
        UUID a=person(child,pos,"a","active",null),b=person(grandchild,pos,"b","resigned","disabled");person(outside,null,"outside","active","locked");
        JsonNode exact=read(API,Map.of("purpose",ARRIVAL,"search",tag,"departmentId",child.toString()),200);
        assertEquals(1,exact.path("total").asInt());assertEquals(a.toString(),exact.path("items").get(0).path("id").asText());
        Map<String,String> q=new HashMap<>(Map.of("purpose",ARRIVAL,"search",tag,"departmentId",child.toString(),"includeSubtree","true","size","1"));
        JsonNode first=read(API,q,200);q.put("page","2");JsonNode second=read(API,q,200);
        assertEquals(2,first.path("total").asInt());assertEquals(2,first.path("totalPages").asInt());
        assertEquals(Set.of(a.toString(),b.toString()),Set.of(first.path("items").get(0).path("id").asText(),second.path("items").get(0).path("id").asText()));
        q.put("accountStatus","disabled");q.put("page","1");assertEquals(b.toString(),read(API,q,200).path("items").get(0).path("id").asText());
        q.remove("accountStatus");q.put("statuses","resigned");assertEquals(1,read(API,q,200).path("total").asInt());
        assertEquals(2,read(API,Map.of("purpose",ARRIVAL,"search","Position "+tag),200).path("total").asInt());
    }

    @Test void pagedPersonSearchFindsAncestorPathsWhileKeepingPurposeAndSelectedSubtree() throws Exception {
        UUID ancestor=department(world.departmentId(),"path-root"),leaf=department(ancestor,"path-leaf");
        String rootName="祖先_%\\"+tag;
        db.update("UPDATE departments SET name=? WHERE id=?",rootName,ancestor);
        UUID target=person(leaf,null,"path-target","active",null);
        person(world.departmentId(),null,"outside-path","active",null);
        Map<String,String> filters=new HashMap<>(Map.of("purpose",ARRIVAL,"search",rootName+" Person","size","1"));
        JsonNode result=read(API,filters,200);
        assertEquals(1,result.path("total").asInt());
        assertEquals(target.toString(),result.path("items").get(0).path("id").asText());
        assertEquals(FIELDS,fields(result.path("items").get(0)));
        filters.put("departmentId",world.departmentId().toString());
        filters.put("includeSubtree","false");
        assertEquals(0,read(API,filters,200).path("total").asInt());
        filters.put("departmentId",ancestor.toString());filters.put("includeSubtree","true");
        assertEquals(1,read(API,filters,200).path("total").asInt());
    }

    @Test void referencedEmployeeAccountStateDoesNotChangePhysicalPersonLegalityAndEchoIsBounded() throws Exception {
        UUID noAccount=person(world.departmentId(),null,"no-account","active",null);
        UUID disabled=person(world.departmentId(),null,"disabled","active","disabled");
        UUID locked=person(world.departmentId(),null,"locked","onLeave","locked");
        UUID resigned=person(world.departmentId(),null,"resigned","resigned",null);
        UUID deleted=person(world.departmentId(),null,"deleted","active",null);db.update("UPDATE employees SET is_deleted=true WHERE id=?",deleted);
        JsonNode list=read(API,Map.of("purpose",ARRIVAL,"search","Person "+tag),200);
        assertEquals(4,list.path("total").asInt());
        var ids=String.join(",",disabled.toString(),noAccount.toString(),disabled.toString(),resigned.toString(),locked.toString(),deleted.toString(),UUID.randomUUID().toString());
        JsonNode echoes=read(API+"/by-ids",Map.of("purpose",ARRIVAL,"ids",ids),200);
        assertEquals(4,echoes.size());assertEquals(disabled.toString(),echoes.get(0).path("id").asText());assertEquals("disabled",echoes.get(0).path("accountStatus").asText());
        assertEquals("resigned",echoes.get(2).path("status").asText());
        for(JsonNode row:echoes){assertEquals(FIELDS,fields(row));}
        read(API+"/by-ids",Map.of("purpose",ARRIVAL,"ids",String.join(",",Collections.nCopies(101,noAccount.toString()))),422);
    }

    @Test void readOnlyScopeHrOnlyAndAnotherOperationDoNotOpenThePurpose() throws Exception {
        for(String[] codes:List.of(new String[]{"warehouse_inbound:view","warehouse_task:view:all"},new String[]{"employee:view"},new String[]{"workshop_material:view","workshop_material:issue"})) {
            UUID reader=createOperator("-reader-"+UUID.randomUUID(),codes);fixture.loginAs(reader);
            read(API,query(ARRIVAL),403);read(API+"/departments",query(ARRIVAL),403);
            int echo=Arrays.asList(codes).contains("warehouse_inbound:view")?200:403;
            read(API+"/by-ids",Map.of("purpose",ARRIVAL,"ids",world.employeeId().toString()),echo);
        }
    }

    @Test void eachOtherPurposeUsesItsExactExistingCommandAndNoGenericWriteUnion() throws Exception {
        read(API,query(OUTBOUND),200);read(API,query(MATERIAL),200);
        UUID editor=fixture.createUserWithPerms(world,tag+"-outbound","subcontract_outbound:view","subcontract_outbound:execute","subcontract_material_issue:view","subcontract_material_issue:edit");
        fixture.loginAs(editor);read(API,query(OUTBOUND),200);read(API,query(MATERIAL),403);
        revoke(editor,"subcontract_material_issue:edit");fixture.loginAs(editor);read(API,query(OUTBOUND),403);
        read(API,query("UNKNOWN_PURPOSE"),422);
    }

    @Test void anonymousAndVisitorAreDeniedButFormalReadOnlySimulationRetainsTargetReads() throws Exception {
        SecurityContextHolder.clearContext();assertEquals(401,exchange(get(API).param("purpose",ARRIVAL)).getStatus());
        AuthUser visitor=AuthUser.visitor(UUID.randomUUID(),"synthetic-visitor","V-REF",Set.of("warehouse_inbound:view","warehouse_inbound:stock_in"));
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(visitor,null,visitor.getAuthorities()));read(API,query(ARRIVAL),403);
        fixture.loginAs(operator);var real=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        var simulated=new AuthUser(real.getId(),real.getEmployeeId(),real.getLoginAccount(),real.getPermissions(),false,true,false,false,UUID.randomUUID());
        var simulatedAuth=new UsernamePasswordAuthenticationToken(simulated,null,simulated.getAuthorities());
        SecurityContextHolder.getContext().setAuthentication(simulatedAuth);read(API,query(ARRIVAL),200);
        assertEquals(403,exchange(post("/api/warehouse/inbound/arrivals/batch")
                .contentType("application/json").content("{}")).getStatus(),"Existing write guard must still reject simulated business writes");
    }

    @Test void aRevokeBeforePublicationStillBlocksTheAlreadyBuiltMinimalResponse() throws Exception {
        PublicationProbe.PENDING.set(()->revoke(operator,"warehouse_inbound:stock_in"));
        JsonNode denied=read(API,query(ARRIVAL),403);assertEquals("READ_SCOPE_CHANGED",denied.path("code").asText());
        fixture.loginAs(operator);read(API,query(ARRIVAL),403);
    }

    @Test void approvedOtherBusinessCreateEditAndReadEchoUseOnlyTheirOwnAuthorities() throws Exception {
        UUID writer=createOperator("-finance-writer","finance_expense:view","finance_expense:create");fixture.loginAs(writer);
        read(API,query("FINANCE_EXPENSE_PERSON"),200);read(API,query("PURCHASE_ORDER_PERSON"),403);
        UUID viewer=createOperator("-finance-viewer","finance_expense:view");fixture.loginAs(viewer);
        read(API,query("FINANCE_EXPENSE_PERSON"),403);read(API+"/departments",query("FINANCE_EXPENSE_PERSON"),403);
        JsonNode echo=read(API+"/by-ids",Map.of("purpose","FINANCE_EXPENSE_PERSON","ids",world.employeeId().toString()),200);
        assertEquals(1,echo.size());assertEquals(FIELDS,fields(echo.get(0)));
        UUID inquiry=createOperator("-retired","subcontract_inquiry:view","subcontract_inquiry:create");fixture.loginAs(inquiry);
        read(API,query("SUBCONTRACT_INQUIRY_PERSON"),403);
        read(API+"/by-ids",Map.of("purpose","SUBCONTRACT_INQUIRY_PERSON","ids",world.employeeId().toString()),200);
    }

    @Test void workshopManagerFallbackUsesTheOperationPurposeWithoutGoodsLearningOrHrTreeAccess() throws Exception {
        UUID production=db.queryForObject("SELECT id FROM departments WHERE code='DEPT_PROD' AND NOT is_deleted",UUID.class);
        UUID workshop=department(production,"assignment-workshop");
        UUID manager=person(workshop,null,"assignment-manager","active",null);
        db.update("UPDATE departments SET manager_id=? WHERE id=?",manager,workshop);
        db.update("UPDATE goods SET owning_workshop_department_id=NULL,owning_responsible_employee_id=NULL WHERE id=?",world.goodsA());
        UUID writer=createOperator("-material-assigner","production_material_analysis:view","production_material_analysis:generate");
        fixture.loginAs(writer);
        String purpose="PRODUCTION_MATERIAL_OWNER";
        assertTrue(read("/api/production/material-analyses/default-workshops",Map.of("ids",world.goodsA().toString()),200).isEmpty(),
                "The old learned-default response must remain unchanged when no goods preference exists");
        JsonNode rows=read(WORKSHOP_DEFAULTS,Map.of("purpose",purpose,"ids",workshop.toString()),200);
        assertEquals(1,rows.size());assertEquals(manager.toString(),rows.get(0).path("responsibleEmployeeId").asText());
        assertEquals(Set.of("departmentId","departmentName","responsibleEmployeeId","responsibleEmployeeName"),fields(rows.get(0)));
        JsonNode tree=read(API+"/departments",Map.of("purpose",purpose),200);
        assertTrue(tree.findValues("managerId").isEmpty());assertTrue(tree.findValues("managerName").isEmpty());
        read("/api/org/departments/tree",Map.of(),403);read("/api/org/employees",Map.of(),403);
        var auth=SecurityContextHolder.getContext().getAuthentication();
        long authVersion=db.queryForObject("SELECT auth_version FROM users WHERE id=?",Long.class,writer);
        var response=exchange(get(WORKSHOP_DEFAULTS).param("purpose",purpose).param("ids",workshop.toString()));
        assertSame(auth,SecurityContextHolder.getContext().getAuthentication(),
                "A MockMvc response-header probe must retain the fixture principal for the next request");
        assertEquals(authVersion,db.queryForObject("SELECT auth_version FROM users WHERE id=?",Long.class,writer),
                "The read-only header probe must not mutate account authorization");
        assertEquals(200,response.getStatus());assertNotNull(response.getHeader("X-Uten-Read-Scope-Version"));
        assertEquals("native_workshop_tasks:browse",response.getHeader("X-Uten-Read-Scope-Domain"));
        read(WORKSHOP_DEFAULTS,Map.of("purpose","SUPPLIER_OWNER","ids",workshop.toString()),422);
        for(String[] grants:List.of(new String[]{"production_material_analysis:view"},new String[]{"employee:view"},new String[]{"finance_expense:create"})) {
            UUID reader=createOperator("-assignment-reader-"+UUID.randomUUID(),grants);fixture.loginAs(reader);
            read(WORKSHOP_DEFAULTS,Map.of("purpose",purpose,"ids",workshop.toString()),403);
        }
        UUID planner=createOperator("-plan-assigner","production_plan:create");fixture.loginAs(planner);
        read(WORKSHOP_DEFAULTS,Map.of("purpose","PRODUCTION_PLAN_OWNER","ids",workshop.toString()),200);
        read(WORKSHOP_DEFAULTS,Map.of("purpose",purpose,"ids",workshop.toString()),403);
        UUID dispatcher=createOperator("-segment-assigner","production_execution:assign");fixture.loginAs(dispatcher);
        read(WORKSHOP_DEFAULTS,Map.of("purpose","PRODUCTION_SEGMENT_OWNER","ids",workshop.toString()),200);
        db.update("UPDATE users SET must_change_password=true WHERE id=?",dispatcher);
        read(WORKSHOP_DEFAULTS,Map.of("purpose","PRODUCTION_SEGMENT_OWNER","ids",workshop.toString()),403);
    }

    @Test void workshopDefaultPublicationRejectsAChangedManagerLifecycleAndActorAuthority() throws Exception {
        UUID production=db.queryForObject("SELECT id FROM departments WHERE code='DEPT_PROD' AND NOT is_deleted",UUID.class);
        UUID workshop=department(production,"fenced-workshop");
        UUID manager=person(workshop,null,"fenced-manager","active",null);
        db.update("UPDATE departments SET manager_id=? WHERE id=?",manager,workshop);
        UUID writer=createOperator("-fenced-assigner","production_material_analysis:view","production_material_analysis:generate");
        fixture.loginAs(writer);
        Map<String,String> params=Map.of("purpose","PRODUCTION_MATERIAL_OWNER","ids",workshop.toString());
        PublicationProbe.PENDING.set(()->db.update("UPDATE employees SET status='resigned' WHERE id=?",manager));
        assertEquals("READ_SCOPE_CHANGED",read(WORKSHOP_DEFAULTS,params,403).path("code").asText());
        fixture.loginAs(writer);
        JsonNode rows=read(WORKSHOP_DEFAULTS,params,200);
        assertTrue(rows.get(0).path("responsibleEmployeeId").isNull());
        assertTrue(rows.get(0).path("responsibleEmployeeName").isNull());
        db.update("UPDATE employees SET status='probation' WHERE id=?",manager);
        fixture.loginAs(writer);
        assertEquals(manager.toString(),read(WORKSHOP_DEFAULTS,params,200).get(0).path("responsibleEmployeeId").asText());
        PublicationProbe.PENDING.set(()->revoke(writer,"production_material_analysis:generate"));
        assertEquals("READ_SCOPE_CHANGED",read(WORKSHOP_DEFAULTS,params,403).path("code").asText());
        AuthUser visitor=AuthUser.visitor(UUID.randomUUID(),"synthetic-visitor","V-ASSIGN",Set.of("production_material_analysis:view","production_material_analysis:generate"));
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(visitor,null,visitor.getAuthorities()));
        read(WORKSHOP_DEFAULTS,params,403);
    }

    @TestConfiguration(proxyBeanMethods=false) static class ProbeConfiguration {
        @Bean PublicationProbe publicationProbe(){return new PublicationProbe();}
    }
    @org.springframework.web.bind.annotation.RestControllerAdvice
    @org.springframework.core.annotation.Order(org.springframework.core.Ordered.HIGHEST_PRECEDENCE+25)
    static class PublicationProbe implements ResponseBodyAdvice<Object> {
        static final ThreadLocal<Runnable> PENDING=new ThreadLocal<>();
        @Override public boolean supports(org.springframework.core.MethodParameter p,Class<? extends org.springframework.http.converter.HttpMessageConverter<?>> c){return true;}
        @Override public Object beforeBodyWrite(Object body,org.springframework.core.MethodParameter p,org.springframework.http.MediaType media,
                Class<? extends org.springframework.http.converter.HttpMessageConverter<?>> c,org.springframework.http.server.ServerHttpRequest request,org.springframework.http.server.ServerHttpResponse response) {
            Runnable pending=PENDING.get();if(pending!=null&&(request.getURI().getPath().equals(API)||request.getURI().getPath().equals(WORKSHOP_DEFAULTS))){PENDING.remove();pending.run();}return body;
        }
    }
}
