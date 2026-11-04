package com.uten.imp.features.applications;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.policy.DepartmentApprovalScope;
import com.uten.imp.application.port.ApprovalCandidateDirectoryPort;
import com.uten.imp.common.web.*;
import com.uten.imp.features.applications.BusinessApplicationController.*;
import com.uten.imp.features.attachment.*;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.auth.model.UserAccountRepository;
import com.uten.imp.features.finance.FinanceDocumentAccessPolicy;
import com.uten.imp.features.notice.NoticeService;
import com.uten.imp.security.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.core.io.ClassPathResource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.init.ResourceDatabasePopulator;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicReference;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

/** Real PostgreSQL row locks/versions/JSON/constraints; no company services. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class BusinessApplicationPostgresTest {
    static PostgreSQLContainer postgres;
    JdbcTemplate jdbc;TransactionTemplate tx;BusinessApplicationService service;
    final ThreadLocal<AuthUser> principal=new ThreadLocal<>();
    UUID dept,otherDept,applicant,reviewer,finance,executive,initialReviewer,secondaryReviewer,viceExecutive;
    ApprovalCandidateDirectoryPort candidates;
    com.uten.imp.application.port.AttachmentEvidencePort evidence;
    FinanceDocumentAccessPolicy financeAccess;
    @BeforeAll static void start(){postgres=new PostgreSQLContainer("postgres:16-alpine");postgres.start();}
    @AfterAll static void stop(){if(postgres!=null)postgres.stop();}
    @BeforeEach void setup(){
        var ds=new DriverManagerDataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword());jdbc=new JdbcTemplate(ds);tx=new TransactionTemplate(new DataSourceTransactionManager(ds));
        jdbc.execute("DROP SCHEMA public CASCADE;CREATE SCHEMA public");
        jdbc.execute("CREATE TABLE departments(id uuid PRIMARY KEY,parent_id uuid,manager_id uuid,code text,name text,level text,permission_delegation_generation bigint DEFAULT 0,is_deleted boolean DEFAULT false)");
        jdbc.execute("CREATE TABLE employees(id uuid PRIMARY KEY,full_name text,department_id uuid,status text DEFAULT 'active',is_deleted boolean DEFAULT false)");
        jdbc.execute("CREATE TABLE suppliers(id uuid PRIMARY KEY,name text,is_deleted boolean DEFAULT false,is_hidden boolean DEFAULT false)");
        jdbc.execute("CREATE TABLE users(id uuid PRIMARY KEY,employee_id uuid,is_deleted boolean DEFAULT false,status text)");
        jdbc.execute("CREATE TABLE permissions(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),code text UNIQUE,name text,module text,category text,sort_order int,action_type text,description text,grant_policy text[],high_risk boolean,baseline boolean)");
        jdbc.execute("CREATE TABLE permission_surfaces(id uuid PRIMARY KEY,surface_key text UNIQUE,name text,sort_order int,enabled boolean)");
        jdbc.execute("CREATE TABLE permission_surface_permissions(surface_id uuid,permission_id uuid,PRIMARY KEY(surface_id,permission_id))");
        jdbc.execute("CREATE TABLE finance_expenses(id uuid PRIMARY KEY,maker_id uuid,status smallint,amount_local numeric(18,4),bill_date date,account_id uuid,is_deleted boolean DEFAULT false)");
        jdbc.execute("CREATE TABLE finance_payments(LIKE finance_expenses INCLUDING ALL)");jdbc.execute("ALTER TABLE finance_payments ADD COLUMN supplier_id uuid");
        jdbc.execute("ALTER TABLE finance_payments ADD COLUMN bill_no text, ADD COLUMN legacy_id int, ADD COLUMN legacy_import_run_id uuid, ADD COLUMN amount_authority_version smallint DEFAULT 1");
        jdbc.execute("CREATE TABLE ar_ap_ledger(id uuid PRIMARY KEY,source_doc_id uuid,source_doc_type text,direction text,open_item_kind text,status smallint,is_deleted boolean DEFAULT false,legacy_id int,legacy_import_run_id uuid,supplier_id uuid,amount_original_local numeric(18,4),amount_received_local numeric(18,4))");
        jdbc.execute("CREATE TABLE finance_payment_lines(payment_id uuid)");
        jdbc.execute("CREATE TABLE expense_claims(id uuid,finance_expense_id uuid,paid_at timestamptz,status text,applicant_id uuid,applicant_department_id uuid,approval_stage text,approval_participants text,approval_round int DEFAULT 0,is_deleted boolean DEFAULT false)");
        jdbc.execute("CREATE TABLE expense_claim_events(event_type text,CONSTRAINT expense_claim_events_type_chk CHECK(event_type IN('CREATED')))");
        jdbc.execute("CREATE TABLE business_identifier_namespaces(namespace_key text,identifier_family text,fixed_prefix text,source_table text,identifier_column text,discriminator_value text)");
        jdbc.execute("CREATE FUNCTION fn_reserve_business_document_identifier() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$");
        jdbc.execute("CREATE FUNCTION fn_audit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF TG_OP='DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF; END $$");
        try{jdbc.execute(new ClassPathResource("db/migration/V1001__business_application_workflows.sql").getContentAsString(java.nio.charset.StandardCharsets.UTF_8));}
        catch(java.io.IOException ex){throw new IllegalStateException(ex);}
        dept=UUID.randomUUID();otherDept=UUID.randomUUID();applicant=UUID.randomUUID();reviewer=UUID.randomUUID();finance=UUID.randomUUID();executive=UUID.randomUUID();initialReviewer=UUID.randomUUID();secondaryReviewer=UUID.randomUUID();viceExecutive=UUID.randomUUID();
        for(UUID d:List.of(dept,otherDept))jdbc.update("INSERT INTO departments(id,code,name,level) VALUES(?,?,?,'一级部门')",d,d.equals(dept)?"DEPT_SALES":"DEPT_RD","fixture");
        for(UUID e:List.of(applicant,reviewer,finance,executive,initialReviewer,secondaryReviewer,viceExecutive))jdbc.update("INSERT INTO employees(id,full_name,department_id) VALUES(?, 'fixture', ?)",e,dept);
        jdbc.execute("CREATE TABLE employee_secondary_departments(employee_id uuid,department_id uuid)");
        jdbc.execute("CREATE FUNCTION fn_mark_read_scope_domains() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NULL; END $$");
        jdbc.execute("CREATE TABLE business_outbox(id uuid PRIMARY KEY,event_type text,aggregate_type text,aggregate_id uuid,payload jsonb,dedupe_key text UNIQUE,created_by uuid)");
        try{
            String script=new ClassPathResource("db/migration/V1002__department_approval_substitution_policy.sql").getContentAsString(java.nio.charset.StandardCharsets.UTF_8);
            String start="-- EXPENSE_PAYMENT_NOTICE_PATCH:START",end="-- EXPENSE_PAYMENT_NOTICE_PATCH:END";
            int first=script.indexOf(start),last=script.indexOf(end);if(first<0||last<first)throw new IllegalStateException("Expense-only legacy notice patch markers changed");
            // Only the unrelated legacy expense-notice replacement is outside
            // this minimal fixture. Full Flyway and expense suites execute it.
            script=script.substring(0,first)+script.substring(last+end.length());jdbc.execute(script);
        }
        catch(java.io.IOException ex){throw new IllegalStateException(ex);}
        var current=mock(SecurityContextCurrentUser.class);when(current.get()).thenAnswer(i->Optional.ofNullable(principal.get()));
        evidence=mock(com.uten.imp.application.port.AttachmentEvidencePort.class);when(evidence.cleanEvidence(anyString(),any())).thenReturn(List.of(new com.uten.imp.application.port.AttachmentEvidencePort.Evidence(UUID.randomUUID(),"fixture-sha","fixture-original")));
        candidates=mock(ApprovalCandidateDirectoryPort.class);
        when(candidates.candidates(anyString(),anySet())).thenAnswer(invocation->candidates.candidates(invocation.getArgument(0)));
        for(String stage:BusinessApplicationWorkflow.scope(null)){
            UUID target=switch(stage){case "DEPARTMENT","PROCUREMENT"->reviewer;case "EXECUTIVE"->executive;case "FINANCE_INITIAL"->initialReviewer;case "FINANCE_REVIEW"->secondaryReviewer;case "VICE_EXECUTIVE"->viceExecutive;default->finance;};
            when(candidates.candidates(BusinessApplicationWorkflow.permission(stage))).thenReturn(List.of(new ApprovalCandidateDirectoryPort.Candidate(UUID.randomUUID(),target)));
        }
        var numbers=mock(com.uten.imp.common.docnumber.DocNumberService.class);var sequence=new java.util.concurrent.atomic.AtomicInteger();when(numbers.nextNumber(any())).thenAnswer(invocation->"SQ20261103"+String.format("%06d",sequence.incrementAndGet()));
        var scope=new DepartmentApprovalScope(jdbc);var routing=new com.uten.imp.application.policy.DepartmentApprovalRouting(new org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate(jdbc),scope,new ObjectMapper());
        financeAccess=mock(FinanceDocumentAccessPolicy.class);when(financeAccess.nativeReadScope(anyString(),anyString())).thenReturn(new com.uten.imp.security.DocumentAccessPolicy.NativeReadScope("1=1",null,Set.of()));
        service=new BusinessApplicationService(jdbc,new ObjectMapper(),current,mock(TxSessionVars.class),scope,evidence,new com.uten.imp.features.finance.FinanceApplicationReferenceAdapter(jdbc,financeAccess),mock(com.uten.imp.application.port.EmployeeApplicationNoticePort.class),candidates,mock(com.uten.imp.application.port.MasterReferenceValidationPort.class),numbers,routing);
    }
    AuthUser actor(UUID employee,String... permissions){return new AuthUser(UUID.randomUUID(),employee,"fixture",Set.of(permissions),false,true,false);}
    Map<String,Object> call(AuthUser u,java.util.function.Supplier<Map<String,Object>> operation){principal.set(u);try{return tx.execute(s->operation.get());}finally{principal.remove();}}
    Input input(String kind){return new Input(UUID.randomUUID(),kind,"fixture","123.45",Map.of("reason","fixture","destination","上海","startDate","2026-11-04","endDate","2026-11-05","payee","fixture"),null);}
    Action version(Map<String,Object> dto){return new Action(((Number)dto.get("version")).longValue(),null,null);}
    @Test void travelHasDepartmentAndExecutiveApprovalThenCustodyWithoutMoneyPosting(){
        var input=input("TRAVEL");var owner=actor(applicant,"application:apply:travel");var created=call(owner,()->service.create(input));
        var submitted=call(owner,()->service.act(input.id(),"submit",version(created)));
        assertThrows(ApiException.class,()->call(actor(applicant,"application:approve:department"),()->service.act(input.id(),"approve",version(submitted))));
        var department=actor(reviewer,"application:approve:department","attachment:view","attachment:download");
        var reviewed=call(department,()->service.act(input.id(),"approve",version(submitted)));
        assertEquals("EXECUTIVE",reviewed.get("approvalStage"));
        assertThrows(ApiException.class,()->call(actor(reviewer,"application:approve:executive","attachment:view","attachment:download"),()->service.act(input.id(),"approve",version(reviewed))));
        var approved=call(actor(executive,"application:approve:executive","attachment:view","attachment:download"),()->service.act(input.id(),"approve",version(reviewed)));
        assertEquals("FINANCE_RECEIVE",approved.get("approvalStage"));
        assertThrows(ApiException.class,()->call(actor(finance,"application:pay"),()->service.act(input.id(),"pay",version(approved))));
        var complete=call(actor(finance,"application:receive"),()->service.act(input.id(),"receive",version(approved)));
        assertEquals("COMPLETED",complete.get("status"));assertNull(complete.get("financeDocumentId"));
        assertEquals(5,((List<?>)complete.get("events")).size());
    }
    @Test void staleOrParallelApprovalOnlyAdvancesOneNodeAndPreservesAllRoundHistory() throws Exception {
        var input=input("TRAVEL");var owner=actor(applicant,"application:apply");var created=call(owner,()->service.create(input));
        assertEquals(created.get("id"),call(owner,()->service.create(input)).get("id"));
        var submitted=call(owner,()->service.act(input.id(),"submit",version(created)));
        var department=actor(reviewer,"application:approve:department","attachment:view","attachment:download");
        var gate=new CountDownLatch(1);var results=new CopyOnWriteArrayList<Boolean>();
        try(var executor=Executors.newFixedThreadPool(2)){
            var jobs=new ArrayList<Future<?>>();for(int i=0;i<2;i++)jobs.add(executor.submit(()->{try{gate.await();call(department,()->service.act(input.id(),"approve",version(submitted)));results.add(true);}catch(ApiException e){results.add(false);}catch(InterruptedException e){Thread.currentThread().interrupt();}}));
            gate.countDown();for(var job:jobs)job.get(15,TimeUnit.SECONDS);
        }
        assertEquals(1,results.stream().filter(Boolean::booleanValue).count());
        var state=call(owner,()->service.detail(input.id()));
        var rejected=call(actor(executive,"application:approve:executive"),()->service.act(input.id(),"reject",new Action(((Number)state.get("version")).longValue(),"补充事由",null)));
        assertEquals("REJECTED",rejected.get("status"));
        var resubmitted=call(owner,()->service.act(input.id(),"submit",version(rejected)));
        assertEquals(2,((Number)resubmitted.get("round")).intValue());assertNull(resubmitted.get("rejectReason"));
        assertEquals(2,jdbc.queryForObject("SELECT count(*) FROM business_application_submissions WHERE application_id=?",Integer.class,input.id()));
        assertTrue(call(department,()->service.detail(input.id())).get("canApprove").equals(true));
    }
    @Test void departmentScopeAndQueuesAndCountsAgreeAndWithdrawalRevokesCurrentReview(){
        var input=input("TRAVEL");var owner=actor(applicant,"application:apply");var created=call(owner,()->service.create(input));var submitted=call(owner,()->service.act(input.id(),"submit",version(created)));
        jdbc.update("UPDATE employees SET department_id=? WHERE id=?",otherDept,reviewer);
        var wrong=actor(reviewer,"application:approve:department","attachment:view","attachment:download");
        assertThrows(ApiException.class,()->call(wrong,()->service.act(input.id(),"approve",version(submitted))));
        principal.set(wrong);assertEquals(0,service.list("pending",null,null,"DEPARTMENT","DEPT_SALES",1,24).getTotal());assertEquals(0L,service.counts().get("pendingCount"));principal.remove();
        var withdrawn=call(owner,()->service.act(input.id(),"withdraw",version(submitted)));assertEquals("DRAFT",withdrawn.get("status"));
        assertEquals(1,jdbc.queryForObject("SELECT count(*) FROM business_application_submissions",Integer.class));
    }
    @Test void paymentLinksOnlyAuditedExactPostingAndLocksReversalUntilOriginalPayerCancels(){
        var in=input("PAYMENT");var owner=actor(applicant,"application:apply:payment");
        var created=call(owner,()->service.create(in));var submitted=call(owner,()->service.act(in.id(),"submit",version(created)));
        var payer=actor(finance,"application:pay","finance_expense:view","attachment:view","attachment:download");
        assertThrows(ApiException.class,()->call(payer,()->service.act(in.id(),"pay",version(submitted))));
        Map<String,Object> state=submitted;
        for(var step:List.of(Map.entry(reviewer,"DEPARTMENT"),Map.entry(initialReviewer,"FINANCE_INITIAL"),Map.entry(secondaryReviewer,"FINANCE_REVIEW"),Map.entry(executive,"EXECUTIVE"))){
            var before=state;state=call(actor(step.getKey(),BusinessApplicationWorkflow.permission(step.getValue()),"attachment:view","attachment:download"),()->service.act(in.id(),"approve",version(before)));
        }
        assertEquals("APPROVED",state.get("status"));assertEquals("PAYMENT",state.get("approvalStage"));
        UUID document=UUID.randomUUID();jdbc.update("INSERT INTO finance_expenses(id,maker_id,status,amount_local,bill_date,account_id) VALUES(?,?,0,123.45,'2026-11-01',?)",document,reviewer,UUID.randomUUID());
        var payFields=Map.<String,Object>of("financeDocumentType","EXPENSE","financeDocumentId",document.toString(),"paymentDate","2026-11-01","paymentReference","fixture-bank-1");
        var payable=state;assertThrows(ApiException.class,()->call(payer,()->service.act(in.id(),"pay",new Action(((Number)payable.get("version")).longValue(),null,payFields))));
        jdbc.update("UPDATE finance_expenses SET status=1 WHERE id=?",document);
        var paid=call(payer,()->service.act(in.id(),"pay",new Action(((Number)payable.get("version")).longValue(),null,payFields)));
        assertEquals("PAID",paid.get("status"));assertEquals(document,paid.get("financeDocumentId"));assertEquals(true,paid.get("canCancelPayment"));
        assertThrows(org.springframework.dao.DataIntegrityViolationException.class,()->jdbc.update("UPDATE finance_expenses SET status=0 WHERE id=?",document));
        assertThrows(org.springframework.dao.DataIntegrityViolationException.class,()->jdbc.update("UPDATE finance_expenses SET amount_local=99 WHERE id=?",document));
        var cancelled=call(payer,()->service.act(in.id(),"cancel-payment",new Action(((Number)paid.get("version")).longValue(),"原登记流水有误，核对后修订",null)));
        assertEquals("APPROVED",cancelled.get("status"));assertNull(cancelled.get("financeDocumentId"));
        jdbc.update("UPDATE finance_expenses SET status=0 WHERE id=?",document);
        assertEquals(1,jdbc.queryForObject("SELECT count(*) FROM business_application_events WHERE application_id=? AND action='PAYMENT_CANCELLED' AND remark LIKE '%fixture-bank-1%'",Integer.class,in.id()));
        assertEquals(true,cancelled.get("canPay"));
    }
    @Test void offboardedAccountHasNoNewWritesOrDepartmentScope(){
        jdbc.update("UPDATE employees SET status='resigned' WHERE id=?",reviewer);
        var departed=actor(reviewer,"application:apply","application:approve:department");
        assertTrue(new DepartmentApprovalScope(jdbc).load(departed).departmentIds().isEmpty());
        assertThrows(ApiException.class,()->call(departed,()->service.create(input("TRAVEL"))));
    }
    @Test void noAssigneeDoesNotPublishAnUnfinishableSubmissionAndNoticePermissionIsNotRequired(){
        var in=input("TRAVEL");var owner=actor(applicant,"application:apply");var draft=call(owner,()->service.create(in));
        when(candidates.candidates("application:approve:department")).thenReturn(List.of());
        assertThrows(ApiException.class,()->call(owner,()->service.act(in.id(),"submit",version(draft))));
        assertEquals("DRAFT",jdbc.queryForObject("SELECT status FROM business_applications WHERE id=?",String.class,in.id()));
        assertEquals(0,jdbc.queryForObject("SELECT count(*) FROM business_application_submissions",Integer.class));
        when(candidates.candidates("application:approve:department")).thenReturn(List.of(new ApprovalCandidateDirectoryPort.Candidate(UUID.randomUUID(),reviewer)));
        // Candidate only has the stage grant; missing notice:read does not block.
        var submitted=call(owner,()->service.act(in.id(),"submit",version(draft)));assertEquals("SUBMITTED",submitted.get("status"));
        when(candidates.candidates("application:approve:executive")).thenReturn(List.of(new ApprovalCandidateDirectoryPort.Candidate(UUID.randomUUID(),reviewer)));
        assertThrows(ApiException.class,()->call(actor(reviewer,"application:approve:department","attachment:view","attachment:download"),()->service.act(in.id(),"approve",version(submitted))));
        assertEquals("DEPARTMENT",jdbc.queryForObject("SELECT approval_stage FROM business_applications WHERE id=?",String.class,in.id()));
        assertEquals(0,jdbc.queryForObject("SELECT count(*) FROM business_application_events WHERE action='APPROVED'",Integer.class));
    }
    @Test void supplierNameAndPayeeAreFrozenByTheServerAndPaymentMetadataCannotBeForged(){
        UUID supplier=UUID.randomUUID();jdbc.update("INSERT INTO suppliers(id,name) VALUES(?,'真实供应商')",supplier);
        var owner=actor(applicant,"application:apply:supplier_payment");var fields=Map.<String,Object>of("reason","供应生产材料付款","paymentUnit","本公司","supplierId",supplier.toString(),"supplierName","伪造名称","payee","错误收款人");
        var in=new Input(UUID.randomUUID(),"SUPPLIER_PAYMENT","材料付款","123.45",fields,null);
        var created=call(owner,()->service.create(in));var stored=(Map<?,?>)created.get("fields");assertEquals("真实供应商",stored.get("supplierName"));assertEquals("真实供应商",stored.get("payee"));
        assertEquals(created.get("id"),call(owner,()->service.create(in)).get("id"));
        jdbc.update("UPDATE suppliers SET name='更名后的供应商',is_hidden=true WHERE id=?",supplier);
        var edited=call(owner,()->service.update(in.id(),new Input(in.id(),in.kind(),"修订材料付款",in.amount(),fields,((Number)created.get("version")).longValue())));
        assertEquals("真实供应商",((Map<?,?>)edited.get("fields")).get("supplierName"));
        var forged=new LinkedHashMap<String,Object>(fields);forged.put("paymentDate","2026-11-01");
        assertThrows(ApiException.class,()->call(owner,()->service.create(new Input(UUID.randomUUID(),in.kind(),in.title(),in.amount(),forged,null))));
    }
    @Test void managerOwnApplicationsUseOnlyTheConfiguredCrossDepartmentSubstituteAndExpireOnConfigurationChange(){
        jdbc.update("UPDATE departments SET manager_id=? WHERE id=?",applicant,dept);
        jdbc.update("UPDATE employees SET department_id=? WHERE id=?",otherDept,finance);
        jdbc.update("INSERT INTO department_approval_policies(department_id,substitute_employee_id,version) VALUES(?,?,1)",dept,finance);
        when(candidates.candidates("application:approve:department")).thenReturn(List.of(new ApprovalCandidateDirectoryPort.Candidate(UUID.randomUUID(),finance),new ApprovalCandidateDirectoryPort.Candidate(UUID.randomUUID(),executive)));
        var owner=actor(applicant,"application:apply:travel");var in=input("TRAVEL");var draft=call(owner,()->service.create(in));var pending=call(owner,()->service.act(in.id(),"submit",version(draft)));
        var substitute=actor(finance,"application:approve:department","attachment:view","attachment:download");
        assertEquals(true,call(substitute,()->service.detail(in.id())).get("canApprove"));
        var worker=actor(reviewer,"application:apply:travel");var workerInput=input("TRAVEL");var workerDraft=call(worker,()->service.create(workerInput));call(worker,()->service.act(workerInput.id(),"submit",version(workerDraft)));
        assertThrows(ApiException.class,()->call(substitute,()->service.detail(workerInput.id())));
        principal.set(substitute);assertEquals(1,service.list("pending",null,null,"DEPARTMENT","DEPT_SALES",1,24).getTotal());assertEquals(1L,service.counts().get("pendingCount"));principal.remove();
        jdbc.update("UPDATE department_approval_policies SET version=2 WHERE department_id=?",dept);
        assertThrows(ApiException.class,()->call(substitute,()->service.act(in.id(),"approve",version(pending))));
        assertEquals(true,call(owner,()->service.detail(in.id())).get("approvalRoutingStale"));
        principal.set(owner);assertEquals(1L,service.counts().get("mineRoutingStaleCount"));assertEquals(0L,service.counts().get("mineProcessingCount"));assertEquals(1,service.list("mine",null,"ACTION_REQUIRED",null,null,1,24).getTotal());principal.remove();
        var withdrawn=call(owner,()->service.act(in.id(),"withdraw",version(pending)));var resubmitted=call(owner,()->service.act(in.id(),"submit",version(withdrawn)));
        assertEquals(true,call(substitute,()->service.detail(in.id())).get("canApprove"));assertEquals(false,resubmitted.get("approvalRoutingStale"));assertEquals(2,((Number)resubmitted.get("round")).intValue());
    }
    @Test void managerOwnApplicationWithoutSubstituteDoesNotFallBackToDepartmentCoworkers(){
        jdbc.update("UPDATE departments SET manager_id=? WHERE id=?",applicant,dept);
        var owner=actor(applicant,"application:apply:travel");var in=input("TRAVEL");var draft=call(owner,()->service.create(in));
        assertThrows(ApiException.class,()->call(owner,()->service.act(in.id(),"submit",version(draft))));
        assertEquals("DRAFT",jdbc.queryForObject("SELECT status FROM business_applications WHERE id=?",String.class,in.id()));
    }
    @Test void supplierManagerOwnApplicationStartsAtProcurementWithoutAnUnrelatedDepartmentSubstitute(){
        jdbc.update("UPDATE departments SET manager_id=? WHERE id=?",applicant,dept);
        UUID supplier=UUID.randomUUID();jdbc.update("INSERT INTO suppliers(id,name) VALUES(?,'材料供应商')",supplier);
        var owner=actor(applicant,"application:apply:supplier_payment");var in=new Input(UUID.randomUUID(),"SUPPLIER_PAYMENT","负责人经办材料货款","123.45",Map.of("supplierId",supplier.toString(),"paymentUnit","本公司","reason","供应生产材料"),null);
        var draft=call(owner,()->service.create(in));var submitted=call(owner,()->service.act(in.id(),"submit",version(draft)));
        assertEquals("PROCUREMENT",submitted.get("approvalStage"));
        assertNull(jdbc.queryForObject("SELECT department_approval_snapshot::text FROM business_applications WHERE id=?",String.class,in.id()));
        assertThrows(ApiException.class,()->call(actor(applicant,"application:approve:procurement","attachment:view","attachment:download"),()->service.act(in.id(),"approve",version(submitted))));
        var next=call(actor(reviewer,"application:approve:procurement","attachment:view","attachment:download"),()->service.act(in.id(),"approve",version(submitted)));
        assertEquals("FINANCE_REVIEW",next.get("approvalStage"));
    }
    @Test void supplierPaperRouteRequiresProcurementFinanceViceExecutiveAndExecutiveAndMatchingSupplierPosting(){
        UUID supplier=UUID.randomUUID(),otherSupplier=UUID.randomUUID();jdbc.update("INSERT INTO suppliers(id,name) VALUES(?,'供应商甲'),(?,'供应商乙')",supplier,otherSupplier);
        var owner=actor(applicant,"application:apply:supplier_payment");var in=new Input(UUID.randomUUID(),"SUPPLIER_PAYMENT","材料货款","123.45",Map.of("supplierId",supplier.toString(),"paymentUnit","本公司","reason","供应生产材料"),null);
        var created=call(owner,()->service.create(in));Map<String,Object> state=call(owner,()->service.act(in.id(),"submit",version(created)));
        for(var step:List.of(Map.entry(reviewer,"PROCUREMENT"),Map.entry(secondaryReviewer,"FINANCE_REVIEW"),Map.entry(viceExecutive,"VICE_EXECUTIVE"),Map.entry(executive,"EXECUTIVE"))){
            assertEquals(step.getValue(),state.get("approvalStage"));var before=state;
            state=call(actor(step.getKey(),BusinessApplicationWorkflow.permission(step.getValue()),"attachment:view","attachment:download"),()->service.act(in.id(),"approve",version(before)));
        }
        assertEquals("APPROVED",state.get("status"));UUID document=UUID.randomUUID();jdbc.update("INSERT INTO finance_payments(id,maker_id,status,amount_local,bill_date,account_id,supplier_id) VALUES(?,?,1,123.45,'2026-11-01',?,?)",document,reviewer,UUID.randomUUID(),otherSupplier);
        var payFields=Map.<String,Object>of("financeDocumentType","PAYMENT","financeDocumentId",document.toString(),"paymentDate","2026-11-01","paymentReference","supplier-bank-fixture");
        var payer=actor(finance,"application:pay","finance_payment:view","attachment:view","attachment:download");var approved=state;
        assertThrows(ApiException.class,()->call(payer,()->service.act(in.id(),"pay",new Action(((Number)approved.get("version")).longValue(),null,payFields))));
        jdbc.update("UPDATE finance_payments SET supplier_id=? WHERE id=?",supplier,document);
        var paid=call(payer,()->service.act(in.id(),"pay",new Action(((Number)approved.get("version")).longValue(),null,payFields)));
        assertEquals("PAID",paid.get("status"));assertEquals(document,paid.get("financeDocumentId"));
    }
    @Test void submissionUsesCurrentDepartmentWhileEarlierRoundKeepsItsFrozenDepartment(){
        var owner=actor(applicant,"application:apply:travel");var in=input("TRAVEL");var draft=call(owner,()->service.create(in));
        jdbc.update("UPDATE employees SET department_id=? WHERE id IN(?,?)",otherDept,applicant,finance);
        when(candidates.candidates("application:approve:department")).thenReturn(List.of(new ApprovalCandidateDirectoryPort.Candidate(UUID.randomUUID(),reviewer),new ApprovalCandidateDirectoryPort.Candidate(UUID.randomUUID(),finance)));
        var first=call(owner,()->service.act(in.id(),"submit",version(draft)));assertEquals(otherDept,first.get("departmentId"));
        var withdrawn=call(owner,()->service.act(in.id(),"withdraw",version(first)));
        jdbc.update("UPDATE employees SET department_id=? WHERE id=?",dept,applicant);
        var second=call(owner,()->service.act(in.id(),"submit",version(withdrawn)));assertEquals(dept,second.get("departmentId"));
        assertEquals(List.of(otherDept.toString(),dept.toString()),jdbc.queryForList("SELECT snapshot->>'departmentId' FROM business_application_submissions WHERE application_id=? ORDER BY round",String.class,in.id()));
    }
    @Test void administratorCapabilityDoesNotSubscribeThemToEveryApprovalTask(){
        var owner=actor(applicant,"application:apply:travel");var in=input("TRAVEL");var draft=call(owner,()->service.create(in));call(owner,()->service.act(in.id(),"submit",version(draft)));
        var audience=mock(com.uten.imp.application.port.TaskAudiencePort.class);
        var observer=new AuthUser(UUID.randomUUID(),finance,"fixture",Set.of("application:view"),false,true,false);
        when(audience.freshTaskSubject(any())).thenReturn(observer);
        org.springframework.test.util.ReflectionTestUtils.setField(service,"taskAudience",audience);
        var admin=new AuthUser(observer.getId(),finance,"fixture",Set.of("application:view","application:approve:department","application:approve:executive","application:pay"),false,true,true);
        principal.set(admin);try{assertEquals(0L,service.counts().get("pendingCount"));assertTrue(((Map<?,?>)service.counts().get("departmentScopeByCode")).isEmpty());}finally{principal.remove();}
    }
    record Prepayment(UUID id,UUID supplier,AuthUser owner,Map<String,Object> approved){}
    private Prepayment prepayment(){
        UUID supplier=UUID.randomUUID();jdbc.update("INSERT INTO suppliers(id,name) VALUES(?,'真实预付供应商')",supplier);
        var owner=actor(applicant,"application:apply:prepayment");var in=new Input(UUID.randomUUID(),"PREPAYMENT","供应商材料预付款","123.45",Map.of("supplierId",supplier.toString(),"reason","采购材料预付款"),null);
        var created=call(owner,()->service.create(in));Map<String,Object> state=call(owner,()->service.act(in.id(),"submit",version(created)));
        for(var step:List.of(Map.entry(reviewer,"DEPARTMENT"),Map.entry(initialReviewer,"FINANCE_INITIAL"),Map.entry(secondaryReviewer,"FINANCE_REVIEW"),Map.entry(executive,"EXECUTIVE"))){var before=state;state=call(actor(step.getKey(),BusinessApplicationWorkflow.permission(step.getValue()),"attachment:view","attachment:download"),()->service.act(in.id(),"approve",version(before)));}
        return new Prepayment(in.id(),supplier,owner,state);
    }
    private AuthUser cashPayer(){return actor(finance,"application:pay","attachment:view","attachment:download","attachment:upload");}
    private AuthUser bookkeeper(){return actor(viceExecutive,"application:prepayment:link_finance","finance_payment:view","attachment:view","attachment:download");}
    private Map<String,Object> cashPay(Prepayment app){return call(cashPayer(),()->service.act(app.id(),"pay",new Action(((Number)app.approved().get("version")).longValue(),null,Map.of("paymentDate","2026-11-01","paymentReference","PREPAY-CASH-001"))));}
    @Test void supplierPrepaymentRegistersOnlyCashFactsAndRemainsInProgressUntilItsOwnValidPostingExists(){
        var app=prepayment();var paid=cashPay(app);
        assertEquals("PAID",paid.get("status"));assertEquals("PENDING",paid.get("postingStatus"));assertNull(paid.get("financeDocumentId"));
        assertEquals(0,jdbc.queryForObject("SELECT count(*) FROM finance_expenses",Integer.class));assertEquals(0,jdbc.queryForObject("SELECT count(*) FROM finance_payments",Integer.class));assertEquals(0,jdbc.queryForObject("SELECT count(*) FROM ar_ap_ledger",Integer.class));
        var keeper=bookkeeper();var pending=call(keeper,()->service.detail(app.id()));assertEquals(false,pending.get("canLinkFinance"));
        principal.set(keeper);try{assertEquals(1,service.list("prepayment-posting",null,null,"FINANCE",null,1,24).getTotal());assertEquals(0L,service.counts().get("prepaymentPostingTodoCount"));assertEquals(1L,service.counts().get("prepaymentPostingInProgressCount"));assertEquals(0,service.prepaymentFinanceCandidates(app.id(),1,24,null).getTotal());}finally{principal.remove();}
        principal.set(app.owner());try{assertEquals(1L,service.counts().get("mineProcessingCount"));assertEquals(1,service.list("mine",null,"PROCESSING",null,null,1,24).getTotal());assertEquals(0,service.list("mine",null,"FINISHED",null,null,1,24).getTotal());}finally{principal.remove();}
    }
    @Test void prepaymentCannotBecomeAnExpenseAndRequiresItsOwnCleanPaymentProof(){
        var app=prepayment();var payer=cashPayer();
        var forbidden=Map.<String,Object>of("financeDocumentType","EXPENSE","financeDocumentId",UUID.randomUUID().toString(),"paymentDate","2026-11-01","paymentReference","fake-expense");
        assertThrows(ApiException.class,()->call(payer,()->service.act(app.id(),"pay",new Action(((Number)app.approved().get("version")).longValue(),null,forbidden))));
        when(evidence.cleanEvidence("BUSINESS_APPLICATION_PAYMENT",app.id())).thenReturn(List.of());
        assertThrows(ApiException.class,()->cashPay(app));
        assertEquals("APPROVED",jdbc.queryForObject("SELECT status FROM business_applications WHERE id=?",String.class,app.id()));
        assertEquals(0,jdbc.queryForObject("SELECT count(*) FROM business_application_events WHERE application_id=? AND action='PAID'",Integer.class,app.id()));
    }
    @Test void prepaymentPostingRequiresNativeClassifiedSupplierRecordAndNeverRepostsMoney(){
        var app=prepayment();var paid=cashPay(app);var keeper=bookkeeper();UUID document=UUID.randomUUID(),ledger=UUID.randomUUID();
        jdbc.update("INSERT INTO finance_payments(id,maker_id,bill_no,status,amount_local,bill_date,account_id,supplier_id) VALUES(?,?,'CF-FIXTURE',1,123.45,'2026-11-01',?,?)",document,viceExecutive,UUID.randomUUID(),app.supplier());
        var link=Map.<String,Object>of("financeDocumentType","PAYMENT","financeDocumentId",document.toString());long viewed=((Number)paid.get("version")).longValue();
        assertThrows(ApiException.class,()->call(keeper,()->service.act(app.id(),"link-finance",new Action(viewed,null,link))));
        jdbc.update("INSERT INTO ar_ap_ledger(id,source_doc_id,source_doc_type,direction,open_item_kind,status,supplier_id,amount_original_local,amount_received_local) VALUES(?,?,'DIRECT_PAYMENT','AP','LEGACY_UNVERIFIED',1,?,0,123.45)",ledger,document,app.supplier());
        assertEquals(false,call(keeper,()->service.detail(app.id())).get("canLinkFinance"));
        jdbc.update("UPDATE ar_ap_ledger SET open_item_kind='PREPAYMENT' WHERE id=?",ledger);jdbc.update("INSERT INTO finance_payment_lines(payment_id) VALUES(?)",document);
        assertEquals(false,call(keeper,()->service.detail(app.id())).get("canLinkFinance"));
        jdbc.update("DELETE FROM finance_payment_lines WHERE payment_id=?",document);jdbc.update("UPDATE finance_payments SET legacy_import_run_id=? WHERE id=?",UUID.randomUUID(),document);
        assertEquals(false,call(keeper,()->service.detail(app.id())).get("canLinkFinance"));
        jdbc.update("UPDATE finance_payments SET legacy_import_run_id=NULL WHERE id=?",document);
        assertEquals(true,call(keeper,()->service.detail(app.id())).get("canLinkFinance"));
        principal.set(keeper);try{assertEquals(1L,service.counts().get("prepaymentPostingTodoCount"));assertEquals(0L,service.counts().get("prepaymentPostingInProgressCount"));assertEquals(document,service.prepaymentFinanceCandidates(app.id(),1,24,null).getItems().getFirst().get("id"));}finally{principal.remove();}
        var linked=call(keeper,()->service.act(app.id(),"link-finance",new Action(viewed,null,link)));
        assertEquals("POSTED",linked.get("postingStatus"));assertEquals("PAID",linked.get("status"));assertEquals(document,linked.get("financeDocumentId"));
        assertEquals("2026-11-01",((Map<?,?>)linked.get("fields")).get("paymentDate"));assertEquals("PREPAY-CASH-001",((Map<?,?>)linked.get("fields")).get("paymentReference"));
        assertEquals(1,jdbc.queryForObject("SELECT count(*) FROM finance_payments",Integer.class));assertEquals(0,jdbc.queryForObject("SELECT count(*) FROM finance_expenses",Integer.class));
        assertThrows(ApiException.class,()->call(keeper,()->service.act(app.id(),"link-finance",new Action(viewed,null,link))));
        assertThrows(org.springframework.dao.DataIntegrityViolationException.class,()->jdbc.update("UPDATE finance_payments SET status=0 WHERE id=?",document));
        assertEquals("POSTED",call(keeper,()->service.detail(app.id())).get("postingStatus"));
    }
    @Test void prepaymentCandidatesAndReadDoNotBorrowAnotherFinancialOwnersVisibility(){
        var app=prepayment();cashPay(app);var keeper=bookkeeper();
        UUID document=UUID.randomUUID();jdbc.update("INSERT INTO finance_payments(id,maker_id,bill_no,status,amount_local,bill_date,account_id,supplier_id) VALUES(?,?,'CF-PRIVATE',1,123.45,'2026-11-01',?,?)",document,executive,UUID.randomUUID(),app.supplier());
        jdbc.update("INSERT INTO ar_ap_ledger(id,source_doc_id,source_doc_type,direction,open_item_kind,status,supplier_id,amount_original_local,amount_received_local) VALUES(?,?,'DIRECT_PAYMENT','AP','PREPAYMENT',1,?,0,123.45)",UUID.randomUUID(),document,app.supplier());
        when(financeAccess.nativeReadScope(anyString(),anyString())).thenReturn(new com.uten.imp.security.DocumentAccessPolicy.NativeReadScope("1=0",null,Set.of()));
        // No financial source visibility does not erase the separately granted
        // workflow read or uploaded proof owner access while waiting for books.
        assertEquals("PENDING",call(keeper,()->service.detail(app.id())).get("postingStatus"));
        principal.set(keeper);try{assertEquals(0,service.prepaymentFinanceCandidates(app.id(),1,24,null).getTotal());new BusinessApplicationAttachmentPolicy(service).applicationPaymentEvidence().requireCanView(app.id(),keeper);}finally{principal.remove();}
    }
    @Test void cancelledDraftRetainsItsNumberAndRejectedHistoryCanAlsoBeClosed(){
        var owner=actor(applicant,"application:apply:travel");var in=input("TRAVEL");var draft=call(owner,()->service.create(in));
        var cancelled=call(owner,()->service.act(in.id(),"cancel",version(draft)));
        assertEquals("CANCELLED",cancelled.get("status"));assertEquals(draft.get("applicationNo"),cancelled.get("applicationNo"));
        assertEquals(1,jdbc.queryForObject("SELECT count(*) FROM business_applications WHERE id=?",Integer.class,in.id()));
        principal.set(owner);try{assertEquals(0L,service.counts().get("mineDraftCount"));assertEquals(1,service.list("mine",null,"FINISHED",null,null,1,24).getTotal());}finally{principal.remove();}
        var secondInput=input("TRAVEL");var second=call(owner,()->service.create(secondInput));assertNotEquals(draft.get("applicationNo"),second.get("applicationNo"));
        var submitted=call(owner,()->service.act(secondInput.id(),"submit",version(second)));
        var rejected=call(actor(reviewer,"application:approve:department"),()->service.act(secondInput.id(),"reject",new Action(((Number)submitted.get("version")).longValue(),"无需继续申请",null)));
        var closed=call(owner,()->service.act(secondInput.id(),"cancel",version(rejected)));assertEquals("CANCELLED",closed.get("status"));
        assertTrue(((List<?>)closed.get("events")).size()>=4);assertEquals(1,jdbc.queryForObject("SELECT count(*) FROM business_application_submissions WHERE application_id=?",Integer.class,secondInput.id()));
    }
    @Test void cancelledIsOwnerAndViewedVersionProtectedAndSubmittedApplicationsMustWithdrawFirst(){
        var owner=actor(applicant,"application:apply:travel");var in=input("TRAVEL");var draft=call(owner,()->service.create(in));
        assertThrows(ApiException.class,()->call(actor(reviewer,"application:apply:travel"),()->service.act(in.id(),"cancel",version(draft))));
        var submitted=call(owner,()->service.act(in.id(),"submit",version(draft)));
        assertThrows(ApiException.class,()->call(owner,()->service.act(in.id(),"cancel",version(submitted))));
        var withdrawn=call(owner,()->service.act(in.id(),"withdraw",version(submitted)));
        assertThrows(ApiException.class,()->call(owner,()->service.act(in.id(),"cancel",version(draft))));
        var closed=call(owner,()->service.act(in.id(),"cancel",version(withdrawn)));assertEquals("CANCELLED",closed.get("status"));
    }
}
