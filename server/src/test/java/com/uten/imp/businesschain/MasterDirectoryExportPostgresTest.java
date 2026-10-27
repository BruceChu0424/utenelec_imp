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
                employee,"MX-"+employee,"Master export reader");
        master=new MasterReportExportSource(context.getBean(GoodsService.class),context.getBean(ClientService.class),
                context.getBean(SupplierService.class),context.getBean(AccountService.class),context.getBean(CurrencyService.class),
                context.getBean(ColorService.class),context.getBean(UnitService.class),context.getBean(MouldService.class),
                context.getBean(WarehouseService.class),context.getBean(ReferenceMethodService.class),objectMapper,validator,()->100_000);
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
        verify(goodsRepository,times(1)).count(org.mockito.ArgumentMatchers.<Specification<com.uten.imp.features.master.goods.Goods>>any());
        verify(goodsRepository,never()).findAll(org.mockito.ArgumentMatchers.<Specification<com.uten.imp.features.master.goods.Goods>>any(),any(Pageable.class));
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
        String extras=switch(report){case "goods"->",category_id,code_sequence,auto_created,price,zk";
            case "client"->",category_id,owner_employee_id,code_sequence";case "supplier"->",category_id,code_sequence";case "account"->",style_id,currency_id";
            case "mould"->",category_id,code_sequence,code_managed";case "warehouse"->",parent_id,is_accountable";default->"";};
        int extraCount=switch(report){case "goods"->5;case "client","mould"->3;case "supplier","warehouse","account"->2;default->0;};
        String sql="INSERT INTO "+table+"(id,code,name,status"+extras+") VALUES("+String.join(",",Collections.nCopies(4+extraCount,"?"))+")";
        List<Integer> indices=java.util.stream.IntStream.range(0,count).boxed().toList();
        var write=new org.springframework.transaction.support.TransactionTemplate(context.getBean(org.springframework.transaction.PlatformTransactionManager.class));
        write.executeWithoutResult(status->jdbc.batchUpdate(sql,indices,100,(ps,index)->{
            ps.setObject(1,ids.get(index));ps.setString(2,"MX-"+token+"-"+String.format("%06d",index));
            ps.setString(3,token+"-"+index);ps.setString(4,"使用");
            switch(report){
                case "goods"->{ps.setObject(5,category);ps.setLong(6,base+index+1);ps.setBoolean(7,false);ps.setBigDecimal(8,new BigDecimal("1.234567"));ps.setBigDecimal(9,new BigDecimal("0.9500"));}
                case "client"->{ps.setObject(5,category);ps.setObject(6,employee);ps.setLong(7,base+index+1);}
                case "supplier"->{ps.setObject(5,category);ps.setLong(6,base+index+1);}
                case "account"->{ps.setObject(5,category);ps.setObject(6,currency);}
                case "mould"->{ps.setObject(5,category);ps.setLong(6,base+index+1);ps.setBoolean(7,false);}
                case "warehouse"->{ps.setObject(5,category);ps.setBoolean(6,true);}
                default->{}
            }
        }));
        return new Seed(List.copyOf(ids));
    }
}
