package com.uten.imp.features.finance.receivables;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.Executors;

import static org.assertj.core.api.Assertions.assertThat;

/** Explicitly gated service/query benchmark; synthetic state is never a claim of write-chain throughput. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_SALES_MONEY_PRESSURE", matches="(?i)true")
@SpringBootTest(properties={"spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false", "uten.policy-intelligence.enabled=false",
        "spring.datasource.hikari.maximum-pool-size=20",
        "uten.jwt.secret=sales-pressure-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=sales-pressure-harness-pgp-test-only-0123456789",
        "uten.crypto.hmac-key=sales-pressure-harness-hmac-test-only",
        "uten.bootstrap.admin-login=sales-pressure-bootstrap-test",
        "uten.bootstrap.admin-password=SalesPressureTest-1!"})
class SalesMoneyProjectionPressurePostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        SalesPressureDatabase.configure(registry);
    }
    @Autowired NamedParameterJdbcTemplate jdbc;
    @Autowired CustomerPrepaymentQueryService summary;
    @Autowired ObjectMapper json;
    @Autowired org.springframework.transaction.PlatformTransactionManager transactionManager;
    private org.springframework.transaction.support.TransactionTemplate seedTransactions;
    private int committedBatches;

    @Test
    void benchmarkAttributedMoneyQueriesAfterCheckingTheirResults() throws Exception {
        // Keep preparation and measurement mutually exclusive even across JVMs.
        try (var connection=SalesPressureDatabase.connect(); var statement=connection.createStatement()) {
            try (var lock=statement.executeQuery("SELECT pg_try_advisory_lock(20260907, 500000)")) {
                if (!lock.next() || !lock.getBoolean(1)) throw new IllegalStateException("Another pressure run owns this database");
            }
            try { runBenchmark(); }
            finally { statement.execute("SELECT pg_advisory_unlock(20260907, 500000)"); }
        }
    }

    private void runBenchmark() throws Exception {
        int orderCount=Integer.getInteger("uten.sales.pressure.orders",10_000);
        int readers=Integer.getInteger("uten.sales.pressure.readers",8);
        int calls=Integer.getInteger("uten.sales.pressure.calls",2_000);
        if (orderCount<100 || orderCount>500_000 || readers<1 || readers>16 || calls<100 || calls>100_000) {
            throw new IllegalArgumentException("Pressure bounds: 100-500000 orders, 1-16 readers, 100-100000 calls");
        }
        if (Boolean.getBoolean("uten.sales.pressure.prepareOnly") && !SalesPressureDatabase.persistent()) {
            throw new IllegalArgumentException("prepareOnly requires a persistent isolated database");
        }
        long seedStarted=System.nanoTime();
        seedTransactions=new org.springframework.transaction.support.TransactionTemplate(transactionManager);
        List<UUID> orders=seed(orderCount);
        double seedSeconds=(System.nanoTime()-seedStarted)/1_000_000_000d;
        if (Boolean.getBoolean("uten.sales.pressure.prepareOnly")) {
            for (int i=0;i<100;i++) verify(orders.get((i*7919)%orders.size()));
            System.out.println("SALES_MONEY_PRESSURE_PREPARED orders="+orders.size()+" preparationSeconds="+seedSeconds+"; no throughput measurement performed");
            return;
        }
        waitForMeasurementWindow(orderCount);
        for (int i=0;i<100;i++) verify(orders.get(i%orders.size()));
        long[] timings=new long[calls];
        long started=System.nanoTime();
        try (var workers=Executors.newFixedThreadPool(readers)) {
            var tasks=new ArrayList<java.util.concurrent.Callable<Void>>();
            for (int i=0;i<calls;i++) {
                final int index=i;
                tasks.add(()->{
                    long start=System.nanoTime();
                    verify(orders.get((index*7919)%orders.size()));
                    timings[index]=System.nanoTime()-start;
                    return null;
                });
            }
            for (var task:workers.invokeAll(tasks)) task.get();
        }
        double elapsed=(System.nanoTime()-started)/1_000_000_000d;
        Arrays.sort(timings);
        Map<String,Object> report=new LinkedHashMap<>();
        report.put("scope","synthetic isolated PostgreSQL service/query benchmark; excludes setup, HTTP and write throughput");
        report.put("databaseImage",SalesPressureDatabase.image());
        report.put("resumableFixture",SalesPressureDatabase.persistent());
        report.put("fixtureVersion",2);
        report.put("databaseVersion",jdbc.getJdbcTemplate().queryForObject("SHOW server_version",String.class));
        report.put("databaseCollation",jdbc.getJdbcTemplate().queryForObject(
                "SELECT datcollate FROM pg_database WHERE datname=current_database()",String.class));
        report.put("migrationHead",jdbc.getJdbcTemplate().queryForObject(
                "SELECT max(version::integer) FROM flyway_schema_history WHERE success AND version IS NOT NULL",Integer.class));
        report.put("migrationCount",jdbc.getJdbcTemplate().queryForObject(
                "SELECT count(*) FROM flyway_schema_history WHERE success AND version IS NOT NULL",Integer.class));
        report.put("seedBatchRows",500); report.put("seedSeconds",seedSeconds);
        report.put("orders",orderCount); report.put("shipments",orderCount); report.put("returns",orderCount);
        report.put("readers",readers); report.put("checkedCalls",calls); report.put("failedCalls",0);
        report.put("elapsedSeconds",elapsed); report.put("callsPerSecond",calls/elapsed);
        report.put("p50Millis",percentile(timings,0.50)); report.put("p95Millis",percentile(timings,0.95));
        report.put("p99Millis",percentile(timings,0.99));
        Path directory=Path.of("..", ".codex-tmp", "platform-audit-20260907").toAbsolutePath().normalize();
        Files.createDirectories(directory);
        json.writerWithDefaultPrettyPrinter().writeValue(directory.resolve("sales-money-pressure-"+orderCount+".json").toFile(),report);
        System.out.println("SALES_MONEY_PRESSURE "+json.writeValueAsString(report));
    }

    private void verify(UUID order) {
        var value=summary.salesOrderSummary(order);
        assertThat(value.positionComplete()).isTrue();
        assertThat(value.netReceivableOriginal()).isEqualTo("50.0000");
        assertThat(value.unrecognizedOrderOriginal()).isEqualTo("150.0000");
        assertThat(value.plannedRemainingOriginal()).isEqualTo("200.0000");
    }

    private void waitForMeasurementWindow(int orders) throws Exception {
        String configured=System.getProperty("uten.sales.pressure.measurementGate", "");
        if (configured.isBlank()) return;
        Path gate=Path.of(configured).toAbsolutePath().normalize();
        if (Files.exists(gate)) throw new IllegalStateException("Use a fresh measurement gate, not an old approval file");
        Files.writeString(Path.of(gate+".ready"),"Fixture prepared: "+orders+" orders; waiting for an exclusive measurement window before correctness warmup and timing\n");
        System.out.println("SALES_MONEY_PRESSURE_DATA_READY orders="+orders);
        long deadline=System.nanoTime()+java.time.Duration.ofMinutes(30).toNanos();
        while (!Files.isRegularFile(gate)) {
            if (System.nanoTime()>deadline) throw new IllegalStateException("Exclusive measurement window was not released within 30 minutes");
            Thread.sleep(100);
        }
    }

    private void seedRows(String stage, String sql, Map<String,Object> parameters) {
        int count=((Number)parameters.get("count")).intValue();
        // Keep real triggers and constraints, with bounded transactions like a
        // document batch. Large-history identifier lookups are indexed by V501;
        // setup timings are deliberately excluded from query throughput.
        for (int first=1;first<=count;first+=500) {
            parameters.put("first",first);
            parameters.put("last",Math.min(count,first+499));
            parameters.put("stage",stage);
            parameters.put("sqlHash",sha256(sql));
            seedTransactions.executeWithoutResult(transaction -> {
                var hashes=jdbc.queryForList("SELECT sql_hash FROM audit_pressure.seed_batches WHERE fixture_id='sales-money-v2' AND stage=:stage AND first_row=:first",parameters,String.class);
                if (!hashes.isEmpty()) {
                    if (!hashes.getFirst().equals(parameters.get("sqlHash"))) throw new IllegalStateException("Fixture SQL changed; create a new isolated database");
                    return;
                }
                int inserted=jdbc.update(sql,parameters);
                int expected=((Number)parameters.get("last")).intValue()-((Number)parameters.get("first")).intValue()+1;
                if (inserted!=expected) throw new IllegalStateException("Incomplete synthetic fixture batch");
                jdbc.update("INSERT INTO audit_pressure.seed_batches(fixture_id,stage,first_row,last_row,sql_hash) VALUES('sales-money-v2',:stage,:first,:last,:sqlHash)",parameters);
                committedBatches++;
            });
            int stopAfter=Integer.getInteger("uten.sales.pressure.stopAfterBatches",0);
            if (stopAfter>0 && committedBatches>=stopAfter) {
                throw new IllegalStateException("INTENTIONAL_PRESSURE_PREPARATION_INTERRUPTION after committed batches="+committedBatches);
            }
            if (first==1 || (first-1)%25_000==0 || ((Number)parameters.get("last")).intValue()==count) {
                System.out.println("SALES_MONEY_PRESSURE_SEED stage="+stage+" through="+parameters.get("last")+"/"+count);
            }
        }
    }

    private static String sha256(String value) {
        try { return java.util.HexFormat.of().formatHex(java.security.MessageDigest.getInstance("SHA-256")
                .digest(value.getBytes(java.nio.charset.StandardCharsets.UTF_8))); }
        catch (java.security.NoSuchAlgorithmException failure) { throw new IllegalStateException(failure); }
    }

    private List<UUID> seed(int count) {
        jdbc.getJdbcTemplate().execute("CREATE SCHEMA IF NOT EXISTS audit_pressure");
        jdbc.getJdbcTemplate().execute("""
                CREATE TABLE IF NOT EXISTS audit_pressure.fixtures(
                    fixture_id text PRIMARY KEY, order_count integer NOT NULL, salt text NOT NULL,
                    client_id uuid NOT NULL,currency_id uuid NOT NULL,goods_id uuid NOT NULL,warehouse_id uuid NOT NULL,
                    actor_id uuid NOT NULL, created_at timestamptz NOT NULL DEFAULT now())
                """);
        jdbc.getJdbcTemplate().execute("""
                CREATE TABLE IF NOT EXISTS audit_pressure.seed_batches(
                    fixture_id text NOT NULL REFERENCES audit_pressure.fixtures(fixture_id),stage text NOT NULL,
                    first_row integer NOT NULL,last_row integer NOT NULL,sql_hash text NOT NULL,
                    completed_at timestamptz NOT NULL DEFAULT now(),PRIMARY KEY(fixture_id,stage,first_row))
                """);
        Map<String,Object> p=new LinkedHashMap<>();
        p.put("salt",UUID.randomUUID().toString()); p.put("count",count);
        for (String key:List.of("client","currency","goods","warehouse")) p.put(key,UUID.randomUUID());
        p.put("actor",jdbc.getJdbcTemplate().queryForObject("SELECT employee_id FROM users WHERE is_super_admin AND employee_id IS NOT NULL LIMIT 1",UUID.class));
        seedTransactions.executeWithoutResult(transaction -> {
        var existing=jdbc.getJdbcTemplate().queryForList("SELECT * FROM audit_pressure.fixtures WHERE fixture_id='sales-money-v2'");
        if (!existing.isEmpty()) {
            var fixture=existing.getFirst();
            if (((Number)fixture.get("order_count")).intValue()!=count) throw new IllegalStateException("Fixture scale differs; create a new isolated database");
            p.put("salt",fixture.get("salt")); p.put("actor",fixture.get("actor_id"));
            for(String key:List.of("client","currency","goods","warehouse")) p.put(key,fixture.get(key+"_id"));
            return;
        }
        jdbc.update("INSERT INTO audit_pressure.fixtures(fixture_id,order_count,salt,client_id,currency_id,goods_id,warehouse_id,actor_id) VALUES('sales-money-v2',:count,:salt,:client,:currency,:goods,:warehouse,:actor)",p);
        jdbc.update("INSERT INTO clients(id,code,name,status,code_sequence,sales_payment_type) VALUES(:client,'CLIENT-'||:salt,'Pressure customer','使用',100000,'MONTHLY')",p);
        jdbc.update("INSERT INTO currencies(id,code,name,exchange_rate,status) VALUES(:currency,'PRESSURE-CNY','Pressure currency',1,'使用')",p);
        jdbc.update("INSERT INTO goods(id,code,name,status,code_sequence) VALUES(:goods,'GOODS-'||:salt,'Pressure goods','使用',100000)",p);
        jdbc.update("INSERT INTO warehouses(id,code,name) VALUES(:warehouse,'PRESSURE-WH','Pressure warehouse')",p);
        });
        String series=" FROM generate_series(:first,:last) AS sample(n)";
        seedRows("orders","""
                INSERT INTO sales_orders(id,bill_no,bill_date,client_id,currency_id,total_original,total_local,
                    status,finance_confirmed,finance_confirmed_at,finance_confirmed_by,shipment_policy)
                SELECT md5(:salt||'-order-'||n)::uuid,'XD20260907'||lpad(n::text,6,'0'),DATE '2026-09-07',
                    :client,:currency,200,200,1,TRUE,now(),:actor,'ALLOW_PARTIAL'
                """+series,p);
        seedRows("order-items","""
                INSERT INTO sales_order_items(id,order_id,bill_no,bill_date,goods_id,qty,price,amount_original,
                    shipped_qty,returned_qty,flag_qty,goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,goods_snapshot_locked_at)
                SELECT md5(:salt||'-order-line-'||n)::uuid,md5(:salt||'-order-'||n)::uuid,
                    'XD20260907'||lpad(n::text,6,'0'),DATE '2026-09-07',:goods,20,10,200,10,5,0,
                    'PRESSURE','Pressure goods','MASTER_AT_APPROVAL',now()
                """+series,p);
        seedRows("shipments","""
                INSERT INTO sales_shipments(id,bill_no,bill_date,client_id,currency_id,warehouse_id,exchange_rate,tax_rate,
                    status,warehouse_work_status,finance_gate_version,finance_audit,finance_auditor_id,finance_audited_at,
                    handed_over_at,ar_posted,total_original,total_local)
                SELECT md5(:salt||'-ship-'||n)::uuid,'XC20260907'||lpad(n::text,6,'0'),DATE '2026-09-07',
                    :client,:currency,:warehouse,1,0,1,'SHIPPED',1,1,:actor,now(),now(),TRUE,100,100
                """+series,p);
        seedRows("shipment-items","""
                INSERT INTO sales_shipment_items(id,shipment_id,order_item_id,bill_no,bill_date,goods_id,qty,price,
                    amount_original,amount_local,goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,goods_snapshot_locked_at)
                SELECT md5(:salt||'-ship-line-'||n)::uuid,md5(:salt||'-ship-'||n)::uuid,md5(:salt||'-order-line-'||n)::uuid,
                    'XC20260907'||lpad(n::text,6,'0'),DATE '2026-09-07',:goods,10,10,100,100,
                    'PRESSURE','Pressure goods','MASTER_AT_APPROVAL',now()
                """+series,p);
        seedRows("returns","""
                INSERT INTO sales_returns(id,bill_no,bill_date,client_id,currency_id,warehouse_id,exchange_rate,tax_rate,
                    status,ar_posted,source_shipment_id,total_original,total_local)
                SELECT md5(:salt||'-return-'||n)::uuid,'XT20260907'||lpad(n::text,6,'0'),DATE '2026-09-07',
                    :client,:currency,:warehouse,1,0,1,TRUE,md5(:salt||'-ship-'||n)::uuid,50,50
                """+series,p);
        seedRows("return-items","""
                INSERT INTO sales_return_items(id,return_id,out_item_id,order_item_id,bill_no,bill_date,goods_id,qty,
                    price,amount_original,amount_local,goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,goods_snapshot_locked_at)
                SELECT md5(:salt||'-return-line-'||n)::uuid,md5(:salt||'-return-'||n)::uuid,md5(:salt||'-ship-line-'||n)::uuid,
                    md5(:salt||'-order-line-'||n)::uuid,'XT20260907'||lpad(n::text,6,'0'),DATE '2026-09-07',
                    :goods,5,10,50,50,'PRESSURE','Pressure goods','SHIPMENT_ITEM_AT_APPROVAL',now()
                """+series,p);
        for (String kind:List.of("ship","return")) {
            p.put("kind",kind); p.put("type",kind.equals("ship")?"SALES_SHIPMENT":"SALES_RETURN");
            p.put("prefix",kind.equals("ship")?"XC":"XT"); p.put("amount",kind.equals("ship")?100:-50);
            seedRows("ledger-"+kind,"""
                    INSERT INTO ar_ap_ledger(id,direction,source_doc_type,source_doc_id,source_doc_no,bill_no,bill_date,
                        client_id,currency_id,exchange_rate,amount_original,amount_original_local,amount_balance_original,
                        amount_balance,amount_received_original,amount_received_local,amount_write_off_original,amount_write_off_local,status)
                    SELECT md5(:salt||'-ar-'||:kind||'-'||n)::uuid,'AR',:type,md5(:salt||'-'||:kind||'-'||n)::uuid,
                        :prefix||'20260907'||lpad(n::text,6,'0'),:prefix||'20260907'||lpad(n::text,6,'0'),DATE '2026-09-07',
                        :client,:currency,1,:amount,:amount,:amount,:amount,0,0,0,0,1
                    """+series,p);
        }
        seedRows("source-refs","""
                INSERT INTO ar_ap_source_refs(id,ledger_id,source_type,source_id,source_no,source_sequence,amount_original,amount_local)
                SELECT md5(:salt||'-ref-'||n)::uuid,md5(:salt||'-ar-ship-'||n)::uuid,'SALES_ORDER',md5(:salt||'-order-'||n)::uuid,
                    'XD20260907'||lpad(n::text,6,'0'),1,100,100
                """+series,p);
        jdbc.getJdbcTemplate().execute("ANALYZE");
        var orders=jdbc.queryForList("SELECT id FROM sales_orders WHERE client_id=:client ORDER BY id",p,UUID.class);
        assertThat(orders).hasSize(count);
        for (String table:List.of("sales_shipments","sales_returns")) {
            assertThat(jdbc.queryForObject("SELECT count(*) FROM "+table+" WHERE client_id=:client",p,Integer.class)).isEqualTo(count);
        }
        assertThat(jdbc.queryForObject("SELECT count(*) FROM ar_ap_ledger WHERE client_id=:client",p,Integer.class)).isEqualTo(count*2);
        return orders;
    }

    private static double percentile(long[] values,double percentile) {
        return values[Math.max(0,(int)Math.ceil(values.length*percentile)-1)]/1_000_000d;
    }
}
