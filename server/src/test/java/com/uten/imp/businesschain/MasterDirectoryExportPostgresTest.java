package com.uten.imp.businesschain;

import com.uten.imp.features.master.export.MasterReportExportSource;

import com.uten.imp.common.export.*;
import com.uten.imp.features.reporting.export.*;
import com.uten.imp.features.master.account.AccountService;
import com.uten.imp.features.master.client.ClientService;
import com.uten.imp.features.master.color.ColorService;
import com.uten.imp.features.master.currency.CurrencyService;
import com.uten.imp.features.master.goods.GoodsService;
import com.uten.imp.features.master.goods.GoodsRepository;
import com.uten.imp.features.master.mould.MouldService;
import com.uten.imp.features.master.supplier.SupplierService;
import com.uten.imp.features.master.unit.UnitService;
import com.uten.imp.features.master.warehouse.WarehouseService;
import com.uten.imp.features.master.referencemethod.ReferenceMethodService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.GoodsReadScopePolicy;
import jakarta.persistence.EntityManager;
import jakarta.validation.Validator;
import org.junit.jupiter.api.*;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.context.ApplicationContext;
import org.springframework.data.domain.Pageable;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.bean.override.mockito.MockitoSpyBean;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.atomic.*;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Real original services/Specifications, full migrations and isolated business fixtures. */
class MasterDirectoryExportPostgresTest extends AuthSessionPostgresTestSupport {
    @Autowired ApplicationContext context;
    @Autowired EntityManager em;
    @Autowired Validator validator;
    @MockitoSpyBean GoodsRepository goodsRepository;
    UUID employee;
    MasterReportExportSource master;
    @BeforeEach void reader(){
        employee=UUID.randomUUID();
        jdbc.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) SELECT ?,?,?,id_type,department_id,CURRENT_DATE,'active','regular' FROM employees WHERE code='ADMIN'",
                employee,"MX-"+employee,com.uten.imp.support.SyntheticEmployeeIdentity.name("Master export reader",employee));
        master=new MasterReportExportSource(context.getBean(GoodsService.class),context.getBean(ClientService.class),
                context.getBean(SupplierService.class),context.getBean(AccountService.class),context.getBean(CurrencyService.class),
                context.getBean(ColorService.class),context.getBean(UnitService.class),context.getBean(MouldService.class),
                context.getBean(WarehouseService.class),context.getBean(ReferenceMethodService.class),objectMapper,validator);
    }
    @AfterEach void logout(){SecurityContextHolder.clearContext();}
    void exporter(String report,String... extra){
        Set<String> permissions=new HashSet<>(List.of(report+":export"));permissions.addAll(List.of(extra));
        var user=new AuthUser(UUID.randomUUID(),employee,"master-export-only",permissions,false,true,false);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user,null,user.getAuthorities()));
    }
    ReportExportRequest request(String report,Map<String,Object> filter)throws Exception{
        return new ReportExportRequest(UUID.randomUUID(),"master",report,Map.of("filter",objectMapper.writeValueAsString(filter)),null,null,null);
    }

    @ParameterizedTest @ValueSource(strings={"goods","client","supplier","account","currency","color","unit","mould","warehouse","settlement_method"})
    void allTenActualCallersPreserveTheirOriginalRowsFiltersMasksAndExportOnlyPermission(String report)throws Exception{
        assertCaller(report);
    }
    @Test void repairedAccountCallerPreservesEveryOriginalAssertion()throws Exception { assertCaller("account"); }
    @Test void expandedSettlementAndWarehouseHeadersExportTheirAuthoritativeValues() throws Exception {
        String token="HDR"+UUID.randomUUID().toString().replace("-","").substring(0,10);
        UUID method=seed("settlement_method",token,1).ids().getFirst();
        jdbc.update("UPDATE settlement_methods SET terms_base='STATEMENT_END',due_rule='FIXED_DAY_OF_MONTH',default_due_days=0,fixed_day_of_month=15,months_ahead=2 WHERE id=?",method);
        exporter("settlement_method");
        var terms=master.read(request("settlement_method",Map.of("keyword",token)));
        assertThat(terms.columns()).extracting(ExportColumn::key)
                .contains("defaultDueDays","fixedDayOfMonth","monthsAhead");
        assertThat(terms.rows().getFirst()).containsEntry("defaultDueDays",0)
                .containsEntry("fixedDayOfMonth",15).containsEntry("monthsAhead",2);
        // Global business identifiers span master domains; keep this second
        // fixture distinct from the settlement-method code already claimed.
        String warehouseToken=token+"W";
        UUID warehouse=seed("warehouse",warehouseToken,1).ids().getFirst();
        jdbc.update("UPDATE warehouses SET remark=? WHERE id=?","完整备注龘",warehouse);
        exporter("warehouse");
        var source=master.read(request("warehouse",Map.of("keyword",warehouseToken)));
        assertThat(source.rows().getFirst()).containsEntry("remark","完整备注龘")
                .containsEntry("workshopDepartmentName",null);
        var projection=new TableColumnProjection("master.warehouses","master_warehouse",
                List.of(new TableColumnProjection.Column("remark",null,120d,"text",null),
                        new TableColumnProjection.Column("workshopDepartmentId",null,120d,"text",null)));
        var result=context.getBean(ExportTableProjectionService.class)
                .project(source.columns(),source.rows(),projection,"master_warehouse");
        assertThat(result.columns()).extracting(ExportColumn::key)
                .containsExactly("remark","workshopDepartmentName");
        UUID workshop=UUID.randomUUID();
        assertThat(jdbc.update("INSERT INTO departments(id,code,name,parent_id,level) SELECT ?,?,? ,id,'二级班组' FROM departments WHERE code='DEPT_PROD' AND NOT is_deleted",
                workshop,"MX-WORKSHOP-"+token,"导出铜柱车间")).isEqualTo(1);
        jdbc.update("UPDATE warehouses SET workshop_department_id=? WHERE id=?",workshop,warehouse);
        var populated=master.read(request("warehouse",Map.of("keyword",warehouseToken)));
        assertThat(populated.rows().getFirst()).containsEntry("workshopDepartmentName","导出铜柱车间");
        var actual=context.getBean(ExportTableProjectionService.class)
                .project(populated.columns(),populated.rows(),projection,"master_warehouse");
        assertThat(actual.rows().getFirst()).containsEntry("workshopDepartmentName","导出铜柱车间");
    }
    @Test void mouldWorkbookKeepsAll1626RowsAndExactSelectedScopeWithoutTheDisplayPlaceholder() throws Exception {
        String token="MOULD"+UUID.randomUUID().toString().replace("-","").substring(0,10);
        Seed seed=seed("mould",token,1626);
        exporter("mould");
        var columns=List.of("status","code","name","qty","tqty","place","manufacturer","mstatus","remark")
                .stream().map(key->new TableColumnProjection.Column(key,null,120d,"text",null)).toList();
        var projection=new TableColumnProjection("master.mould","master_mould",columns);
        var source=context.getBean(XlsxExportService.class);
        for(boolean selected:List.of(false,true)) {
            List<UUID> ids=selected?seed.ids().subList(201,1502):seed.ids();
            var parameters=new LinkedHashMap<String,String>();
            parameters.put("filter",objectMapper.writeValueAsString(Map.of("keyword",token)));
            if(selected)parameters.put("selectedIds",objectMapper.writeValueAsString(ids));
            var request=new ReportExportRequest(UUID.randomUUID(),"master","mould",parameters,null,null,projection);
            var result=source.buildSource(()->master.read(request),projection,"master_mould");
            assertThat(result.payload().total()).isEqualTo(ids.size());
            try(var workbook=org.apache.poi.ss.usermodel.WorkbookFactory.create(new java.io.ByteArrayInputStream(result.bytes()))) {
                var sheet=workbook.getSheetAt(0);
                assertThat(sheet.getLastRowNum()).isEqualTo(ids.size());
                assertThat(sheet.getRow(0).getLastCellNum()).isEqualTo((short)9);
                for(int index=0;index<ids.size();index++) {
                    assertThat(sheet.getRow(index+1).getCell(1).getStringCellValue())
                            .as("Every original mould identity is present once, in original order: row %s",index+1)
                            .isEqualTo("MX-"+token+"-"+String.format("%06d",index+(selected?201:0)));
                }
            }
        }
        // The fix belongs to the client declaration; unknown columns must still
        // fail closed rather than silently widening or weakening projection.
        var invalid=new TableColumnProjection("master.mould","master_mould",
                List.of(new TableColumnProjection.Column("mouldType",null,120d,"text",null)));
        var original=request("mould",Map.of("keyword",token));
        assertThatThrownBy(()->source.buildSource(()->master.read(original),invalid,"master_mould"))
                .isInstanceOf(com.uten.imp.common.web.ApiException.class).hasMessageContaining("mouldType");
    }
    @Test void mouldTaskKeepsReverseQuantityOrderAndExactDecimalText() throws Exception {
        String token="SORT"+UUID.randomUUID().toString().substring(0,8);
        Seed seed=seed("mould",token,1626);
        jdbc.update("UPDATE moulds SET tqty=1626.125-right(code,6)::numeric WHERE category_id=(SELECT category_id FROM moulds WHERE id=?)",seed.ids().getFirst());
        exporter("mould");
        var req=new ReportExportRequest(UUID.randomUUID(),"master","mould",
                Map.of("filter",objectMapper.writeValueAsString(Map.of("keyword",token))),"tqty","asc",null);
        var payload=master.read(req);
        assertThat(payload.rows()).hasSize(1626);
        assertThat(payload.rows().getFirst()).containsEntry("code","MX-"+token+"-001625").containsEntry("tqty","1.125");
        var selected=new ReportExportRequest(UUID.randomUUID(),"master","mould",
                Map.of("filter",req.parameters().get("filter"),"selectedIds",objectMapper.writeValueAsString(seed.ids().subList(1624,1626))),"tqty","asc",null);
        assertThat(master.read(selected).rows()).extracting(row->row.get("tqty")).containsExactly("1.125","2.125");
    }
    @Test void fiftyThousandAndOneRealSelectedMouldsExcludeAnotherMatchingRowAndKeepOrder(
            @org.junit.jupiter.api.io.TempDir java.nio.file.Path directory) throws Exception {
        String token="SEL"+UUID.randomUUID().toString().substring(0,8);
        Seed seed=seed("mould",token,50002);
        exporter("mould");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM moulds WHERE code LIKE ? AND NOT is_deleted",Integer.class,"MX-"+token+"-%")).isEqualTo(50002);
        List<UUID> ids=seed.ids().subList(0,50001);
        var req=new ReportExportRequest(UUID.randomUUID(),"master","mould",
                Map.of("filter",objectMapper.writeValueAsString(Map.of("keyword",token)),"selectedIds",objectMapper.writeValueAsString(ids)),"tqty","desc",null);
        master.validate(req);
        var rows=new AtomicInteger();
        var measurement=ProductionJdbcMeasurement.begin();long started=System.nanoTime();
        try(var sink=ExportPageSink.open(page->{
            for(var row:page.rows()) {
                int original=50000-rows.getAndIncrement();
                assertThat(row.get("code")).isEqualTo("MX-"+token+"-%06d".formatted(original));
                assertThat(row.get("tqty")).isEqualTo(new BigDecimal(original).add(new BigDecimal("0.125")).toPlainString());
            }
        })) {
            assertThat(master.read(req).total()).isEqualTo(50001);
        } finally {
            ProductionJdbcMeasurement.end();
        }
        assertThat(rows).hasValue(50001);
        assertThat(measurement.maxPreparedParameterIndex).isLessThan(100);
        System.out.println("D3_SELECTION_READ sourceMs="+(System.nanoTime()-started)/1000000+" jdbc="+measurement.result());
        assertThat(MasterExportSelection.current()).isNull();
        exporter("unit");
        assertThatThrownBy(()->master.read(req)).isInstanceOfSatisfying(com.uten.imp.common.web.ApiException.class,
                denied->assertThat(denied.getCode()).isEqualTo(com.uten.imp.common.web.ErrorCode.FORBIDDEN));
        assertThat(MasterExportSelection.current()).isNull();exporter("mould");
        try(var sink=ExportPageSink.open(page->{throw new java.util.concurrent.CancellationException("selection interruption");})) {
            assertThatThrownBy(()->master.read(req)).isInstanceOf(java.util.concurrent.CancellationException.class);
        }
        assertThat(MasterExportSelection.current()).isNull();
        var missing=new ArrayList<>(ids);missing.set(0,UUID.randomUUID());
        var stale=new ReportExportRequest(UUID.randomUUID(),"master","mould",
                Map.of("filter",req.parameters().get("filter"),"selectedIds",objectMapper.writeValueAsString(missing)),"tqty","desc",null);
        assertThatThrownBy(()->master.read(stale)).hasMessageContaining("本次未生成文件");
        System.out.println("D3_REAL_SELECTION selected=50001 matching=50002 excluded=1 ordered=50001 cancellation=preserved missing=rejected revokedAuthority=rejected");
        long writeStart=System.nanoTime();
        var workbook=context.getBean(XlsxExportService.class).buildSource(()->master.read(req),null,"master_mould");
        long sourceAndWriteMs=(System.nanoTime()-writeStart)/1_000_000;
        assertThat(workbook.payload().total()).isEqualTo(50001);
        String evidence=System.getProperty("uten.export.evidence.directory");
        java.nio.file.Path archive=evidence==null?directory:java.nio.file.Path.of(evidence);
        java.nio.file.Files.createDirectories(archive);
        java.nio.file.Path file=archive.resolve("selected-50001-"+token+".xlsx");
        java.nio.file.Files.write(file,workbook.bytes(),java.nio.file.StandardOpenOption.CREATE_NEW);
        long rereadStart=System.nanoTime();
        assertSelectedMouldWorkbook(file,token);
        assertThat(MasterExportSelection.current()).isNull();
        System.out.println("D3_SELECTED_XLSX realDatabaseMatches=50002 realSelected=50001 physicalDataRows=50001 excluded=1 exactQuantityRows=50001 sourceAndWriteMs="+sourceAndWriteMs+
                " rereadMs="+(System.nanoTime()-rereadStart)/1_000_000+" bytes="+java.nio.file.Files.size(file)+
                " sha256="+HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(workbook.bytes()))+" file="+file.toAbsolutePath());
    }
    private static void assertSelectedMouldWorkbook(java.nio.file.Path file,String token)throws Exception {
        var rows=new AtomicInteger();
        try(var zip=new java.util.zip.ZipFile(file.toFile())) {
            assertThat(zip.getEntry("xl/worksheets/sheet2.xml")).isNull();
            var factory=javax.xml.parsers.SAXParserFactory.newInstance();
            factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl",true);
            var handler=new org.xml.sax.helpers.DefaultHandler() {
                int row,column;StringBuilder value;boolean code,quantity;
                public void startElement(String uri,String local,String tag,org.xml.sax.Attributes attributes) {
                    if(tag.equals("row")){row=Integer.parseInt(attributes.getValue("r"));code=false;quantity=false;}
                    if(tag.equals("c")){column=new org.apache.poi.ss.util.CellReference(attributes.getValue("r")).getCol();value=new StringBuilder();}
                }
                public void characters(char[] chars,int begin,int length){if(value!=null)value.append(chars,begin,length);}
                public void endElement(String uri,String local,String tag) {
                    if(tag.equals("c")) {
                        if(row==1) {
                            if(column==0)assertThat(value.toString()).isEqualTo("模具编号");
                            if(column==3)assertThat(value.toString()).isEqualTo("套数");
                        } else {
                            int original=50000-rows.get();
                            if(column==0){assertThat(value.toString()).isEqualTo("MX-"+token+"-%06d".formatted(original));code=true;}
                            if(column==3){assertThat(value.toString()).isEqualTo(new BigDecimal(original).add(new BigDecimal("0.125")).toPlainString());quantity=true;}
                        }
                        value=null;
                    }
                    if(tag.equals("row")&&row>1){assertThat(code).isTrue();assertThat(quantity).isTrue();rows.incrementAndGet();}
                }
            };
            try(var input=zip.getInputStream(zip.getEntry("xl/worksheets/sheet1.xml"))){factory.newSAXParser().parse(input,handler);}
        }
        assertThat(rows).hasValue(50001);
    }
    private void assertCaller(String report)throws Exception{
        String token="MX"+UUID.randomUUID().toString().replace("-","").substring(0,10);
        Seed seed=seed(report,token,251);
        exporter(report);
        var request=request(report,Map.of("keyword",token));
        var small=master.read(request);
        assertThat(small.total()).isEqualTo(251);
        assertThat(small.rows().stream().map(row->UUID.fromString(row.get("_platformRecordId").toString())).toList())
                .containsExactlyElementsOf(seed.ids());
        if(report.equals("goods"))assertThat(small.columns()).extracting(ExportColumn::key).doesNotContain("price","discount");
        if(report.equals("account"))assertThat(small.columns()).extracting(ExportColumn::key).doesNotContain("balanceCurrent");
        List<Map<String,Object>> streamed=new ArrayList<>();AtomicInteger batches=new AtomicInteger();
        try(var sink=ExportPageSink.open(page->{assertThat(page.rows().size()).isLessThanOrEqualTo(100);batches.incrementAndGet();streamed.addAll(page.rows());})){
            var result=master.read(request);
            assertThat(result.rows()).isEmpty();assertThat(result.total()).isEqualTo(251);
        }
        assertThat(batches).hasValue(3);assertThat(streamed).isEqualTo(small.rows());
        AtomicInteger empty=new AtomicInteger();
        try(var sink=ExportPageSink.open(page->{assertThat(page.rows()).isEmpty();empty.incrementAndGet();})){
            assertThat(master.read(request(report,Map.of("keyword",token+"not-present"))).total()).isZero();
        }
        assertThat(empty).hasValue(1);
    }

    @Test void hundredThousandGoodsUseOneCountBoundedManagedObjectsAndExactOriginalAmounts()throws Exception{
        String token="SCALE"+UUID.randomUUID().toString().replace("-","").substring(0,10);
        Seed seed=seed("goods",token,100_000);
        exporter("goods","goods:price:view","goods:discount:view");
        clearInvocations(goodsRepository);
        AtomicInteger rows=new AtomicInteger(),batches=new AtomicInteger(),peakManaged=new AtomicInteger();
        AtomicReference<BigDecimal> sum=new AtomicReference<>(BigDecimal.ZERO);
        AtomicLong previous=new AtomicLong(System.nanoTime()),peakHeap=new AtomicLong();
        List<Long> intervals=new ArrayList<>();
        MessageDigest actual=MessageDigest.getInstance("SHA-256"),expected=MessageDigest.getInstance("SHA-256");
        seed.ids().forEach(id->digest(expected,id));
        var sample=ProductionJdbcMeasurement.begin();
        long started=System.nanoTime();
        try(var sink=ExportPageSink.open(page->{
            long at=System.nanoTime();intervals.add(at-previous.getAndSet(at));
            peakHeap.accumulateAndGet(Runtime.getRuntime().totalMemory()-Runtime.getRuntime().freeMemory(),Math::max);
            batches.incrementAndGet();assertThat(page.rows()).hasSize(100);
            peakManaged.accumulateAndGet(em.unwrap(org.hibernate.Session.class).getStatistics().getEntityCount(),Math::max);
            assertThat(peakManaged.get()).isLessThan(2000);
            for(var row:page.rows()){
                rows.incrementAndGet();digest(actual,UUID.fromString(row.get("_platformRecordId").toString()));
                sum.updateAndGet(value->value.add((BigDecimal)row.get("price")));
            }
        })){
            var result=master.read(request("goods",Map.of("keyword",token)));
            assertThat(result.rows()).isEmpty();assertThat(result.total()).isEqualTo(100_000);
        }finally{ProductionJdbcMeasurement.end();}
        assertThat(rows).hasValue(100_000);assertThat(batches).hasValue(1000);
        assertThat(HexFormat.of().formatHex(actual.digest())).isEqualTo(HexFormat.of().formatHex(expected.digest()));
        BigDecimal original=jdbc.queryForObject("SELECT price FROM goods WHERE id=?",BigDecimal.class,seed.ids().getFirst());
        assertThat(sum.get()).isEqualByComparingTo(original.multiply(BigDecimal.valueOf(100_000)));
        verify(goodsRepository,times(1)).count(org.mockito.ArgumentMatchers.<Specification<com.uten.imp.features.master.goods.Goods>>notNull());
        verify(goodsRepository,never()).findAll(org.mockito.ArgumentMatchers.<Specification<com.uten.imp.features.master.goods.Goods>>notNull(),any(Pageable.class));
        assertThat(sample.logicalStatements).isLessThan(12_000);
        System.out.println("B1-MASTER-SOURCE rows="+rows+" batches="+batches+" peakManaged="+peakManaged
                +" sourceMillis="+(System.nanoTime()-started)/1_000_000+" statements="+sample.logicalStatements
                +" sourceBatchP95Millis="+percentile(intervals,0.95)+" sourceBatchP99Millis="+percentile(intervals,0.99)
                +" peakProcessHeapMiB="+peakHeap.get()/1048576
                +" pgContainerMemoryMiB=1024 pgContainerCpu=1 sourceBatch=100 exportConfiguredMax=100000");
    }

    @Test void configuredGoodsOwnerPolicyIsResolvedPerBatchRatherThanForEveryExportedRow()throws Exception{
        String token="OWNER"+UUID.randomUUID().toString().replace("-","").substring(0,10);
        seed("goods",token,251);exporter("goods");
        var policy=context.getBean(GoodsReadScopePolicy.class);
        ReflectionTestUtils.setField(policy,"ownerScopeEnabled",true);
        AtomicInteger rows=new AtomicInteger();var sample=ProductionJdbcMeasurement.begin();
        try(var sink=ExportPageSink.open(page->rows.addAndGet(page.rows().size()))){
            assertThat(master.read(request("goods",Map.of("keyword",token))).total()).isEqualTo(251);
        }finally{ProductionJdbcMeasurement.end();ReflectionTestUtils.setField(policy,"ownerScopeEnabled",false);}
        assertThat(rows).hasValue(251);
        assertThat(sample.logicalStatements).isLessThan(100);
    }

    private static void digest(MessageDigest digest,UUID id){digest.update(id.toString().getBytes(StandardCharsets.UTF_8));digest.update((byte)0);}
    private static double percentile(List<Long> values,double rank){var ordered=values.stream().sorted().toList();return ordered.get(Math.max(0,(int)Math.ceil(ordered.size()*rank)-1))/1_000_000.0;}
    private UUID category(String table,String token){UUID id=UUID.randomUUID();jdbc.update("INSERT INTO "+table+"(id,code,name) VALUES(?,?,?)",id,"CAT-"+token,token);return id;}
    private UUID mainWarehouse(){
        var roots=jdbc.queryForList("SELECT id FROM warehouses WHERE parent_id IS NULL AND NOT is_deleted",UUID.class);
        if(!roots.isEmpty())return roots.getFirst();
        UUID id=UUID.randomUUID();jdbc.update("INSERT INTO warehouses(id,code,name,status,is_accountable) VALUES(?,'001','主仓','使用',true)",id);return id;
    }
    private UUID accountStyle(){
        var leaves=jdbc.queryForList("SELECT s.id FROM payment_styles s WHERE s.category='ACCOUNT' AND NOT s.is_deleted AND (s.status='使用' OR s.status IS NULL) AND NOT EXISTS(SELECT 1 FROM payment_styles child WHERE child.parent_id=s.id AND NOT child.is_deleted) ORDER BY s.code,s.id LIMIT 1",UUID.class);
        if(!leaves.isEmpty())return leaves.getFirst();
        UUID id=UUID.randomUUID();jdbc.update("INSERT INTO payment_styles(id,code,name,category,status) VALUES(?,?,?,'ACCOUNT','使用')",id,"MXSTYLE-"+id,"Master export account leaf");return id;
    }
    private UUID accountCurrency(){
        var values=jdbc.queryForList("SELECT id FROM currencies WHERE NOT is_deleted AND status='使用' ORDER BY code,id LIMIT 1",UUID.class);
        if(!values.isEmpty())return values.getFirst();
        UUID id=UUID.randomUUID();jdbc.update("INSERT INTO currencies(id,code,name,status,exchange_rate) VALUES(?,?,?,'使用',1)",id,"MXCURRENCY-"+id,"Master export currency");return id;
    }
    private record Seed(List<UUID> ids){}
    private Seed seed(String report,String token,int count){
        String table=switch(report){case "goods"->"goods";case "client"->"clients";case "supplier"->"suppliers";
            case "account"->"accounts";case "currency"->"currencies";case "color"->"colors";case "unit"->"units";
            case "mould"->"moulds";case "warehouse"->"warehouses";case "settlement_method"->"settlement_methods";default->throw new IllegalArgumentException();};
        UUID category=switch(report){case "goods"->category("material_categories",token);case "client"->category("client_categories",token);
            case "supplier"->category("supplier_categories",token);case "mould"->category("mould_categories",token);case "warehouse"->mainWarehouse();case "account"->accountStyle();default->null;};
        long base=Set.of("goods","mould","client","supplier").contains(report)?jdbc.queryForObject("SELECT COALESCE(MAX(code_sequence),0) FROM "+table,Long.class):0;
        UUID currency="account".equals(report)?accountCurrency():null;
        List<UUID> ids=new ArrayList<>(count);for(int index=0;index<count;index++)ids.add(UUID.randomUUID());
        if("mould".equals(report)&&count>=10_000) {
            long began=System.nanoTime();
            for(int start=0;start<count;start+=1000) {
                int offset=start,end=Math.min(start+1000,count);
                jdbc.execute((org.springframework.jdbc.core.ConnectionCallback<Void>)connection->{
                    var selected=connection.createArrayOf("uuid",ids.subList(offset,end).toArray(UUID[]::new));
                    try(var statement=connection.prepareStatement("""
                        INSERT INTO moulds(id,code,name,status,category_id,code_sequence,code_managed,tqty)
                        SELECT source.id,?||lpad((?+source.ordinality-1)::text,6,'0'),
                          ?||(?+source.ordinality-1)::text,'使用',?,?+source.ordinality,FALSE,
                          CAST(?+source.ordinality-1 AS numeric)+0.125
                        FROM unnest(CAST(? AS uuid[])) WITH ORDINALITY source(id,ordinality)
                        """)) {
                        statement.setString(1,"MX-"+token+"-");statement.setInt(2,offset);
                        statement.setString(3,token+"-");statement.setInt(4,offset);
                        statement.setObject(5,category);statement.setLong(6,base+offset);
                        statement.setInt(7,offset);statement.setArray(8,selected);
                        assertThat(statement.executeUpdate()).isEqualTo(end-offset);
                    } finally {selected.free();}
                    return null;
                });
            }
            assertThat(jdbc.queryForObject("SELECT count(*) FROM pg_trigger WHERE tgrelid='moulds'::regclass AND NOT tgisinternal AND tgenabled='D'",Integer.class)).isZero();
            System.out.println("D3-MOULD-PREP realRows="+count+" boundedInsertRows=1000 disabledTriggers=0 seedMs="+(System.nanoTime()-began)/1000000);
            return new Seed(List.copyOf(ids));
        }
        String extras=switch(report){case "goods"->",category_id,code_sequence,auto_created,price,zk";
            case "client"->",category_id,owner_employee_id,code_sequence";case "supplier"->",category_id,code_sequence";case "account"->",style_id,currency_id";
            case "mould"->",category_id,code_sequence,code_managed,tqty";case "warehouse"->",parent_id,is_accountable";default->"";};
        int extraCount=switch(report){case "goods"->5;case "mould"->4;case "client"->3;case "supplier","warehouse","account"->2;default->0;};
        String sql="INSERT INTO "+table+"(id,code,name,status"+extras+") VALUES("+String.join(",",Collections.nCopies(4+extraCount,"?"))+")";
        List<Integer> indices=java.util.stream.IntStream.range(0,count).boxed().toList();
        var write=new org.springframework.transaction.support.TransactionTemplate(context.getBean(org.springframework.transaction.PlatformTransactionManager.class));
        // Fixture preparation is outside the measured export. Keep every row,
        // but release its connection between bounded writes instead of holding
        // one 100,000-row transaction past the production leak threshold.
        long seedStarted=System.nanoTime();
        for(int start=0;start<count;start+=1000){
            long batchStarted=System.nanoTime();
            int end=Math.min(start+1000,count);
            List<Integer> batch=indices.subList(start,end);
            write.executeWithoutResult(status->jdbc.batchUpdate(sql,batch,100,(ps,index)->{
            ps.setObject(1,ids.get(index));ps.setString(2,"MX-"+token+"-"+String.format("%06d",index));
            ps.setString(3,token+"-"+index);ps.setString(4,"使用");
            switch(report){
                case "goods"->{ps.setObject(5,category);ps.setLong(6,base+index+1);ps.setBoolean(7,false);ps.setBigDecimal(8,new BigDecimal("1.234567"));ps.setBigDecimal(9,new BigDecimal("0.9500"));}
                case "client"->{ps.setObject(5,category);ps.setObject(6,employee);ps.setLong(7,base+index+1);}
                case "supplier"->{ps.setObject(5,category);ps.setLong(6,base+index+1);}
                case "account"->{ps.setObject(5,category);ps.setObject(6,currency);}
                case "mould"->{ps.setObject(5,category);ps.setLong(6,base+index+1);ps.setBoolean(7,false);ps.setBigDecimal(8,BigDecimal.valueOf(index).add(new BigDecimal("0.125")));}
                case "warehouse"->{ps.setObject(5,category);ps.setBoolean(6,true);}
                default->{}
            }
            }));
            if(count>=10_000&&(start==0||end%10_000==0||end==count))
                System.out.println("B1-MASTER-SEED report="+report+" prepared="+end+" rows="+count
                        +" batchMillis="+(System.nanoTime()-batchStarted)/1_000_000
                        +" elapsedMillis="+(System.nanoTime()-seedStarted)/1_000_000);
        }
        return new Seed(List.copyOf(ids));
    }
}
