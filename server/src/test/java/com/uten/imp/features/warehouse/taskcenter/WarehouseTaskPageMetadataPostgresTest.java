package com.uten.imp.features.warehouse.taskcenter;

import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.sql.Connection;
import java.sql.DriverManager;
import java.util.*;
import static org.assertj.core.api.Assertions.assertThat;

/**
 * Real PostgreSQL equivalence and source-work counts for the merged inbound page statement.
 * The outbound statement needs the migrated schema (production-order joins); its parity
 * lives in {@code WarehouseOutboundTaskCenterSqlPostgresTest}.
 */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class WarehouseTaskPageMetadataPostgresTest {
    static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    Connection connection;NamedParameterJdbcTemplate db;
    @BeforeAll static void start(){PG.start();}
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void fixture() throws Exception {
        connection=DriverManager.getConnection(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        db=new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection,true));
        db.getJdbcTemplate().execute("CREATE TEMP TABLE metadata_fixture(id uuid DEFAULT gen_random_uuid(),bill_no text,status text,active boolean,business_date date)");
        db.getJdbcTemplate().execute("CREATE TEMP SEQUENCE metadata_probe");
        db.getJdbcTemplate().execute("INSERT INTO metadata_fixture(bill_no,status,active,business_date) VALUES('A','OTHER_DRAFT',true,'2026-10-01'),('A','OTHER_STOCKED',false,'2026-10-02'),('B','OTHER_DRAFT',true,'2026-10-03'),(NULL,'OTHER_STOCKED',false,'2026-10-04')");
    }
    @AfterEach void close() throws Exception{connection.close();}

    @Test void mergedInboundPageKeepsTotalsRowsAndStatusAndBillOwnFilterExclusionsAcrossViews() {
        for(String view:List.of("ACTIVE","HISTORY","ALL"))for(String status:List.of("","OTHER_DRAFT"))for(String bill:List.of("","A"))
            for(int page:List.of(1,2,3)) {
            Map<String,Object> p=params(view,status,bill,page,1);
            var merged=rows(WarehouseInboundTaskCenterSql.page(inbound(),null,null,"",true),p);
            assertThat(merged).isNotEmpty();
            var metadata=WarehouseTaskPageMetadata.fromJson(String.valueOf(merged.stream()
                    .map(row->row.get("page_metadata_buckets")).filter(Objects::nonNull).findFirst().orElseThrow()));
            long total=db.queryForObject(WarehouseInboundTaskCenterSql.count(inbound()),p,Long.class);
            assertThat(metadata.total()).isEqualTo(total);
            assertThat(merged).allSatisfy(row->assertThat(((Number)row.get("page_total")).longValue()).isEqualTo(total));
            assertThat(metadata.statuses()).isEqualTo(buckets(db.queryForList(inbound()+" SELECT workflow_status,COUNT(*) AS count FROM inbound_rows "
                    +WarehouseInboundTaskCenterSql.predicate(false)+" GROUP BY workflow_status ORDER BY workflow_status",p)));
            assertThat(metadata.bills().stream().collect(java.util.stream.Collectors.toMap(
                    WarehouseTaskCenterContracts.StatusFacet::value,WarehouseTaskCenterContracts.StatusFacet::count)))
                    .isEqualTo(buckets(db.queryForList(WarehouseInboundTaskCenterSql.billNoFacets(inbound()),p)));
            // Page rows are exactly the old page, in the old order; metadata rides one row only.
            assertThat(merged.stream().filter(row->row.get("id")!=null).map(row->row.get("id")).toList())
                    .isEqualTo(db.queryForList(WarehouseInboundTaskCenterSql.rows(inbound(),null,null,""),p)
                            .stream().map(row->row.get("id")).toList());
            assertThat(merged.stream().filter(row->row.get("page_metadata_buckets")!=null)).hasSize(1);
        }
    }

    @Test void historicalGrowthEvaluatesTheInboundRelationOnceForRowsTotalsAndFacets() {
        db.getJdbcTemplate().execute("INSERT INTO metadata_fixture(bill_no,status,active,business_date) SELECT 'A-'||n,'OTHER_DRAFT',true,DATE '2026-10-01' FROM generate_series(1,48)n");
        int previous=0;
        for(int history:List.of(10_000,100_000,1_000_000)) {
            db.getJdbcTemplate().execute("INSERT INTO metadata_fixture(bill_no,status,active,business_date) SELECT 'H-'||n,'OTHER_STOCKED',false,DATE '2020-01-01' FROM generate_series("+(previous+1)+","+history+")n");
            previous=history;
            var p=params("ACTIVE","","",1,20);
            String merged=WarehouseInboundTaskCenterSql.page(inbound(),null,null,"",true);
            // The previous interactive read: one metadata statement plus one rows statement.
            Runnable oldRead=()->{rows(previousMetadataSql(inbound()),p);rows(WarehouseInboundTaskCenterSql.rows(inbound(),null,null,""),p);};
            Runnable newRead=()->rows(merged,p);
            restart();oldRead.run();long oldWork=probe();
            restart();var page=rows(merged,p);long sharedWork=probe();
            var metadata=WarehouseTaskPageMetadata.fromJson(String.valueOf(page.getFirst().get("page_metadata_buckets")));
            assertThat(metadata.total()).isEqualTo(50);assertThat(metadata.statuses()).containsEntry("OTHER_DRAFT",50L);
            assertThat(page).hasSize(20);
            assertThat(sharedWork).isEqualTo(history+52L);assertThat(oldWork).isEqualTo(sharedWork*2);
            String explain=db.queryForObject("EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) "+merged,p,String.class);
            assertThat(explain).contains("inbound_snapshot");
            com.uten.imp.support.LoadingGrowthEvidence.write("warehouse-page",history,Map.of(
                    "oldSourceRows",oldWork,"sharedSourceRows",sharedWork,"oldStatements",2,"sharedStatements",1,
                    "before",com.uten.imp.support.LoadingGrowthEvidence.samples(oldRead),
                    "after",com.uten.imp.support.LoadingGrowthEvidence.samples(newRead)),explain);
        }
    }

    /** The metadata statement the service issued before the merge, kept only as this test's oracle. */
    private static String previousMetadataSql(String base) {
        String bill="(CAST(:billNo AS text) IS NULL OR bill_no=CAST(:billNo AS text))";
        String status="(:status = '' OR workflow_status = :status)";
        return base+", metadata_context AS MATERIALIZED (SELECT workflow_status,bill_no FROM inbound_rows "
                +WarehouseInboundTaskCenterSql.predicate(false,false)+")"
                +" SELECT 'TOTAL'::text AS bucket,NULL::text AS value,COUNT(*) AS task_count FROM metadata_context WHERE "+bill+" AND "+status
                +" UNION ALL SELECT 'STATUS',workflow_status,COUNT(*) FROM metadata_context WHERE "+bill
                +" GROUP BY workflow_status UNION ALL SELECT 'BILL',bill_no,task_count FROM ("
                +" SELECT bill_no,COUNT(*) AS task_count FROM metadata_context WHERE "+status
                +" AND bill_no IS NOT NULL GROUP BY bill_no ORDER BY bill_no LIMIT 500) bills ORDER BY bucket,value";
    }

    private String inbound(){return "WITH inbound_rows AS MATERIALIZED(SELECT *,status AS workflow_status,'OTHER'::text AS source_type,"
            +"'STOCK_DOCUMENT'::text AS record_type,0 AS keyword_rank,business_date::timestamptz AS sort_time,"
            +"NULL::jsonb AS line_data,nextval('metadata_probe') AS probe FROM metadata_fixture) ";}
    private Map<String,Object> params(String view,String status,String bill,int page,int size){Map<String,Object> p=new HashMap<>();
        p.put("view",view);p.put("status",status);p.put("billNo",bill.isEmpty()?null:bill);p.put("source","ALL");
        p.put("dateFrom",null);p.put("dateTo",null);p.put("limit",size);p.put("offset",(long)(page-1)*size);return p;}
    private List<Map<String,Object>> rows(String sql,Map<String,Object> p){return db.queryForList(sql,p);}
    private Map<String,Long> buckets(List<Map<String,Object>> rows){Map<String,Long> values=new LinkedHashMap<>();for(var row:rows){
        var columns=new ArrayList<>(row.values());
        values.put(String.valueOf(columns.get(0)),((Number)columns.get(1)).longValue());
    }
    return values;}
    private void restart(){db.getJdbcTemplate().execute("ALTER SEQUENCE metadata_probe RESTART WITH 1");}
    private long probe(){return db.getJdbcTemplate().queryForObject("SELECT last_value FROM metadata_probe",Long.class);}
}
