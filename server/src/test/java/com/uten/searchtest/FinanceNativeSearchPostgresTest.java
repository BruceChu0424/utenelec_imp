package com.uten.searchtest;

import com.uten.imp.features.finance.asset.application.FinanceAssetQueryService;
import com.uten.imp.features.finance.cost.FinanceCostService;
import com.uten.imp.features.finance.statement.FinanceStatementService;
import com.uten.imp.features.finance.report.ReportColumn;
import com.uten.imp.features.finance.report.ReportTableResponse;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.lang.reflect.Method;
import java.time.LocalDate;
import java.util.*;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Executes the real shared report executors and asset filter against PostgreSQL. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class FinanceNativeSearchPostgresTest {
    static final PostgreSQLContainer<?> PG=new PostgreSQLContainer<>("postgres:16-alpine");
    static NamedParameterJdbcTemplate db;
    static final LocalDate DATE=LocalDate.of(2026,10,16);
    static final List<ReportColumn> COLS=List.of(ReportColumn.text("goodsName","货品"),ReportColumn.text("goodsCode","编号"),
            ReportColumn.text("billNo","单号"),ReportColumn.money("amount","金额"));
    static final String CORE="""
            SELECT name AS "goodsName",code AS "goodsCode",bill AS "billNo",amount,party AS party_name,party_code
            FROM (VALUES
              ('ordinary','Metric Screw','A',9::numeric,'华南客户','CLIENT'),
              ('Metric Screw extra','OTHER','B',8::numeric,'华南客户','CLIENT'),
              ('Metric Screw','OTHER','C',7::numeric,'华南客户','CLIENT'),
              ('Small Metric Screw','OTHER','D',6::numeric,'华南客户','CLIENT'),
              ('特殊螺丝','A%_B','E',5::numeric,'华南客户','CLIENT'),
              ('特殊螺丝','AxYB','F',4::numeric,'华南客户','CLIENT')
            ) fixture(name,code,bill,amount,party,party_code)
            WHERE :from<=:to
            """;
    @BeforeAll static void start(){PG.start();db=new NamedParameterJdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword()));}
    @AfterAll static void stop(){PG.stop();}
    static EntityManager manager(){
        EntityManager em=mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call->{
            String sql=call.getArgument(0);Query q=mock(Query.class);Map<String,Object> values=new HashMap<>();
            when(q.setParameter(anyString(),any())).thenAnswer(binding->{values.put(binding.getArgument(0),binding.getArgument(1));return q;});
            when(q.getSingleResult()).thenAnswer(ignored->db.queryForObject(sql,values,Long.class));
            when(q.getResultList()).thenAnswer(ignored->db.query(sql,values,(rs,index)->{
                Object[] row=new Object[rs.getMetaData().getColumnCount()];for(int i=0;i<row.length;i++)row[i]=rs.getObject(i+1);return row;
            }));return q;
        });return em;
    }
    static ReportTableResponse cost(String keyword,int page,int size)throws Exception{
        Method method=FinanceCostService.class.getDeclaredMethod("runPaged",List.class,String.class,String.class,String.class,LocalDate.class,LocalDate.class,int.class,int.class,Map.class);
        method.setAccessible(true);return (ReportTableResponse)method.invoke(new FinanceCostService(manager()),COLS,CORE,"t.\"billNo\"",keyword,DATE,DATE,page,size,Map.of());
    }
    static ReportTableResponse statement(String keyword,int page,boolean timeline)throws Exception{
        Method method=FinanceStatementService.class.getDeclaredMethod("runPaged",List.class,String.class,String.class,String.class,LocalDate.class,LocalDate.class,int.class,int.class,Map.class,boolean.class,String[].class);
        method.setAccessible(true);return (ReportTableResponse)method.invoke(new FinanceStatementService(manager()),COLS,CORE,"t.\"billNo\"",keyword,DATE,DATE,page,1,Map.of(),timeline,
                new String[]{"t.\"goodsName\"","t.\"goodsCode\"","t.\"billNo\""});
    }
    @Test void costSearchRanksCompleteNamesBeforeCodesAndPagesTheCompleteFilteredSet()throws Exception{
        assertThat(cost("Metric Screw",1,1).rows().getFirst()).containsEntry("billNo","C");
        assertThat(cost("Metric Screw",2,1).rows().getFirst()).containsEntry("billNo","B");
        assertThat(cost("Metric Screw",3,1).rows().getFirst()).containsEntry("billNo","D");
        assertThat(cost("Metric Screw",4,1).rows().getFirst()).containsEntry("billNo","A");
        var result=cost("华南\u3000Screw",1,10);assertThat(result.total()).isEqualTo(4);
        assertThat(cost("特殊 A%_B",1,10).rows()).extracting(row->row.get("billNo")).containsExactly("E");
        assertThat(cost("Screw missing",1,10).total()).isZero();
        assertThat(cost("",1,1).rows().getFirst()).containsEntry("billNo","A");
    }
    @Test void statementSearchIncludesVisibleGoodsAndKeepsTheLedgerTimelineWhenRequested()throws Exception{
        var ranked=statement("Metric Screw",1,false);assertThat(ranked.total()).isEqualTo(4);
        assertThat(ranked.rows().getFirst()).containsEntry("billNo","C");
        assertThat(statement("华南 Screw",1,false).total()).isEqualTo(4);
        assertThat(statement("华南 Screw",1,true).rows().getFirst()).containsEntry("billNo","A");
        assertThat(statement("华南 Screw",2,true).rows().getFirst()).containsEntry("billNo","B");
        assertThat(statement("特殊 A%_B",1,false).rows().getFirst()).containsEntry("billNo","E");
    }
    @Test void assetFilterKeepsStatusCategoryDepartmentAndExactUuidBoundaries()throws Exception{
        UUID category=UUID.randomUUID(),department=UUID.randomUUID(),exact=UUID.randomUUID(),prefix=UUID.randomUUID(),code=UUID.randomUUID();
        String fixture="""
                SELECT a.id FROM (VALUES
                  (:code, 'Metric Screw','ordinary','invoice','ACTIVE',:cat,:dept),
                  (:prefix,'OTHER','Metric Screw extra','invoice','ACTIVE',:cat,:dept),
                  (:exact,'OTHER','Metric Screw','invoice','ACTIVE',:cat,:dept),
                  (gen_random_uuid(),'OTHER','Metric Screw','invoice','DRAFT',:cat,:dept),
                  (gen_random_uuid(),'OTHER','Metric Screw','invoice','ACTIVE',gen_random_uuid(),:dept)
                ) a(id,code,name,source_ref,lifecycle_status,category_id,department_id) WHERE TRUE
                """;
        Map<String,Object> values=new HashMap<>(Map.of("code",code,"prefix",prefix,"exact",exact,"cat",category,"dept",department));
        Object filter=assetFilter("Metric Screw","ACTIVE",category,department);
        values.putAll(parameters(filter));
        assertThat(db.queryForList(fixture+where(filter)+" ORDER BY "+rank(filter)+"a.code,a.id",values,UUID.class)).containsExactly(exact,prefix,code);
        filter=assetFilter(exact.toString(),"ACTIVE",category,department);values.keySet().removeAll(Set.of("q","exactId"));values.putAll(parameters(filter));
        assertThat(db.queryForList(fixture+where(filter)+" ORDER BY a.id",values,UUID.class)).containsExactly(exact);
        filter=assetFilter("A%_B","ACTIVE",category,department);values.keySet().removeAll(Set.of("q","exactId"));values.putAll(parameters(filter));
        assertThat(db.queryForList(fixture+where(filter)+" ORDER BY a.id",values,UUID.class)).isEmpty();
    }
    static Object assetFilter(String text,String status,UUID category,UUID department)throws Exception{
        Method method=FinanceAssetQueryService.class.getDeclaredMethod("filters",String.class,String.class,String.class,UUID.class,UUID.class);method.setAccessible(true);return method.invoke(null,"a",text,status,category,department);
    }
    static Object part(Object filter,String name)throws Exception{Method method=filter.getClass().getDeclaredMethod(name);method.setAccessible(true);return method.invoke(filter);}
    @SuppressWarnings("unchecked") static Map<String,Object> parameters(Object f)throws Exception{return (Map<String,Object>)part(f,"parameters");}
    static String where(Object f)throws Exception{return (String)part(f,"where");}
    static String rank(Object f)throws Exception{return (String)part(f,"rank");}
}
