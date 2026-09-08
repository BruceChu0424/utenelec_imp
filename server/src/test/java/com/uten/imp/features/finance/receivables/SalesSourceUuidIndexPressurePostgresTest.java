package com.uten.imp.features.finance.receivables;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.persistence.EntityManager;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;

import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

/** Opt-in migration/plan proof on the existing isolated 500k copy; never seeds or targets the old baseline. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_SALES_MONEY_PRESSURE",matches="(?i)true")
class SalesSourceUuidIndexPressurePostgresTest {
    private static final String INDEX="idx_ar_ap_source_refs_source_uuid";
    private static final Map<String,String> BUSINESS_COLUMNS=Map.ofEntries(
            Map.entry("sales_orders","id,client_id,currency_id,trim_scale(total_original),trim_scale(total_local),status,finance_confirmed"),
            Map.entry("sales_order_items","id,order_id,goods_id,trim_scale(qty),trim_scale(price),trim_scale(amount_original),trim_scale(shipped_qty),trim_scale(returned_qty)"),
            Map.entry("sales_shipments","id,client_id,currency_id,warehouse_id,status,warehouse_work_status,trim_scale(total_original),trim_scale(total_local)"),
            Map.entry("sales_shipment_items","id,shipment_id,order_item_id,goods_id,trim_scale(qty),trim_scale(price),trim_scale(amount_original),trim_scale(amount_local)"),
            Map.entry("sales_returns","id,source_shipment_id,client_id,currency_id,warehouse_id,status,trim_scale(total_original),trim_scale(total_local)"),
            Map.entry("sales_return_items","id,return_id,out_item_id,order_item_id,goods_id,trim_scale(qty),trim_scale(price),trim_scale(amount_original),trim_scale(amount_local)"),
            Map.entry("ar_ap_ledger","id,direction,source_doc_type,source_doc_id,client_id,currency_id,trim_scale(amount_original),trim_scale(amount_original_local),trim_scale(amount_balance_original),trim_scale(amount_balance),status"),
            Map.entry("ar_ap_source_refs","id,ledger_id,source_type,source_id,source_sequence,trim_scale(amount_original),trim_scale(amount_local)"));

    @Test void exactOrderResultAndEightBusinessDigestsStayUnchangedWhileUuidLookupStopsScanning500k() throws Exception {
        ObjectMapper json=new ObjectMapper();
        String configPath=System.getProperty("uten.sales.pressure.databaseConfig","");
        assertFalse(configPath.isBlank(),"Only an existing explicitly identified copied pressure database is allowed");
        JsonNode config=json.readTree(Path.of(configPath).toFile());
        String sourceDatabase=config.path("sourceBaselineDatabase").asText();
        assertTrue(sourceDatabase.startsWith("uten_pressure_"),"The copied fixture must retain its baseline identity");
        assertNotEquals(sourceDatabase,config.path("database").asText(),"Never migrate the baseline itself");
        Map<String,Object> properties=new LinkedHashMap<>();
        SalesPressureDatabase.configure((name,supplier)->properties.put(name,supplier.get()));
        assertTrue(SalesPressureDatabase.persistent());
        var dataSource=new DriverManagerDataSource((String)properties.get("spring.datasource.url"),
                (String)properties.get("spring.datasource.username"),(String)properties.get("spring.datasource.password"));
        try(Connection connection=dataSource.getConnection()) {
            assertEquals("531",scalar(connection,"SELECT version FROM flyway_schema_history WHERE success ORDER BY installed_rank DESC LIMIT 1"));
            assertEquals("490",scalar(connection,"SELECT count(*) FROM flyway_schema_history WHERE success"));
            assertEquals("500000",scalar(connection,"SELECT count(*) FROM ar_ap_source_refs"));
            assertEquals("0",scalar(connection,"SELECT count(*) FROM pg_class WHERE relnamespace='public'::regnamespace AND relname='"+INDEX+"'"));
        }
        var builder=new LocalContainerEntityManagerFactoryBean();builder.setDataSource(dataSource);
        builder.setJpaVendorAdapter(new HibernateJpaVendorAdapter());builder.setPackagesToScan("com.uten.imp.features.common.taskclaim");
        Properties hibernate=new Properties();hibernate.setProperty("hibernate.hbm2ddl.auto","none");builder.setJpaProperties(hibernate);builder.afterPropertiesSet();
        var factory=builder.getObject();assertNotNull(factory);
        EntityManager em=factory.createEntityManager();
        try {
            var sql=new AtomicReference<String>();EntityManager observer=mock(EntityManager.class);
            when(observer.createNativeQuery(anyString())).thenAnswer(call->{sql.set(call.getArgument(0));return em.createNativeQuery(sql.get());});
            var query=new SalesOrderMoneyPositionQuery(observer);
            UUID order;
            Map<String,BusinessDigest> beforeDigests;
            try(Connection connection=dataSource.getConnection()) {
                order=UUID.fromString(scalar(connection,"SELECT id FROM sales_orders WHERE client_id=(SELECT client_id FROM audit_pressure.fixtures WHERE fixture_id='sales-money-v2') ORDER BY id LIMIT 1"));
                beforeDigests=digests(connection);
            }
            var before=query.invoices(order);
            assertEquals(0,before.grossOriginal().compareTo(new java.math.BigDecimal("100")));
            assertEquals(0,before.remainingOriginal().compareTo(new java.math.BigDecimal("100")));
            assertEquals(0,before.unresolvedCount());assertEquals(0,before.unresolvedCashCount());
            JsonNode beforePlan=explain(json,em,sql.get(),order);
            assertTrue(scansLargeSourceHistory(beforePlan.path("Plan")),"The V531 regression fixture must reproduce its measured full scan");
            Path evidence=Path.of(System.getProperty("uten.sales.pressure.indexEvidenceDirectory","target/source-uuid-index-evidence"));Files.createDirectories(evidence);
            json.writerWithDefaultPrettyPrinter().writeValue(evidence.resolve("before-plan.json").toFile(),beforePlan);
            json.writerWithDefaultPrettyPrinter().writeValue(evidence.resolve("before-business-digests.json").toFile(),beforeDigests);

            // A separate migration connection avoids Docker's 64MiB parallel-build shared-memory limit.
            // Application queries keep their normal defaults; no table/role/container setting is changed.
            var migration=Flyway.configure().dataSource(dataSource).locations("classpath:db/migration")
                    .target("532").cleanDisabled(true).outOfOrder(false)
                    .initSql("SET max_parallel_workers_per_gather=0; SET max_parallel_maintenance_workers=0;")
                    .load().migrate();
            assertTrue(migration.success);assertEquals(1,migration.migrationsExecuted);
            assertEquals("532",migration.targetSchemaVersion);

            var after=query.invoices(order);assertEquals(before,after,"An access-path change must not change source attribution or unresolved counts");
            JsonNode afterPlan=explain(json,em,sql.get(),order);
            assertTrue(usesIndex(afterPlan.path("Plan")),"The real UUID lookup must use the new index");
            assertFalse(scansLargeSourceHistory(afterPlan.path("Plan")),"The selected order must not scan the unrelated 500k source history");
            Map<String,BusinessDigest> afterDigests;
            try(Connection connection=dataSource.getConnection()) {
                afterDigests=digests(connection);assertEquals(beforeDigests,afterDigests);
                assertEquals("532",scalar(connection,"SELECT version FROM flyway_schema_history WHERE success ORDER BY installed_rank DESC LIMIT 1"));
                assertEquals("491",scalar(connection,"SELECT count(*) FROM flyway_schema_history WHERE success"));
                assertEquals("2/2",scalar(connection,"SELECT current_setting('max_parallel_workers_per_gather')||'/'||current_setting('max_parallel_maintenance_workers')"));
            }
            json.writerWithDefaultPrettyPrinter().writeValue(evidence.resolve("after-plan.json").toFile(),afterPlan);
            json.writerWithDefaultPrettyPrinter().writeValue(evidence.resolve("after-business-digests.json").toFile(),afterDigests);
            json.writerWithDefaultPrettyPrinter().writeValue(evidence.resolve("result.json").toFile(),Map.of(
                    "migrationHead",532,"migrationCount",491,"migrationsApplied",1,"sameExactInvoicePosition",true,
                    "sameEightBusinessDigests",true,"beforeScanned500k",true,"afterUsesSourceUuidIndex",true,"afterScans500k",false));
        } finally {em.close();factory.close();}
    }

    private static JsonNode explain(ObjectMapper json,EntityManager em,String sql,UUID order) throws Exception {
        return json.readTree(em.createNativeQuery("EXPLAIN (ANALYZE,BUFFERS,TIMING OFF,FORMAT JSON) "+sql)
                .setParameter("orderId",order).getSingleResult().toString()).get(0);
    }
    private static boolean scansLargeSourceHistory(JsonNode node) {
        if("ar_ap_source_refs".equals(node.path("Relation Name").asText())
                && node.path("Node Type").asText().contains("Scan")
                && (node.path("Actual Rows").asLong()+node.path("Rows Removed by Filter").asLong())
                   * node.path("Actual Loops").asLong()>=490000)return true;
        for(JsonNode child:node.path("Plans"))if(scansLargeSourceHistory(child))return true;
        return false;
    }
    private static boolean usesIndex(JsonNode node) {
        if(INDEX.equals(node.path("Index Name").asText()))return true;
        for(JsonNode child:node.path("Plans"))if(usesIndex(child))return true;
        return false;
    }
    private static Map<String,BusinessDigest> digests(Connection connection) throws Exception {
        Map<String,BusinessDigest> result=new LinkedHashMap<>();
        for(String table:BUSINESS_COLUMNS.keySet().stream().sorted().toList()) {
            try(var statement=connection.createStatement();var rows=statement.executeQuery(
                    "SELECT count(*),md5(string_agg(md5(ROW("+BUSINESS_COLUMNS.get(table)+")::text),'' ORDER BY id)) FROM "+table)) {
                assertTrue(rows.next());long count=rows.getLong(1);
                assertEquals(table.equals("ar_ap_ledger")?1000000:500000,count,table);
                result.put(table,new BusinessDigest(count,rows.getString(2)));
            }
        }
        return result;
    }
    private static String scalar(Connection connection,String sql) throws Exception {
        try(var statement=connection.createStatement();var rows=statement.executeQuery(sql)){assertTrue(rows.next());return rows.getString(1);}
    }
    private record BusinessDigest(long rows,String sortedBusinessDigest){}
}
