package com.uten.imp.features.stock.report;

import com.uten.imp.features.admin.systemsetting.SystemSettingKey;
import com.uten.imp.features.admin.systemsetting.SystemSettingsService;
import com.uten.imp.features.stock.StockCostMasker;
import com.uten.imp.features.stock.StockQueryService;
import com.uten.imp.support.MigratedProjectionSchema;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

/** Real current-table SQL through the actual rows/count/facet/total/export executor. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class StockReportHeaderPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    private static JdbcTemplate db;
    private static NamedParameterJdbcTemplate named;
    private StockReportService service;
    private EntityManager em;
    private static final List<String> TYPES=List.of("TRANSFER","OTHER_IN","DRAW","WDRAW","FINISHED_IN","FINISHED_OUT","CHECK");

    @BeforeAll static void start() {
        PG.start();var source=new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        db=new JdbcTemplate(source);named=new NamedParameterJdbcTemplate(source);
        MigratedProjectionSchema.createCurrentTables(db,"stock_documents","stock_document_items","warehouses","clients",
                "departments","employees","goods","colors","units");
    }
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void fixture() {
        db.execute("TRUNCATE stock_document_items,stock_documents,warehouses,clients,departments,employees,goods,colors,units");
        em=mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call->query(call.getArgument(0)));
        var settings=mock(SystemSettingsService.class);
        when(settings.readInt(SystemSettingKey.EXPORT_MAX_ROWS)).thenReturn(1000);
        service=new StockReportService(em,settings,mock(StockQueryService.class),mock(StockCostMasker.class));
    }

    @Test void everyDeclaredPhysicalHeaderExecutesAcrossAllFourteenReportsAndRejectsUndeclaredCostColumns() {
        seed("DRAW");
        for(String type:TYPES) for(boolean detail:List.of(true,false)) {
            var initial=read(type,detail,Map.of(),1,20,null,null,null);
            assertThat(initial.columnSearchKeys()).contains("billNo","billDate").doesNotContain("approved","__srcId","costAmount");
            for(String key:initial.columnSearchKeys()) {
                var column=initial.columns().stream().filter(candidate->candidate.key().equals(key)).findFirst().orElseThrow();
                String input=column.type().equals("date")?"2026-10-01..2026-10-31":
                        Set.of("number","weight").contains(column.type())?">=0":"literal%_does_not_match";
                assertThatCode(()->read(type,detail,Map.of("search."+key,input),1,20,null,null,null))
                        .as(type+"/"+(detail?"detail":"summary")+" "+key).doesNotThrowAnyException();
            }
            clearInvocations(em);
            assertThatThrownBy(()->read(type,detail,Map.of("search.costAmount",">0"),1,20,null,null,null))
                    .isInstanceOf(com.uten.imp.common.web.ApiException.class);
            verifyNoInteractions(em);
        }
    }

    @Test void explicitUnapprovedFacetIncludesDraftsWithoutChangingDefaultsAndSharesCountFacetsTotalsPagesAndExport() {
        for(String type:TYPES) {
            db.execute("TRUNCATE stock_document_items,stock_documents,warehouses,units,goods");
            seed(type);
            for(boolean detail:List.of(true,false)) {
                assertThat(read(type,detail,Map.of(),1,20,null,null,null).total()).as(type+" default").isEqualTo(2);
                Map<String,String> filters=Map.of("approved","false","search.billDate","2026-10-01..2026-10-31","search.billNo","HEADER%_");
                var first=read(type,detail,filters,1,1,null,"billDate","asc");
                var next=read(type,detail,filters,2,1,null,"billDate","asc");
                assertThat(first.total()).as(type).isEqualTo(2);
                assertThat(first.totalPages()).isEqualTo(2);
                assertThat(first.rows().getFirst().get("billNo")).isEqualTo("HEADER%_DRAFT");
                assertThat(next.rows().getFirst().get("billNo")).isEqualTo("HEADER%_REVERSED");
                assertThat(first.facets().get("approved").stream().mapToLong(ReportFacet::count).sum()).isEqualTo(3);
                String warehouseKey=type.equals("TRANSFER")?null:"warehouseName";
                if(warehouseKey!=null) assertThat(first.facets().get(warehouseKey).stream().mapToLong(ReportFacet::count).sum()).isEqualTo(2);
                if(detail) {
                    var quantity=first.totals().stream().filter(total->"unitName".equals(total.groupKey())).findFirst().orElseThrow();
                    assertThat(quantity.groups()).hasSize(2);
                    assertThat(first.totals()).isEqualTo(next.totals());
                } else assertThat(first.totals()).isEmpty();
                var parameters=new LinkedHashMap<String,String>();
                parameters.put("f.approved","false");parameters.put("search.billDate","2026-10-01..2026-10-31");
                parameters.put("search.billNo","HEADER%_");
                var export=service.export(type+"/"+(detail?"detail":"summary"),parameters,"billDate","asc");
                assertThat(export.total()).isEqualTo(2);
                assertThat(export.rows()).extracting(row->row.get("billNo")).containsExactly("HEADER%_DRAFT","HEADER%_REVERSED");
                assertThat(read(type,detail,filters,1,20,(short)1,null,null).total()).isZero();
            }
            db.update("UPDATE stock_documents SET status=1 WHERE status=-1");
            assertThat(read(type,true,Map.of(),1,20,null,null,null).facets().get("approved"))
                    .anySatisfy(facet->{assertThat(facet.value()).isEqualTo("false");assertThat(facet.count()).isZero();});
            assertThat(read(type,true,Map.of("approved","false"),1,20,null,null,null).total()).isEqualTo(1);
        }
    }

    @Test void physicalNumbersAndKgWeightsRetainFourPlacesAndTheExplicitSortWinsOverKeywordRank() {
        seed("OTHER_IN");
        db.update("UPDATE stock_documents SET status=1");
        db.update("UPDATE stock_document_items SET qty=99999999999999.0001,weight=0.5001 WHERE goods_code_snapshot='G-DRAFT'");
        db.update("UPDATE stock_document_items SET qty=99999999999999.0002,weight=0.5002 WHERE goods_code_snapshot='G-APPROVED'");
        var filters=Map.of("search.qty",">99999999999999","search.weight","0.5001..0.5002");
        var one=read("OTHER_IN",true,filters,1,1,null,"qty","desc");
        var two=read("OTHER_IN",true,filters,2,1,null,"qty","desc");
        assertThat(one.total()).isEqualTo(2);
        assertThat(one.rows().getFirst().get("qtyExact")).isEqualTo("99999999999999.0002");
        assertThat(two.rows().getFirst().get("qtyExact")).isEqualTo("99999999999999.0001");
        assertThat(one.rows().getFirst().get("weightExact")).isEqualTo("0.5002");
        db.update("UPDATE stock_documents SET bill_no='HEADER%_' WHERE id IN (SELECT doc_id FROM stock_document_items WHERE goods_code_snapshot='G-DRAFT')");
        var kw=service.detail("OTHER_IN",null,null,null,null,null,null,null,"HEADER%_",filters,1,1,"qty","desc");
        assertThat(kw.rows().getFirst().get("qtyExact")).isEqualTo("99999999999999.0002");
    }

    private ReportTableResponse read(String type,boolean detail,Map<String,String> filters,int page,int size,Short status,String sort,String order) {
        return detail?service.detail(type,null,null,null,status,null,null,null,null,filters,page,size,sort,order)
                :service.summary(type,null,null,null,status,null,null,null,null,filters,page,size,sort,order);
    }
    private void seed(String type) {
        UUID warehouse=UUID.randomUUID(),u1=UUID.randomUUID(),u2=UUID.randomUUID(),goods=UUID.randomUUID();
        db.update("INSERT INTO warehouses(id,name) VALUES(?,'成品仓')",warehouse);
        db.update("INSERT INTO units(id,name) VALUES(?,'件'),(?,'米')",u1,u2);
        db.update("INSERT INTO goods(id,code,name,unit_id,stock_place,model,c_number,spec,series,material) VALUES(?,'G','物料',?,'A-1','型号','客户型','规格','系列','材质')",goods,u1);
        int index=0;
        for(short status:new short[]{0,1,-1}) {
            String label=index==0?"DRAFT":index==1?"APPROVED":"REVERSED";
            UUID id=UUID.randomUUID();
            db.update("INSERT INTO stock_documents(id,doc_type,bill_no,bill_date,status,is_deleted,warehouse_id,to_warehouse_id) VALUES(?,?,?,?,?,false,?,?)",
                    id,type,"HEADER%_"+label,LocalDate.of(2026,10,index+1),status,warehouse,warehouse);
            db.update("INSERT INTO stock_document_items(id,doc_id,bill_type,line_no,goods_id,unit_id,goods_code_snapshot,goods_name_snapshot,qty,issued_qty,base_qty,weight,count_qty,surplus_qty,book_weight,count_weight,is_deleted)"
                    +" VALUES(?,?,?,1,?,?,?,?::text,?,0,?,0.5,?,2,0.4,0.6,false)",
                    UUID.randomUUID(),id,type,goods,index==2?u2:u1,"G-"+label,"物料%_"+label,
                    new BigDecimal(index+1),new BigDecimal(index+1),new BigDecimal(index+3));
            index++;
        }
    }
    private Query query(String sql) {
        Map<String,Object> parameters=new LinkedHashMap<>();
        return mock(Query.class,call->{
            String method=call.getMethod().getName();
            if(method.equals("setParameter")){parameters.put(call.getArgument(0),call.getArgument(1));return call.getMock();}
            if(method.equals("getResultList")) return named.query(sql,parameters,(rs,row)->{
                Object[] values=new Object[rs.getMetaData().getColumnCount()];for(int column=0;column<values.length;column++)values[column]=rs.getObject(column+1);return values;
            });
            if(method.equals("getSingleResult")) return named.queryForObject(sql,parameters,Object.class);
            if(call.getMethod().getReturnType().isAssignableFrom(Query.class)) return call.getMock();
            return org.mockito.Answers.RETURNS_DEFAULTS.answer(call);
        });
    }
}
