package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.*;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.*;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.*;
import java.util.function.Supplier;

import static org.junit.jupiter.api.Assertions.*;

/** Real PASS -> batch stock-in; timings never replace conservation and replay assertions. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false", "uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=false",
        "uten.inventory.value-work-initial-delay-ms=3600000"})
@Import(ProductionJdbcMeasurement.Configuration.class)
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners = WarehouseIqcBatchScalePostgresTest.Cleanup.class,
        mergeMode = TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class WarehouseIqcBatchScalePostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES = database();
    private static WarehouseIqcSnapshotSupport.Restored restored;
    private static final String SECRET = UUID.randomUUID()+"-"+UUID.randomUUID();
    private static PostgreSQLContainer<?> database() {
        var database = new PostgreSQLContainer<>("postgres:16-alpine")
                .withDatabaseName("uten_warehouse_iqc_scale").withUsername("uten_test").withPassword(UUID.randomUUID().toString());
        boolean company = "company".equals(System.getProperty("uten.warehouse.scale.databaseProfile"));
        database.withSharedMemorySize(1024L*1024*1024).withCommand("postgres",
                "-c", "shared_buffers="+(company?"4GB":"128MB"), "-c", "work_mem="+(company?"32MB":"4MB"),
                "-c", "effective_cache_size="+(company?"12GB":"4GB"), "-c", "max_connections="+(company?"200":"100"),
                "-c", "fsync=on", "-c", "synchronous_commit=on", "-c", "full_page_writes=on",
                "-c", "wal_buffers=16MB", "-c", "default_statistics_target=100");
        return database;
    }
    @DynamicPropertySource static void properties(DynamicPropertyRegistry registry) throws Exception {
        POSTGRES.start();
        restored=WarehouseIqcSnapshotSupport.restore(POSTGRES);
        Path attachments = Files.createTempDirectory("uten-warehouse-iqc-scale-");
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRES::getUsername);
        registry.add("spring.datasource.password", POSTGRES::getPassword);
        registry.add("uten.storage.local-dir", () -> attachments.toString());
        registry.add("uten.jwt.secret", () -> SECRET);
        registry.add("uten.crypto.pgp-master-key", () -> SECRET);
        registry.add("uten.crypto.hmac-key", () -> SECRET);
        registry.add("uten.bootstrap.admin-login", () -> "iqc-scale-bootstrap");
        registry.add("uten.bootstrap.admin-password", () -> SECRET+"Aa1!");
    }
    public static class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder() { return new DirtiesContextTestExecutionListener().getOrder()-1; }
        @Override public void afterTestClass(TestContext ignored) { POSTGRES.stop(); }
    }
    @Autowired JdbcTemplate jdbc;
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired ProcurementIqcStockInService stockIn;
    @Autowired com.uten.imp.features.stock.valuation.InventoryValueWorkService valueWork;
    @Autowired ObjectMapper json;
    @AfterEach void cleanup() { SecurityContextHolder.clearContext(); ProductionJdbcMeasurement.end(); }

    @Test
    void actualMixedBatchIsMeasuredAndConservesPhysicalValueApOwnershipAndReplay() throws Exception {
        assertTrue(jdbc.queryForObject("SELECT max(version::int) FROM flyway_schema_history",Integer.class)>=556,
                "This regression requires the database-enforced V556 classifier");
        Map<String,Object> environment = environment();
        emit(Map.of("phase","environment","configuration",environment));
        if(restored!=null)emit(Map.of("phase","input.restored","syntheticOnly",true,"sha256",restored.sha256(),
                "receipts",restored.receipts(),"itemsPerReceipt",restored.lines(),"preparationExcluded",true));
        int repetitions = Integer.getInteger("uten.warehouse.scale.runs",1);
        if (repetitions<1 || repetitions>5) throw new IllegalArgumentException("runs must be 1..5");
        if(restored!=null&&(repetitions!=1||!System.getProperty("uten.warehouse.scale.sizes","10,20").equals(Integer.toString(restored.receipts()))
                ||Integer.getInteger("uten.warehouse.scale.itemsPerReceipt",1)!=restored.lines()))
            throw new IllegalArgumentException("A restored checkpoint runs exactly its own batch shape once");
        var factory = new WarehouseIqcScaleFixture(beans,jdbc);
        for (String size : System.getProperty("uten.warehouse.scale.sizes","10,20").split(",")) {
            int count = Integer.parseInt(size);
            for (int run=1;run<=repetitions;run++) {
                String tag="iqcs-"+count+"-"+run+"-"+UUID.randomUUID().toString().substring(0,8);
                int itemsPerReceipt=Integer.getInteger("uten.warehouse.scale.itemsPerReceipt",1);
                if(itemsPerReceipt<1||itemsPerReceipt>100||count*itemsPerReceipt>300)throw new IllegalArgumentException("Illegal stock-in batch size");
                var scenario = restored!=null?restored.scenario():itemsPerReceipt==1 ? factory.prepare(count,tag)
                        : new WarehouseIqcMultiLineFixture(beans,jdbc).prepare(count,itemsPerReceipt,tag);
                int totalItems=count*itemsPerReceipt;
                BatchConfirmRequest request;
                if(restored==null)request=measure("quality.pass",count,run,() -> factory.passAll(scenario));
                else{
                    var actor=new FullChainEndToEndTest();beans.autowireBean(actor);actor.loginAs(scenario.confirmer());
                    request=restored.request();
                }
                WarehouseIqcSnapshotSupport.checkpoint(POSTGRES,json,scenario,request,count,itemsPerReceipt,run,"before-confirm");
                assertBalance(scenario,BigDecimal.ZERO,BigDecimal.ZERO,BigDecimal.ZERO,BigDecimal.ZERO);
                equalAmount(BigDecimal.ZERO,readyFinish(scenario),"PASS alone cannot make the analysis physically ready");
                assertEquals(0, jdbc.queryForObject("SELECT coalesce(sum(warehouse_stocked_base_qty),0) FROM procurement_inspection_items WHERE receipt_id=ANY(string_to_array(?,',')::uuid[])",BigDecimal.class,receiptIds(scenario)).signum());
                String apBefore = apDigest(scenario);
                BigDecimal expectedAp = WarehouseIqcScaleFixture.RECEIPT_QTY.multiply(BigDecimal.valueOf(totalItems)).multiply(new BigDecimal("50"));
                equalAmount(expectedAp,jdbc.queryForObject("SELECT coalesce(sum(amount_balance_original),0) FROM ar_ap_ledger WHERE source_doc_id=ANY(string_to_array(?,',')::uuid[])",BigDecimal.class,receiptIds(scenario)),"Receipt approval has posted each supplier fee once");
                long version = analysisVersion(scenario);
                // The final receipt is stale: preparation must reject the whole command before stock writes.
                var invalid = new ArrayList<>(request.batches());
                var last = invalid.getLast(); var line = last.items().getFirst();
                var staleItems=new ArrayList<>(last.items());
                staleItems.set(0,new ConfirmItem(line.passEventId(),line.baseQty(),line.expectedRemainingBaseQty().add(new BigDecimal("0.0001")),line.place()));
                invalid.set(invalid.size()-1,new BatchConfirmEntry(last.receiptType(),last.receiptId(),last.idempotencyKey(),
                        List.copyOf(staleItems)));
                String untouched = stateDigest(scenario);
                assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,() -> stockIn.batchConfirm(new BatchConfirmRequest(invalid))).getCode());
                assertEquals(untouched,stateDigest(scenario));

                var confirmed = measure("warehouse.batchConfirm",count,run,() -> {
                    try { return stockIn.batchConfirm(request); }
                    catch (RuntimeException failure) {
                        assertEquals(untouched,stateDigest(scenario),"A late stock-in failure must roll back the complete batch");
                        throw failure;
                    }
                });
                assertEquals(count,confirmed.confirmedReceipts()); assertEquals(totalItems,confirmed.confirmedItemCount());
                assertTrue(confirmed.results().stream().noneMatch(BatchConfirmEntryResult::replayed));
                assertEquals(version+1,analysisVersion(scenario),"All receipts touch the same analysis; exactly one real refresh/version write is required");
                equalAmount(scenario.requiredEach(),readyFinish(scenario),"The single refresh must include every actual qualified receipt");
                // Subcontract material cost is deliberately reconciled by the real
                // value worker. Never treat the immediate known fee as a final cost.
                BigDecimal knownBeforeSettlement=jdbc.queryForObject("SELECT coalesce(sum(amount_local),0) FROM stock_balances WHERE goods_id=ANY(string_to_array(?,',')::uuid[])",BigDecimal.class,goodsIds(scenario.subcontractGoods()));
                BigDecimal finalSubcontractValue=scenario.requiredEach().multiply(new BigDecimal("60")).multiply(BigDecimal.valueOf(scenario.subcontractGoods().size()));
                int pendingBeforeSettlement=jdbc.queryForObject("SELECT coalesce(sum(n.pending_parents),0)::int FROM stock_value_pools p JOIN stock_value_nodes n ON n.id=p.head_node_id WHERE p.goods_id=ANY(string_to_array(?,',')::uuid[])",Integer.class,goodsIds(scenario.subcontractGoods()));
                if(knownBeforeSettlement.compareTo(finalSubcontractValue)!=0) {
                    assertTrue(pendingBeforeSettlement>0,"A non-final known amount must retain explicit unresolved material-cost evidence");
                }
                equalAmount(scenario.requiredEach().multiply(BigDecimal.valueOf(scenario.subcontractGoods().size())),jdbc.queryForObject("SELECT coalesce(sum(qty_base),0) FROM subcontract_receipt_material_consumptions WHERE receipt_item_id IN(SELECT id FROM subcontract_receipt_items WHERE receipt_id=ANY(string_to_array(?,',')::uuid[])) AND reversal_of IS NULL",BigDecimal.class,receiptIds(scenario)),"Every subcontract return retains actual material-consumption provenance");
                equalAmount(scenario.requiredEach().multiply(BigDecimal.TEN).multiply(BigDecimal.valueOf(scenario.subcontractGoods().size())),jdbc.queryForObject("SELECT coalesce(sum(node.owned_value_local),0) FROM stock_value_production_cost_inputs input JOIN stock_value_nodes node ON node.id=input.input_node_id WHERE input.execution_segment_id IN(SELECT id FROM subcontract_receipt_items WHERE receipt_id=ANY(string_to_array(?,',')::uuid[])) AND input.input_kind='CONSUMED'",BigDecimal.class,receiptIds(scenario)),"Unsettled company material cost must remain in the actual cost inputs");
                emit(Map.of("phase","valuation.beforeSettlement","receipts",count,"run",run,
                        "knownSubcontractValue",knownBeforeSettlement.toPlainString(),"pendingParents",pendingBeforeSettlement));
                measure("valuation.settleAfterStockIn",count,run,() -> {
                    var operator=SecurityContextHolder.getContext();
                    SecurityContextHolder.clearContext();
                    try {
                        int work=0;
                        for(int cycle=0;cycle<100;cycle++) {
                            int changed=valueWork.runBatch();work+=changed;
                            if(!valueWork.hasPendingWork())return work;
                            if(changed==0)try{Thread.sleep(25);}catch(InterruptedException interrupted){
                                Thread.currentThread().interrupt();throw new AssertionError("Waiting for another value worker was interrupted",interrupted);
                            }
                        }
                        throw new AssertionError("Real value work did not converge within 100 batches");
                    } finally {
                        SecurityContextHolder.setContext(operator);
                    }
                });
                assertBalance(scenario,scenario.requiredEach(),scenario.requiredEach(),scenario.requiredEach().multiply(new BigDecimal("50")),scenario.requiredEach().multiply(new BigDecimal("60")));
                assertEquals(0,jdbc.queryForObject("SELECT coalesce(sum(n.pending_parents),0)::int FROM stock_value_pools p JOIN stock_value_nodes n ON n.id=p.head_node_id WHERE p.goods_id=ANY(string_to_array(?,',')::uuid[])",Integer.class,allGoodsIds(scenario)));
                assertEquals(totalItems/2,jdbc.queryForObject("SELECT count(*) FROM stock_value_production_cost_objects WHERE execution_segment_id IN(SELECT id FROM subcontract_receipt_items WHERE receipt_id=ANY(string_to_array(?,',')::uuid[])) AND state='FINAL' AND NOT business_refresh_pending",Integer.class,receiptIds(scenario)));
                assertEquals(apBefore,apDigest(scenario),"Warehouse confirmation cannot post supplier payable a second time");
                assertEquals(totalItems,jdbc.queryForObject("SELECT count(*) FROM procurement_iqc_stock_in_batch_items WHERE inspection_item_id IN(SELECT id FROM procurement_inspection_items WHERE receipt_id=ANY(string_to_array(?,',')::uuid[]))",Integer.class,receiptIds(scenario)));
                assertEquals(totalItems,jdbc.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_id=ANY(string_to_array(?,',')::uuid[])",Integer.class,receiptIds(scenario)));
                assertEquals(0,jdbc.queryForObject("SELECT count(*) FROM procurement_inspection_items WHERE receipt_id=ANY(string_to_array(?,',')::uuid[]) AND warehouse_stocked_base_qty<>passed_base_qty",Integer.class,receiptIds(scenario)));
                equalAmount(scenario.requiredEach().multiply(BigDecimal.valueOf(scenario.purchaseGoods().size())),jdbc.queryForObject("SELECT coalesce(sum(balance.effective_qty),0) FROM v_preplan_stock_entitlement_beneficiary_balance balance JOIN stock_reservations reservation ON reservation.id=balance.stock_reservation_id WHERE balance.beneficiary_analysis_id=? AND reservation.goods_id=ANY(string_to_array(?,',')::uuid[])",BigDecimal.class,scenario.analysisId(),goodsIds(scenario.purchaseGoods())),"Purchase provenance remains owned by the exact analysis");

                String stable = stateDigest(scenario);
                var replay = measure("warehouse.batchConfirm.replay",count,run,() -> stockIn.batchConfirm(request));
                assertTrue(replay.results().stream().allMatch(BatchConfirmEntryResult::replayed));
                assertEquals(confirmed.results().stream().map(BatchConfirmEntryResult::batchId).toList(),replay.results().stream().map(BatchConfirmEntryResult::batchId).toList());
                assertEquals(stable,stateDigest(scenario),"Replay cannot duplicate quantity, value, AP, analysis or source entitlement");
                Map<String,Object> verified=new LinkedHashMap<>();
                verified.putAll(Map.of("phase","verified","receipts",count,"run",run,"analysisRefreshes",1,"physicalLeaves",2,
                        "requiredQtyPerSku",scenario.requiredEach().toPlainString(),"purchaseUnitCost","50","subcontractUnitCost","60","replayUnchanged",true));
                verified.put("itemsPerReceipt",itemsPerReceipt);verified.put("totalItems",totalItems);
                verified.put("purchaseSkuCount",scenario.purchaseGoods().size());verified.put("subcontractSkuCount",scenario.subcontractGoods().size());
                emit(verified);
                WarehouseIqcSnapshotSupport.checkpoint(POSTGRES,json,scenario,request,count,itemsPerReceipt,run,"after-verified");
            }
        }
    }

    private <T> T measure(String phase,int size,int run,Supplier<T> operation) throws Exception {
        var sample=ProductionJdbcMeasurement.begin(); long start=System.nanoTime(); long gcBefore=gcMillis();
        try {
            T result=operation.get();
            Map<String,Object> record=new LinkedHashMap<>(sample.result());
            record.put("phase",phase);record.put("receipts",size);record.put("run",run);
            record.put("itemsPerReceipt",Integer.getInteger("uten.warehouse.scale.itemsPerReceipt",1));
            record.put("totalItems",size*Integer.getInteger("uten.warehouse.scale.itemsPerReceipt",1));
            record.put("wallMillis",(System.nanoTime()-start)/1_000_000.0);record.put("gcMillis",gcMillis()-gcBefore);
            record.put("maxHeapBytes",Runtime.getRuntime().maxMemory());record.put("usedHeapBytes",Runtime.getRuntime().totalMemory()-Runtime.getRuntime().freeMemory());
            record.put("status","completed");
            record.put("queryRelations",WarehouseIqcSqlRelations.forSample(sample));
            WarehouseIqcSnapshotSupport.sqlShapes(json,sample,phase,size,Integer.getInteger("uten.warehouse.scale.itemsPerReceipt",1),run);
            emit(record); return result;
        } catch (RuntimeException | Error failure) {
            Map<String,Object> record=new LinkedHashMap<>(sample.result());
            record.put("phase",phase);record.put("receipts",size);record.put("run",run);
            record.put("itemsPerReceipt",Integer.getInteger("uten.warehouse.scale.itemsPerReceipt",1));
            record.put("totalItems",size*Integer.getInteger("uten.warehouse.scale.itemsPerReceipt",1));
            record.put("wallMillis",(System.nanoTime()-start)/1_000_000.0);record.put("status","failed");
            record.put("errorType",failure.getClass().getSimpleName());
            try { emit(record); } catch (Exception outputFailure) { failure.addSuppressed(outputFailure); }
            throw failure;
        } finally { ProductionJdbcMeasurement.end(); }
    }
    private void assertBalance(WarehouseIqcScaleFixture.Scenario s,BigDecimal purchase,BigDecimal subcontract,BigDecimal purchaseValue,BigDecimal subcontractValue) {
        List<UUID> allGoods=new ArrayList<>(s.purchaseGoods());allGoods.addAll(s.subcontractGoods());
        for (var goods : allGoods) {
            BigDecimal qty=s.purchaseGoods().contains(goods)?purchase:subcontract;
            BigDecimal amount=s.purchaseGoods().contains(goods)?purchaseValue:subcontractValue;
            equalAmount(qty,jdbc.queryForObject("SELECT coalesce(sum(qty),0) FROM stock_balances WHERE goods_id=?",BigDecimal.class,goods),"Physical total");
            equalAmount(amount,jdbc.queryForObject("SELECT coalesce(sum(amount_local),0) FROM stock_balances WHERE goods_id=?",BigDecimal.class,goods),"Inventory amount");
            equalAmount(amount,jdbc.queryForObject("SELECT coalesce(sum(n.owned_value_local),0) FROM stock_value_pools p JOIN stock_value_nodes n ON n.id=p.head_node_id WHERE p.goods_id=?",BigDecimal.class,goods),"Authoritative value heads");
            for(UUID leaf:s.leaves()) {
                long receiptCount=s.receipts().stream().filter(r->r.goodsId().equals(goods)&&r.warehouseId().equals(leaf)).count();
                BigDecimal leafQty=qty.signum()==0?BigDecimal.ZERO:WarehouseIqcScaleFixture.RECEIPT_QTY.multiply(BigDecimal.valueOf(receiptCount));
                equalAmount(leafQty,jdbc.queryForObject("SELECT coalesce(sum(qty),0) FROM stock_balances WHERE goods_id=? AND warehouse_id=?",BigDecimal.class,goods,leaf),"Actual leaf quantity");
                BigDecimal unitCost=s.purchaseGoods().contains(goods)?new BigDecimal("50"):new BigDecimal("60");
                equalAmount(leafQty.multiply(unitCost),jdbc.queryForObject("SELECT coalesce(sum(amount_local),0) FROM stock_balances WHERE goods_id=? AND warehouse_id=?",BigDecimal.class,goods,leaf),"Actual leaf value");
            }
        }
    }
    private long analysisVersion(WarehouseIqcScaleFixture.Scenario s) { return jdbc.queryForObject("SELECT version FROM production_material_analyses WHERE id=?",Long.class,s.analysisId()); }
    private BigDecimal readyFinish(WarehouseIqcScaleFixture.Scenario s) { return jdbc.queryForObject("SELECT ready_finish_qty FROM production_material_analysis_items WHERE analysis_id=?",BigDecimal.class,s.analysisId()); }
    private String apDigest(WarehouseIqcScaleFixture.Scenario s) { return jdbc.queryForObject("SELECT md5(coalesce(string_agg(to_jsonb(t)::text,',' ORDER BY id),'')) FROM ar_ap_ledger t WHERE source_doc_id=ANY(string_to_array(?,',')::uuid[])",String.class,receiptIds(s)); }
    private String stateDigest(WarehouseIqcScaleFixture.Scenario s) {
        List<String> parts=new ArrayList<>();parts.add(apDigest(s));parts.add(Long.toString(analysisVersion(s)));
        for(String table:List.of("procurement_iqc_stock_in_batches","stock_movements"))parts.add(jdbc.queryForObject("SELECT md5(coalesce(string_agg(to_jsonb(t)::text,',' ORDER BY id),'')) FROM "+table+" t WHERE "+(table.equals("stock_movements")?"source_doc_id":"receipt_id")+"=ANY(string_to_array(?,',')::uuid[])",String.class,receiptIds(s)));
        for(String table:List.of("stock_balances","stock_value_pools","stock_reservations"))parts.add(jdbc.queryForObject("SELECT md5(coalesce(string_agg(to_jsonb(t)::text,',' ORDER BY id),'')) FROM "+table+" t WHERE goods_id=ANY(string_to_array(?,',')::uuid[])",String.class,allGoodsIds(s)));
        parts.add(jdbc.queryForObject("SELECT md5(coalesce(string_agg(to_jsonb(t)::text,',' ORDER BY id),'')) FROM stock_value_nodes t WHERE pool_id IN(SELECT id FROM stock_value_pools WHERE goods_id=ANY(string_to_array(?,',')::uuid[]))",String.class,allGoodsIds(s)));
        return String.join("|",parts);
    }
    private static String receiptIds(WarehouseIqcScaleFixture.Scenario s) { return s.receipts().stream().map(r->r.id().toString()).distinct().collect(java.util.stream.Collectors.joining(",")); }
    private static String goodsIds(List<UUID> ids) { return ids.stream().map(UUID::toString).collect(java.util.stream.Collectors.joining(",")); }
    private static String allGoodsIds(WarehouseIqcScaleFixture.Scenario s) { List<UUID> ids=new ArrayList<>(s.purchaseGoods());ids.addAll(s.subcontractGoods());return goodsIds(ids); }
    private static void equalAmount(BigDecimal expected,BigDecimal actual,String message) { assertEquals(0,expected.compareTo(actual),message+": expected="+expected+", actual="+actual); }
    private Map<String,Object> environment() {
        Map<String,Object> values=new LinkedHashMap<>();
        for(String key:List.of("server_version","shared_buffers","work_mem","effective_cache_size","max_connections","fsync","synchronous_commit","full_page_writes","wal_buffers","default_statistics_target","jit"))values.put(key,jdbc.queryForObject("SHOW "+key,String.class));
        values.put("maxHeapBytes",Runtime.getRuntime().maxMemory());values.put("migrationHead",jdbc.queryForObject("SELECT max(version::int) FROM flyway_schema_history",Integer.class));values.put("migrationCount",jdbc.queryForObject("SELECT count(*) FROM flyway_schema_history",Integer.class));return values;
    }
    private static long gcMillis() { return java.lang.management.ManagementFactory.getGarbageCollectorMXBeans().stream().mapToLong(b->Math.max(0,b.getCollectionTime())).sum(); }
    private void emit(Map<String,Object> record) throws Exception {
        Path path=Path.of(System.getProperty("uten.warehouse.scale.output","target/warehouse-iqc-scale.jsonl"));
        Files.createDirectories(path.toAbsolutePath().getParent());Files.writeString(path,json.writeValueAsString(record)+System.lineSeparator(),StandardOpenOption.CREATE,StandardOpenOption.APPEND);
    }
}
