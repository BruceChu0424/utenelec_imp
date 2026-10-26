package com.uten.imp.features.reporting.export;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.export.*;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.production.report.ProductionWhereUsedQueryService;
import com.uten.imp.features.production.report.WhereUsedExportService;
import com.uten.imp.security.*;
import jakarta.persistence.EntityManager;
import org.hibernate.SessionFactory;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.api.io.TempDir;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.orm.jpa.SharedEntityManagerCreator;
import org.springframework.orm.jpa.vendor.HibernateJpaDialect;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.io.*;
import java.math.BigDecimal;
import java.nio.file.*;
import java.time.LocalDate;
import java.util.*;
import java.util.concurrent.atomic.*;
import java.util.stream.IntStream;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Actual migrated queue + actual where-used SQL + same Spring JPA/JDBC RR worker snapshot. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class WhereUsedExportWorkerPostgresTest {
    static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine").withDatabaseName("b1_where_used_worker")
            .withReuse(false).withCreateContainerCmdModifier(cmd->cmd.getHostConfig().withMemory(768L*1024*1024).withNanoCPUs(1_000_000_000L));
    static DriverManagerDataSource dataSource,outsideSource;
    static JdbcTemplate db,outside;
    static ReportExportRepository repository,outsideRepository;
    static SessionFactory factory;
    static JpaTransactionManager transactions;
    static TransactionTemplate tx;
    static UUID owner,employee;
    static Facts baseFacts;
    static final LocalDate DATE=LocalDate.of(2026,10,12);
    static final Set<String> PERMISSIONS=Set.of("production_where_used:view","production_where_used:export");
    static final List<String> sql=Collections.synchronizedList(new ArrayList<>());
    @TempDir Path directory;

    @BeforeAll static void start() {
        PG.start();
        com.uten.imp.testsupport.TestFlyway.configure().dataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword())
                .locations("classpath:db/migration").load().migrate();
        dataSource=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        outsideSource=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        db=new JdbcTemplate(dataSource);outside=new JdbcTemplate(outsideSource);
        repository=new ReportExportRepository(new NamedParameterJdbcTemplate(dataSource));
        outsideRepository=new ReportExportRepository(new NamedParameterJdbcTemplate(outsideSource));
        var configuration=new org.hibernate.cfg.Configuration().setProperty("hibernate.hbm2ddl.auto","none")
                .setProperty("hibernate.show_sql","false")
                .setProperty("hibernate.connection.handling_mode","DELAYED_ACQUISITION_AND_HOLD");
        configuration.getProperties().put("hibernate.connection.datasource",dataSource);
        configuration.setStatementInspector(statement->{sql.add(statement);return statement;});
        factory=configuration.buildSessionFactory();
        transactions=new JpaTransactionManager(factory);transactions.setDataSource(dataSource);transactions.setJpaDialect(new HibernateJpaDialect());
        tx=new TransactionTemplate(transactions);
        owner=UUID.randomUUID();employee=db.queryForObject("SELECT id FROM employees WHERE code='ADMIN'",UUID.class);
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password) VALUES(?,?,'b1_where_used_fixture','test-only-fixture',false)",owner,employee);
        baseFacts=facts();
    }
    @AfterAll static void stop(){if(factory!=null)factory.close();PG.stop();}
    @AfterEach void retireFixtureJobs(){SecurityContextHolder.clearContext();db.update("UPDATE report_export_jobs SET status='FAILED',finished_at=clock_timestamp(),lease_until=NULL WHERE status IN ('PENDING','RUNNING')");}

    private record Facts(UUID material,List<String> names){}
    private static Facts facts() {
        String key=UUID.randomUUID().toString().substring(0,8).toUpperCase(Locale.ROOT);UUID unit=UUID.randomUUID(),material=UUID.randomUUID();
        db.update("INSERT INTO units(id,code,name,status) VALUES(?,?,?,'使用')",unit,"WU-"+key,"测试件"+key);
        db.update("INSERT INTO goods(id,code,name,unit_id,issue_method,status,auto_created,code_sequence) VALUES(?,?,?,?,'ORDER','使用',false,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))",material,"WU-M-"+key,"当前组件"+key,unit);
        db.update("""
            INSERT INTO goods(id,code,name,unit_id,issue_method,status,auto_created,code_sequence)
            SELECT md5(?||n)::uuid,?||lpad(n::text,4,'0'),?||lpad(n::text,4,'0'),?,'ORDER','使用',false,
                   (SELECT COALESCE(MAX(code_sequence),0) FROM goods)+n
              FROM generate_series(1,1001)n
            """,key,"WU-P-"+key+"-","产品-"+key+"-",unit);
        db.update("INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty,summary) SELECT gen_random_uuid(),id,?,2.50003,'原始组装依据' FROM goods WHERE code LIKE ?",material,"WU-P-"+key+"-%");
        UUID product=db.queryForObject("SELECT id FROM goods WHERE code=?",UUID.class,"WU-P-"+key+"-0001");
        UUID plan=UUID.randomUUID(),item=UUID.randomUUID(),warehouse=UUID.randomUUID(),planning=UUID.randomUUID(),segment=UUID.randomUUID();
        db.update("INSERT INTO warehouses(id,code,name,status) VALUES(?,?,?,'使用')",warehouse,"WU-W-"+key,"测试仓"+key);
        EntityManager numbering=SharedEntityManagerCreator.createSharedEntityManager(factory);
        String[] identifiers=tx.execute(status->{
            String billNo=new com.uten.imp.common.docnumber.DocNumberService(numbering)
                    .nextNumber(com.uten.imp.common.docnumber.DocNumberPrefix.PRODUCTION_PLAN);
            db.update("INSERT INTO production_plans(id,bill_no,bill_date,status) VALUES(?,?,?,1)",plan,billNo,DATE);
            String productNo=new com.uten.imp.features.production.plan.ProductionProductNoAllocator(db).allocate(plan,Set.of());
            db.update("INSERT INTO production_plan_items(id,plan_id,bill_no,bill_date,product_no,goods_id,unit_id,unit_rate,qty) VALUES(?,?,?,?,?,?,?,1,10)",item,plan,billNo,DATE,productNo,product,unit);
            String segmentCode=new com.uten.imp.common.mastercode.MasterCodeService(numbering)
                    .nextCode(com.uten.imp.common.mastercode.MasterCodePrefix.PRODUCTION_EXECUTION_SEGMENT);
            return new String[]{billNo,segmentCode};
        });
        // Only the isolated fixture's legacy snapshot enters the existing import contract.
        // SET LOCAL remains on this physical transaction; guards/triggers stay enabled.
        tx.executeWithoutResult(status->{
            db.queryForObject("SELECT set_config('app.legacy_import','on',true)",String.class);
            db.update("""
                INSERT INTO production_plan_costs(id,legacy_id,bill_item_id,bill_no,bill_date,goods_id,master_goods_id,node_class,qty,dqty,pdraw_qty,owdraw_qty)
                VALUES(gen_random_uuid(),(SELECT COALESCE(MAX(legacy_id),1500000000)+1 FROM production_plan_costs),?,?,?,?,?,0,3.1257,0.3125,1.0001,0.0001)
                """,item,identifiers[0],DATE,material,product);
        });
        assertNotEquals("on",db.queryForObject("SELECT current_setting('app.legacy_import',true)",String.class));
        // The live planner commits its package, complete quantity partition and demands atomically.
        tx.executeWithoutResult(status->{
        db.update("INSERT INTO production_planning_packages(id,plan_id,warehouse_id,idempotency_key,request_hash,preview_fingerprint,execution_model_version) VALUES(?,?,?,?,?,?,1)",planning,plan,warehouse,"where-used-"+key,"a".repeat(64),"b".repeat(64));
        db.update("""
            INSERT INTO production_execution_segments(id,package_id,plan_id,source_plan_item_id,segment_no,segment_code,client_segment_key,
                product_goods_id,product_unit_id,product_unit_rate,planned_qty,status,bom_fingerprint,idempotency_key,plan_begin_date)
            VALUES(?,?,?,?,1,?,?,?, ?,1,10,'READY',?,?,?)
            """,segment,planning,plan,item,identifiers[1],"WU-CLIENT-"+key,product,unit,"c".repeat(64),"where-used-segment-"+key,DATE);
        db.update("""
            INSERT INTO production_material_demands(package_id,plan_id,warehouse_id,goods_id,unit_id,required_qty,supply_route,idempotency_key,
                execution_segment_id,source_plan_item_id,per_product_qty,need_date)
            VALUES(?,?,?,?,?,5.0003,'SUBCONTRACT',?,?,?,?,?)
            """,planning,plan,warehouse,material,unit,"where-used-demand-"+key,segment,item,new BigDecimal("0.500030"),DATE);
        });
        return new Facts(material,IntStream.rangeClosed(1,1001).mapToObj(index->"产品-"+key+"-"+String.format("%04d",index)).toList());
    }

    private final class Harness implements AutoCloseable {
        final AtomicReference<AuthUser> principal=new AtomicReference<>(user(PERMISSIONS));
        final SecurityContextCurrentUser users=new SecurityContextCurrentUser();
        final SubmitterPrincipalRestorer restorer=mock(SubmitterPrincipalRestorer.class);
        final ReportExportService service;
        final ReportExportSource source;
        final AtomicReference<Runnable> sourceBoundary=new AtomicReference<>(()->{});
        final AtomicBoolean boundaryCalled=new AtomicBoolean();
        Harness()throws Exception {
            when(restorer.restore(eq(owner),anyLong(),any())).thenAnswer(call->principal.get());
            when(restorer.currentStamps(owner)).thenReturn(Optional.of(new SubmitterPrincipalRestorer.AuthorizationStamps(1,1)));
            var identity=mock(ReportExportBuildIdentity.class);when(identity.revision()).thenReturn("where-used-fixture-build");
            var scopes=mock(ReadScopeVersionAuthority.class);when(scopes.scopeFor(anyString(),any())).thenReturn("a".repeat(64));
            @SuppressWarnings("unchecked") org.springframework.beans.factory.ObjectProvider<ExportProjectionAccessGuard> projection=mock(org.springframework.beans.factory.ObjectProvider.class);
            service=new ReportExportService(repository,users,restorer,new ObjectMapper(),identity,mock(ExportRateLimiter.class),scopes,projection,directory.toString());
            EntityManager em=SharedEntityManagerCreator.createSharedEntityManager(factory);
            var employeeNames=mock(EmployeeNameResolver.class);when(employeeNames.nameWithCodeOf(employee)).thenReturn("服务器操作员(E001)");
            var whereUsed=spy(new WhereUsedExportService(new ProductionWhereUsedQueryService(em),users,em,employeeNames));
            doAnswer(call->{if(boundaryCalled.compareAndSet(false,true))sourceBoundary.get().run();return call.callRealMethod();})
                    .when(whereUsed).streamDocument(any(),anyString(),any(),any(),any(),any());
            var constructor=Arrays.stream(ReportExportSource.class.getConstructors()).max(Comparator.comparingInt(java.lang.reflect.Constructor::getParameterCount)).orElseThrow();
            Object[] arguments=Arrays.stream(constructor.getParameterTypes()).map(type->type==WhereUsedExportService.class?whereUsed:mock(type)).toArray();
            source=(ReportExportSource)constructor.newInstance(arguments);login(principal.get());
        }
        ReportExportRepository.Job submit(Facts facts,String format) {
            var request=new ReportExportRequest(UUID.randomUUID(),"where_used","where-used",Map.of("materialGoodsId",facts.material().toString(),"source","all"),"goodsCode","asc",null,format);
            var view=tx.execute(status->service.submit(request));return repository.find(view.id()).orElseThrow();
        }
        void run(ReportExportRepository.Job job,XlsxExportService excel,TabularPdfExportService pdf) {
            var claimed=tx.execute(status->repository.claim().orElseThrow());assertEquals(job.id(),claimed.id());
            var worker=new ReportExportWorker(repository,service,source,restorer,excel,pdf,db,transactions);
            try{ReflectionTestUtils.invokeMethod(worker,"runWithSlot",claimed);}finally{worker.close();}
        }
        @Override public void close(){SecurityContextHolder.clearContext();}
    }
    private static AuthUser user(Set<String> permissions){return new AuthUser(owner,employee,"where-used-fixture",permissions,false,true,false);}
    private static void login(AuthUser user){SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,null,user.getAuthorities()));}

    @ParameterizedTest @ValueSource(strings={"xlsx","pdf"})
    void independentWhereUsedPermissionsProduceAllRowsAndUnmixedEvidenceThroughRealWorker(String format)throws Exception {
        Facts facts=baseFacts;try(var harness=new Harness()) {
            assertFalse(harness.principal.get().getPermissions().contains("production_report:view"));
            assertFalse(harness.principal.get().getPermissions().contains("production_report:export"));
            assertFalse(harness.principal.get().getPermissions().contains("goods:view"));
            var job=harness.submit(facts,format);sql.clear();harness.run(job,new XlsxExportService(),new TabularPdfExportService());
            var complete=repository.find(job.id()).orElseThrow();assertEquals("SUCCEEDED",complete.status(),complete.error());
            assertEquals(1001,complete.rows(),"Evidence section copies must not inflate primary progress");assertNotNull(complete.snapshotAt());
            assertEquals(1,sql.stream().filter(statement->statement.contains("FROM combined row")&&statement.contains("WITH RECURSIVE")).count());
            Path artifact=harness.service.artifact(complete);assertTrue(Files.size(artifact)>100);
            if(format.equals("xlsx"))try(var input=Files.newInputStream(artifact);var book=new org.apache.poi.xssf.usermodel.XSSFWorkbook(input)) {
                assertEquals(List.of("说明","组件使用产品","当前组装依据","新生产需求依据","旧生产快照依据","委外需求与历史依据"),
                        IntStream.range(0,book.getNumberOfSheets()).mapToObj(book::getSheetName).toList());
                assertEquals(1001,book.getSheetAt(1).getLastRowNum());assertEquals(1001,book.getSheetAt(2).getLastRowNum());
                assertEquals(1,book.getSheetAt(3).getLastRowNum());assertEquals(1,book.getSheetAt(4).getLastRowNum());assertEquals(1,book.getSheetAt(5).getLastRowNum());
                assertEquals(facts.names(),IntStream.rangeClosed(1,1001).mapToObj(index->book.getSheetAt(1).getRow(index).getCell(0).getStringCellValue()).toList());
                assertEquals(5.0003,book.getSheetAt(3).getRow(1).getCell(5).getNumericCellValue());
                assertEquals(3.1257,book.getSheetAt(4).getRow(1).getCell(5).getNumericCellValue());
                assertFalse(book.getSheetAt(4).getRow(1).getCell(5).getCellStyle().getDataFormatString().contains("测试件"));
            }
            else try(var pdf=org.apache.pdfbox.Loader.loadPDF(artifact.toFile())) {
                var text=new org.apache.pdfbox.text.PDFTextStripper().getText(pdf);assertTrue(text.contains("服务器操作员(E001)"));
                for(String name:facts.names())assertTrue(text.contains(name),"Missing worker PDF identity "+name);
                assertTrue(text.contains("3.1257"));assertTrue(text.contains("5.0003"));assertTrue(text.contains("历史用量保留原证据口径"));
            }
            login(harness.principal.get());
            var controller=new ReportExportController(harness.service,new WorkbookDownloadService(),new TabularPdfExportService(),mock(com.uten.imp.audit.AuditService.class),harness.users);
            var response=new org.springframework.mock.web.MockHttpServletResponse();controller.download(job.id(),new ExportPasswordRequest("1"),response);
            assertTrue(response.getContentAsByteArray().length>100);
            harness.principal.set(user(Set.of("production_where_used:export")));login(harness.principal.get());
            var denied=new org.springframework.mock.web.MockHttpServletResponse();
            assertThrows(com.uten.imp.common.web.ApiException.class,()->controller.download(job.id(),new ExportPasswordRequest(null),denied));assertEquals(0,denied.getContentAsByteArray().length);
            assertNoTemporaryArtifacts(artifact);
        }
    }

    @Test void missingIndependentViewOrExportCannotCreateADurableTask()throws Exception {
        Facts facts=new Facts(UUID.randomUUID(),List.of());try(var harness=new Harness()) {
            long before=db.queryForObject("SELECT count(*) FROM report_export_jobs",Long.class);
            for(var permissions:List.of(Set.of("production_where_used:view"),Set.of("production_where_used:export"),Set.of("production_report:view","production_report:export"))) {
                harness.principal.set(user(permissions));login(harness.principal.get());
                assertThrows(com.uten.imp.common.web.ApiException.class,()->harness.submit(facts,"xlsx"));
            }
            assertEquals(before,db.queryForObject("SELECT count(*) FROM report_export_jobs",Long.class));
        }
    }

    @Test void commitBetweenWorkerSnapshotAndFirstSourceSqlOnlyAppearsInANewTask()throws Exception {
        Facts facts=facts();try(var harness=new Harness()) {
            String lateName="晚提交产品-"+UUID.randomUUID().toString().substring(0,8);
            var inserted=new AtomicBoolean();
            harness.sourceBoundary.set(()->{
                UUID unit=outside.queryForObject("SELECT unit_id FROM goods WHERE id=?",UUID.class,facts.material());
                UUID product=UUID.randomUUID();
                outside.update("INSERT INTO goods(id,code,name,unit_id,issue_method,status,auto_created,code_sequence) VALUES(?,?,?,?,'ORDER','使用',false,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))",
                        product,"WU-LATE-"+product,lateName,unit);
                outside.update("INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty,summary) VALUES(gen_random_uuid(),?,?,2.50003,'晚提交原始组装依据')",product,facts.material());
                inserted.set(true);
            });
            var first=harness.submit(facts,"xlsx");harness.run(first,new XlsxExportService(),new TabularPdfExportService());
            assertTrue(inserted.get());var old=repository.find(first.id()).orElseThrow();assertEquals("SUCCEEDED",old.status(),old.error());assertEquals(1001,old.rows());
            try(var input=Files.newInputStream(harness.service.artifact(old));var book=new org.apache.poi.xssf.usermodel.XSSFWorkbook(input)) {
                assertEquals(facts.names(),IntStream.rangeClosed(1,1001).mapToObj(index->book.getSheetAt(1).getRow(index).getCell(0).getStringCellValue()).toList());
            }
            login(harness.principal.get());
            var second=harness.submit(facts,"xlsx");harness.run(second,new XlsxExportService(),new TabularPdfExportService());
            var current=repository.find(second.id()).orElseThrow();assertEquals("SUCCEEDED",current.status(),current.error());assertEquals(1002,current.rows());
            try(var input=Files.newInputStream(harness.service.artifact(current));var book=new org.apache.poi.xssf.usermodel.XSSFWorkbook(input)) {
                assertTrue(IntStream.rangeClosed(1,1002).mapToObj(index->book.getSheetAt(1).getRow(index).getCell(0).getStringCellValue()).anyMatch(lateName::equals));
            }
            try(var files=Files.list(directory)){assertEquals(Set.of(harness.service.artifact(old),harness.service.artifact(current)),new HashSet<>(files.toList()));}
        }
    }

    @ParameterizedTest @ValueSource(booleans={false,true})
    void sourceCancellationOrSinkFailureNeverPublishesEvenAfterItsFirstMainPage(boolean fail)throws Exception {
        Facts facts=baseFacts;try(var harness=new Harness()) {
            var job=harness.submit(facts,"xlsx");var once=new AtomicBoolean();
            XlsxExportService excel=new XlsxExportService(){@Override public StreamingDocumentWriter openDocumentStream(Path path){
                var delegate=super.openDocumentStream(path);return new Forward(delegate){@Override public void accept(DocumentPageSink.Page page){
                    super.accept(page);if(page.sectionId().equals("section-0")&&once.compareAndSet(false,true)) {
                        if(fail)throw new IllegalStateException("injected sink failure");outsideRepository.cancel(job.id(),owner);
                    }
                }};
            }};
            harness.run(job,excel,new TabularPdfExportService());assertTrue(once.get());
            var result=repository.find(job.id()).orElseThrow();assertEquals(fail?"FAILED":"CANCELLED",result.status());
            assertFalse(Files.exists(harness.service.artifact(result)));assertNoTemporaryArtifacts(null);
        }
    }
    @Test void pdfFormattingCancellationAfterSourceCompletionStillCannotPublish()throws Exception {
        Facts facts=baseFacts;try(var harness=new Harness()) {
            var job=harness.submit(facts,"pdf");var cancelled=new AtomicBoolean();
            var observedRows=new AtomicLong();
            TabularPdfExportService pdf=new TabularPdfExportService(){@Override public StreamingDocumentWriter openDocumentStream(Path path){
                var delegate=super.openDocumentStream(path);return new Forward(delegate){
                    Runnable taskCheckpoint;
                    @Override public void onCheckpoint(Runnable checkpoint){taskCheckpoint=checkpoint;delegate.onCheckpoint(checkpoint);}
                    @Override public void finish(OutputStream output)throws IOException {
                        observedRows.set(delegate.primaryRowCount());
                        delegate.onCheckpoint(()->{
                            if(cancelled.compareAndSet(false,true))outsideRepository.cancel(job.id(),owner);
                            taskCheckpoint.run();
                        });
                        delegate.finish(output);
                    }
                };
            }};
            harness.run(job,new XlsxExportService(),pdf);
            assertTrue(cancelled.get());assertEquals(1001,observedRows.get());
            var result=repository.find(job.id()).orElseThrow();assertEquals("CANCELLED",result.status());
            assertFalse(Files.exists(harness.service.artifact(result)));assertNoTemporaryArtifacts(null);
        }
    }
    private static class Forward implements StreamingDocumentWriter {
        final StreamingDocumentWriter delegate;Forward(StreamingDocumentWriter delegate){this.delegate=delegate;}
        public void onCheckpoint(Runnable checkpoint){delegate.onCheckpoint(checkpoint);}public void begin(DocumentPageSink.Header header){delegate.begin(header);}
        public void accept(DocumentPageSink.Page page){delegate.accept(page);}public long primaryRowCount(){return delegate.primaryRowCount();}public long rowCount(){return delegate.rowCount();}
        public void finish(OutputStream output)throws IOException{delegate.finish(output);}public void close()throws IOException{delegate.close();}
    }
    private void assertNoTemporaryArtifacts(Path artifact)throws IOException {
        try(var files=Files.list(directory)){assertEquals(artifact==null?List.of():List.of(artifact),files.toList());}
    }
    private record FacetCase(String service,String method,String path,Object[] arguments) { }
    @Test void everyNativeCandidateRouteUsesItsRealBusinessSqlExactlyOnceOnTheMigratedSchema() throws Exception {
        Object allWarehouses=com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope.ALL;
        Object active=Enum.valueOf((Class)Class.forName("com.uten.imp.features.warehouse.taskcenter.WarehouseTaskCenterContracts$TaskView"),"ACTIVE");
        List<FacetCase> cases=new ArrayList<>(List.of(
            new FacetCase("finance.report.FinanceReportService","accountStatementFacets","/api/finance/reports/account/statement/facets",new Object[]{UUID.randomUUID(),null,null,null}),
            new FacetCase("finance.payables.ProcurementPayablesService","facets","/api/finance/payables/facets",new Object[]{null,null,null,null,null,null,null,null,null,null}),
            new FacetCase("finance.payables.SubcontractLossClaimService","facets","/api/finance/subcontract-loss-claims/facets",new Object[]{null,null,null}),
            new FacetCase("warehouse.inbound.WarehouseQualityResultService","facets","/api/warehouse/quality-results/facets",new Object[]{null,null,null,null,null,allWarehouses,active}),
            new FacetCase("warehouse.inbound.ProcurementInspectionRecordQueryService","facets","/api/procurement/inspection/records/facets",new Object[]{null,null,null,null,null,null,null}),
            new FacetCase("subcontract.short_delivery.SubcontractShortDeliveryService","facets","/api/subcontract/short-deliveries/facets",new Object[]{"PENDING",null,null,null,null,null}),
            new FacetCase("warehouse.finishedin.ProductionFinishedInboundTaskService","facets","/api/warehouse/production-finished-in/tasks/facets",new Object[]{null,null,null,allWarehouses}),
            new FacetCase("production.schedule.ProductionScheduleService","pendingFacets","/api/production/schedule/pending/facets",new Object[]{null,null,null}),
            new FacetCase("production.quality.ProductionFqcRecordQueryService","facets","/api/production/quality-inspections/records/facets",new Object[]{null,null,null,null,null,null,null}),
            new FacetCase("sales.order.SalesOrderService","progressFacets","/api/sales/orders/progress/facets",new Object[]{"IN_PROGRESS",null,null,null}),
            new FacetCase("sales.order.SalesOrderFinanceConfirmService","pendingFacets","/api/sales/orders/finance-confirmation/pending/facets",new Object[]{null,null,null,false}),
            new FacetCase("production.analysis.MaterialAnalysisService","salesCandidatesFacets","/api/production/material-analyses/sales-candidates/facets",new Object[]{null}),
            new FacetCase("production.execution.ProductionExecutionWorkbenchService","rootFacets","/api/production/execution-workbench/facets",new Object[]{null,null,false}),
            new FacetCase("production.execution.ProductionExecutionWorkbenchService","workshopTaskFacets","/api/production/workshop-tasks/facets",new Object[]{null,"IN_PROGRESS",null,null,null,null,null}),
            new FacetCase("production.execution.ProductionOverproductionRateService","facets","/api/production/overproduction-rate/requests/facets",new Object[]{"ALL"})
        ));
        Class<?> history=Class.forName("com.uten.imp.features.warehouse.history.WarehouseHistoryType");
        for(Object type:history.getEnumConstants()) {
            // The enum's fixed endpoint path is package-private; its name maps to the existing compile-time route.
            String path=switch(((Enum<?>)type).name()) {
                case "PURCHASE_RECEIPT"->"purchase-receipts";case "SUBCONTRACT_RECEIPT"->"subcontract-receipts";
                case "SUBCONTRACT_MATERIAL_ISSUE"->"subcontract-material-issues";case "SUBCONTRACT_RETURN"->"subcontract-returns";
                case "SUBCONTRACT_MATERIAL_RETURN"->"subcontract-material-returns";default->"subcontract-wastes";
            };
            cases.add(new FacetCase("warehouse.history.WarehouseHistoryQueryService","facets","/api/warehouse/document-history/"+path+"/facets",new Object[]{type,null,null,null,null,null}));
        }
        assertEquals(21,cases.size());
        EntityManager em=SharedEntityManagerCreator.createSharedEntityManager(factory);
        var read=new TransactionTemplate(transactions);read.setReadOnly(true);read.setIsolationLevel(org.springframework.transaction.TransactionDefinition.ISOLATION_REPEATABLE_READ);
        int checked=read.execute(status->{
            int fields=0;
            for(FacetCase test:cases)try {
                Class<?> type=Class.forName("com.uten.imp.features."+test.service());Object service=facetService(type,em);
                var method=Arrays.stream(type.getMethods()).filter(candidate->candidate.getName().equals(test.method())&&candidate.getParameterCount()==test.arguments().length).findFirst().orElseThrow();method.setAccessible(true);
                for(String field:com.uten.imp.common.report.NativeFacetRoutes.find(test.path()).fields()) {
                    sql.clear();
                    try(var candidates=com.uten.imp.common.web.NativeFacetCandidates.open(field,"",1,100)) {
                        Object response=method.invoke(service,test.arguments());var result=candidates.result(response,"isolated-sql-contract");
                        assertEquals(field,result.field());assertTrue(result.items().size()<=100);
                        assertEquals(1,sql.size(),test.path()+"#"+field+" must execute only its own original grouped query");
                        assertTrue(sql.getFirst().contains("candidate.bucket_count"),test.path()+"#"+field);
                    }
                    fields++;
                }
            } catch(Exception failure){throw new AssertionError(test.path(),failure);}
            return fields;
        });
        assertEquals(33,checked);
    }
    private static Object facetService(Class<?> type,EntityManager em) throws Exception {
        var constructor=Arrays.stream(type.getConstructors()).max(Comparator.comparingInt(java.lang.reflect.Constructor::getParameterCount)).orElseThrow();
        Object[] args=new Object[constructor.getParameterCount()];
        for(int i=0;i<args.length;i++) {
            Class<?> dependency=constructor.getParameterTypes()[i];
            if(dependency==EntityManager.class)args[i]=em;
            else if(dependency==JdbcTemplate.class)args[i]=db;
            else if(dependency==ObjectMapper.class)args[i]=new ObjectMapper();
            else args[i]=mock(dependency,call->{
                Class<?> result=call.getMethod().getReturnType();String name=call.getMethod().getName();
                if(result==com.uten.imp.security.DocumentAccessPolicy.NativeReadScope.class)return new com.uten.imp.security.DocumentAccessPolicy.NativeReadScope("1=1",null,Set.of());
                if(result==com.uten.imp.security.OwnerVisibility.OwnerScope.class)return new com.uten.imp.security.OwnerVisibility.OwnerScope(true,Set.of());
                if(result==com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope.class)return com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope.ALL;
                if(result==Optional.class)return switch(name) {
                    case "get"->Optional.of(new AuthUser(owner,employee,"native-reader",Set.of(),false,true,true));
                    case "employeeId"->Optional.of(employee);case "id"->Optional.of(owner);default->Optional.empty();};
                if(result==boolean.class||result==Boolean.class)return true;
                return org.mockito.Answers.RETURNS_DEFAULTS.answer(call);
            });
        }
        return constructor.newInstance(args);
    }

    @Test void isolatedLegacyFixtureDoesNotDisableOrLeakThePermanentReadOnlyGuard() {
        var before=db.queryForObject("SELECT qty FROM production_plan_costs WHERE goods_id=?",BigDecimal.class,baseFacts.material());
        var denied=assertThrows(org.springframework.dao.DataAccessException.class,()->db.update("UPDATE production_plan_costs SET qty=qty WHERE goods_id=?",baseFacts.material()));
        assertInstanceOf(java.sql.SQLException.class,denied.getMostSpecificCause());
        assertEquals("42501",((java.sql.SQLException)denied.getMostSpecificCause()).getSQLState());
        assertEquals(before,db.queryForObject("SELECT qty FROM production_plan_costs WHERE goods_id=?",BigDecimal.class,baseFacts.material()));
    }

}
