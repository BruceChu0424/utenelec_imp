package com.uten.imp.features.production.dailyreport;

import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.ProductionWorkshopMembership;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.sql.DriverManager;
import java.math.BigDecimal;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.LinkedHashMap;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.anyString;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ProductionOverLimitHeaderPostgresTest {
    private static final PostgreSQLContainer POSTGRES=new PostgreSQLContainer("postgres:16-alpine").withDatabaseName("over_limit_header");
    @BeforeAll static void start(){POSTGRES.start();}
    @AfterAll static void stop(){POSTGRES.stop();}

    @Test void filteringWithinKeepsImmutableBatchSlicesBeforeCountPagingAndAfterWithdrawal() throws Exception {
        try(var connection=DriverManager.getConnection(POSTGRES.getJdbcUrl(),POSTGRES.getUsername(),POSTGRES.getPassword())){
            var source=new SingleConnectionDataSource(connection,true);var jdbc=new JdbcTemplate(source);
            jdbc.execute("""
                CREATE TEMP TABLE fixture(id uuid,report_id uuid,item_id uuid,batch_id uuid,segment_id uuid,plan_id uuid,
                    goods_id uuid,owner_id uuid,actual numeric,total_over numeric,slice_qty numeric,allowed_rate numeric,
                    sibling_deleted boolean NOT NULL DEFAULT FALSE);
                CREATE TEMP VIEW production_over_limit_dispositions AS
                  SELECT id,CASE WHEN sibling_deleted THEN 'WITHDRAWN' ELSE 'PENDING' END::text AS status,0::bigint AS row_version,report_id,item_id AS report_item_id,
                    segment_id AS execution_segment_id,plan_id,1000::numeric AS planned_qty,allowed_rate,
                    actual AS actual_batch_qty,slice_qty AS qty,'多出生产超限'::text AS reason,
                    '2026-10-28 00:00+00'::timestamptz AS created_at,NULL::uuid AS last_decision_id FROM fixture
                  UNION ALL SELECT batch_id,CASE WHEN sibling_deleted THEN 'WITHDRAWN' ELSE 'PENDING' END,0::bigint,report_id,batch_id,
                    segment_id,plan_id,1000::numeric,allowed_rate,actual,total_over-slice_qty,'同批其它超限片段',
                    '2026-10-28 00:00+00'::timestamptz,NULL::uuid FROM fixture;
                CREATE TEMP VIEW production_daily_report_items AS
                  SELECT item_id AS id,report_id,batch_id AS output_batch_id,goods_id,NULL::uuid AS color_id,
                    '00000000-0000-0000-0000-000000000001'::uuid AS unit_id,slice_qty AS qty,TRUE AS is_over_limit,FALSE AS is_deleted FROM fixture
                  UNION ALL SELECT batch_id,report_id,batch_id,goods_id,NULL::uuid,
                    '00000000-0000-0000-0000-000000000001'::uuid,total_over-slice_qty,TRUE,sibling_deleted FROM fixture;
                CREATE TEMP VIEW production_daily_reports AS SELECT report_id AS id,'日报'::text AS bill_no,
                    CASE WHEN sibling_deleted THEN 0 ELSE 1 END::smallint AS status,FALSE AS is_deleted,owner_id AS maker_id FROM fixture;
                CREATE TEMP VIEW production_execution_segments AS SELECT segment_id AS id,'工单'::text AS segment_code,
                    NULL::uuid AS workshop_department_id,NULL::uuid AS responsible_employee_id FROM fixture;
                CREATE TEMP VIEW production_plans AS SELECT plan_id AS id,'计划'::text AS bill_no,owner_id AS maker_id FROM fixture;
                CREATE TEMP VIEW goods AS SELECT goods_id AS id,'G'::text AS code,'生产货品'::text AS name FROM fixture;
                CREATE TEMP VIEW colors AS SELECT NULL::uuid AS id,NULL::text AS name WHERE FALSE;
                CREATE TEMP VIEW units AS SELECT '00000000-0000-0000-0000-000000000001'::uuid AS id,'件'::text AS name;
                CREATE TEMP VIEW production_over_limit_decisions AS SELECT NULL::uuid AS id,NULL::text AS reason,
                    NULL::text AS decided_by_name,NULL::timestamptz AS decided_at WHERE FALSE;
                """);
            UUID owner=UUID.randomUUID();
            seed(jdbc,owner,"1200","100","40","0.1");
            seed(jdbc,owner,"1300","200","60","0.1");
            seed(jdbc,owner,"1250","250","40","0");
            seed(jdbc,UUID.randomUUID(),"1400","300","100","0.1");
            var named=new NamedParameterJdbcTemplate(source);var em=mock(EntityManager.class);
            when(em.createNativeQuery(anyString())).thenAnswer(call->query(named,call.getArgument(0)));
            var access=mock(ProductionDocumentAccessPolicy.class);when(access.hasAuthority(ProductionOverLimitDispositionService.APPROVE)).thenReturn(true);
            when(access.nativeReadScope("plan.maker_id","owners")).thenReturn(new NativeReadScope("plan.maker_id IN (:owners)","owners",Set.of(owner)));
            var service=new ProductionOverLimitDispositionService(em,access,mock(ProductionWorkshopMembership.class),null,null,null,null,null);
            var result=service.list("PENDING",2,1,"actual","desc",Map.of("search.actual",">=1200","search.within","=1100","search.over",">=40","search.goodsName","生产","search.reason","多出生产超限"));
            assertThat(result.getTotal()).isEqualTo(2);
            assertThat(result.getItems()).singleElement().satisfies(row->{
                assertThat(row.actualBatchQty()).isEqualByComparingTo("1200");
                assertThat(row.withinAuthorizationQty()).isEqualByComparingTo("1100");
                assertThat(row.overLimitQty()).isEqualByComparingTo("40");
                assertThat(row.unitName()).isEqualTo("件");
            });
            jdbc.update("UPDATE fixture SET sibling_deleted=TRUE WHERE owner_id=? AND actual=1200",owner);
            var withdrawn=service.list("WITHDRAWN",1,10,"actual","asc",Map.of("search.within","=1100","search.reason","多出生产超限"));
            assertThat(withdrawn.getTotal()).isEqualTo(1);
            assertThat(withdrawn.getItems()).singleElement().satisfies(row->{
                assertThat(row.status()).isEqualTo("WITHDRAWN");
                assertThat(row.withinAuthorizationQty()).isEqualByComparingTo("1100");
                assertThat(row.canDecide()).isFalse();
            });
        }
    }
    private static void seed(JdbcTemplate jdbc,UUID owner,String actual,String totalOver,String slice,String rate){
        jdbc.update("INSERT INTO fixture(id,report_id,item_id,batch_id,segment_id,plan_id,goods_id,owner_id,actual,total_over,slice_qty,allowed_rate) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID(),
            UUID.randomUUID(),UUID.randomUUID(),UUID.randomUUID(),owner,new BigDecimal(actual),new BigDecimal(totalOver),new BigDecimal(slice),new BigDecimal(rate));
    }
    private static Query query(NamedParameterJdbcTemplate jdbc,String sql){
        Map<String,Object> parameters=new LinkedHashMap<>();int[] paging={0,100};
        return mock(Query.class,call->{
            switch(call.getMethod().getName()){
                case "setParameter" -> {parameters.put(call.getArgument(0),call.getArgument(1));return call.getMock();}
                case "setFirstResult" -> {paging[0]=call.getArgument(0);return call.getMock();}
                case "setMaxResults" -> {paging[1]=call.getArgument(0);return call.getMock();}
                case "getSingleResult" -> {return jdbc.queryForObject(sql,parameters,Long.class);}
                case "getResultList" -> {var bound=new MapSqlParameterSource(parameters).addValue("test_limit",paging[1]).addValue("test_offset",paging[0]);
                    return jdbc.query(sql+" LIMIT :test_limit OFFSET :test_offset",bound,(rs,index)->{
                        Object[] row=new Object[rs.getMetaData().getColumnCount()];for(int i=0;i<row.length;i++) { row[i]=rs.getObject(i+1); } return row;});}
                default -> {return null;}
            }
        });
    }
}
