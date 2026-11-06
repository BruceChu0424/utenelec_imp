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

/** Real PostgreSQL equivalence and source-work counts for the two production metadata builders. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class WarehouseTaskPageMetadataPostgresTest {
    static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    Connection connection;NamedParameterJdbcTemplate db;
    @BeforeAll static void start(){PG.start();}
    @AfterAll static void stop(){PG.stop();}
    @BeforeEach void fixture() throws Exception {
        connection=DriverManager.getConnection(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword());
        db=new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection,true));
        db.getJdbcTemplate().execute("CREATE TEMP TABLE metadata_fixture(bill_no text,status text,active boolean,business_date date)");
        db.getJdbcTemplate().execute("CREATE TEMP SEQUENCE metadata_probe");
        db.getJdbcTemplate().execute("INSERT INTO metadata_fixture VALUES('A','OTHER_DRAFT',true,'2026-10-01'),('A','OTHER_APPROVED',false,'2026-10-02'),('B','OTHER_DRAFT',true,'2026-10-03'),(NULL,'OTHER_APPROVED',false,'2026-10-04')");
    }
    @AfterEach void close() throws Exception{connection.close();}

    @Test void inboundAndOutboundKeepStatusAndBillOwnFilterExclusionsAcrossViews() {
        for(String view:List.of("ACTIVE","HISTORY","ALL"))for(String status:List.of("","OTHER_DRAFT"))for(String bill:List.of("","A")) {
            Map<String,Object> p=params(view,status,bill);
            var outbound=outbound();
            var metadata=WarehouseTaskPageMetadata.from(rows(outbound.metadataSql(),p));
            assertThat(metadata.total()).isEqualTo(db.queryForObject(outbound.countSql(),p,Long.class));
            assertThat(metadata.statuses()).isEqualTo(buckets(rows(outbound.facetsSql(),p)));
            assertThat(metadata.bills().stream().collect(java.util.stream.Collectors.toMap(
                    WarehouseTaskCenterContracts.StatusFacet::value,WarehouseTaskCenterContracts.StatusFacet::count)))
                    .isEqualTo(buckets(rows(outbound.billNoFacetsSql(),p)));
            p.put("status",status); // Inbound uses empty string instead of null for no status.
            var inbound=WarehouseTaskPageMetadata.from(rows(WarehouseInboundTaskCenterSql.metadata(inbound()),p));
            assertThat(inbound.total()).isEqualTo(db.queryForObject(WarehouseInboundTaskCenterSql.count(inbound()),p,Long.class));
            assertThat(inbound.statuses()).isEqualTo(buckets(rows(WarehouseInboundTaskCenterSql.facets(inbound()),p)));
            assertThat(inbound.bills().stream().collect(java.util.stream.Collectors.toMap(
                    WarehouseTaskCenterContracts.StatusFacet::value,WarehouseTaskCenterContracts.StatusFacet::count)))
                    .isEqualTo(buckets(rows(WarehouseInboundTaskCenterSql.billNoFacets(inbound()),p)));
        }
    }

    @Test void historicalGrowthEvaluatesOneCandidateRelationInsteadOfThreeWithoutDroppingFacetBuckets() {
        db.getJdbcTemplate().execute("INSERT INTO metadata_fixture SELECT 'A-'||n,'OTHER_DRAFT',true,DATE '2026-10-01' FROM generate_series(1,48)n");
        int previous=0;
        for(int history:List.of(10_000,100_000,1_000_000)) {
            db.getJdbcTemplate().execute("INSERT INTO metadata_fixture SELECT 'H-'||n,'OTHER_APPROVED',false,DATE '2020-01-01' FROM generate_series("+(previous+1)+","+history+")n");
            previous=history;
            var p=params("ACTIVE","","");var plan=outbound();
            Runnable oldRead=()->{db.queryForObject(plan.countSql(),p,Long.class);rows(plan.facetsSql(),p);rows(plan.billNoFacetsSql(),p);};
            Runnable newRead=()->rows(plan.metadataSql(),p);
            restart();oldRead.run();long oldWork=probe();
            restart();var metadata=WarehouseTaskPageMetadata.from(rows(plan.metadataSql(),p));long sharedWork=probe();
            assertThat(metadata.total()).isEqualTo(50);assertThat(metadata.statuses()).containsEntry("OTHER_DRAFT",50L);
            assertThat(sharedWork).isEqualTo(history+52L);assertThat(oldWork).isEqualTo(sharedWork*3);
            String explain=db.queryForObject("EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) "+plan.metadataSql(),p,String.class);
            assertThat(explain).contains("source_rows");
            com.uten.imp.support.LoadingGrowthEvidence.write("warehouse-metadata",history,Map.of(
                    "oldSourceRows",oldWork,"sharedSourceRows",sharedWork,"oldStatements",3,"sharedStatements",1,
                    "before",com.uten.imp.support.LoadingGrowthEvidence.samples(oldRead),
                    "after",com.uten.imp.support.LoadingGrowthEvidence.samples(newRead)),explain);
        }
    }

    private WarehouseOutboundTaskCenterSql.Plan outbound(){
        return new WarehouseOutboundTaskCenterSql.Plan("""
            WITH source_rows AS MATERIALIZED(SELECT *,nextval('metadata_probe') AS probe FROM metadata_fixture),
            physical_rows AS(SELECT *,((:view='ALL' OR (:view='ACTIVE')=active)
              AND (CAST(:dateFrom AS date) IS NULL OR business_date>=CAST(:dateFrom AS date))
              AND (CAST(:dateTo AS date) IS NULL OR business_date<=CAST(:dateTo AS date))) AS context_match FROM source_rows),
            filtered AS(SELECT * FROM physical_rows WHERE context_match
              AND (CAST(:billNo AS text) IS NULL OR bill_no=CAST(:billNo AS text))
              AND (CAST(:status AS text) IS NULL OR status=CAST(:status AS text)))
            """,Map.of(),"");
    }
    private String inbound(){return "WITH inbound_rows AS MATERIALIZED(SELECT *,status AS workflow_status,'OTHER'::text AS source_type,nextval('metadata_probe') AS probe FROM metadata_fixture) ";}
    private Map<String,Object> params(String view,String status,String bill){Map<String,Object> p=new HashMap<>();p.put("view",view);p.put("status",status.isEmpty()?null:status);p.put("billNo",bill.isEmpty()?null:bill);p.put("source","ALL");p.put("dateFrom",null);p.put("dateTo",null);return p;}
    private List<Object[]> rows(String sql,Map<String,Object> p){return db.query(sql,p,(rs,i)->{Object[] row=new Object[rs.getMetaData().getColumnCount()];for(int k=0;k<row.length;k++){
        row[k]=rs.getObject(k+1);
    }
    return row;});}
    private Map<String,Long> buckets(List<Object[]> rows){Map<String,Long> values=new LinkedHashMap<>();for(var row:rows){
        values.put(String.valueOf(row[0]),((Number)row[1]).longValue());
    }
    return values;}
    private void restart(){db.getJdbcTemplate().execute("ALTER SEQUENCE metadata_probe RESTART WITH 1");}
    private long probe(){return db.getJdbcTemplate().queryForObject("SELECT last_value FROM metadata_probe",Long.class);}
}
