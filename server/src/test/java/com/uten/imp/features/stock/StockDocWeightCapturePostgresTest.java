package com.uten.imp.features.stock;

import com.uten.imp.testsupport.FixtureDatabaseProperties;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.auth.PermissionResolver;
import com.uten.imp.features.stock.dto.StockBalanceAdjustmentRequest;
import com.uten.imp.features.stock.dto.StockDocDetail;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.features.stock.weight.StockWeightAdjustmentService;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.assertThrows;

/**
 * ADR-135 仓库单据称重采集的真实库全链路: 其它入库实称 -> 流水 MEASURED + 余额重量 + 其它入库观测(带供应商);
 * 盘点(盘盈盘亏为 0)带实盘重量 -> 盘点定重 + 盘点观测, 红冲 -> 撤销定重 + 观测已红冲; 保存后账面重量变化 -> 审核拒绝;
 * 授权调整只改重量 -> 盘点定重(授权调整)且不进学习; 其它出库实称 -> 核对观测, 红冲按原流水镜像;
 * 按重量计的货品丢弃客户端重量(精确换算), 不能填实盘重量。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(
        webEnvironment = SpringBootTest.WebEnvironment.MOCK,
        properties = {
                "spring.profiles.active=dev",
                "uten.audit.retention.enabled=false",
                "uten.reporting.materialized-view-refresh.enabled=false",
                "uten.production.readiness-reconcile.enabled=false",
                "uten.policy-intelligence.enabled=false",
                "uten.features.goods-owner-scope-enabled=false",
                "uten.jwt.secret=stock-weight-capture-harness-jwt-secret-0123456789-test-only",
                "uten.crypto.pgp-master-key=stock-weight-capture-harness-pgp-key-test-only-012345",
                "uten.crypto.hmac-key=stock-weight-capture-harness-hmac-key-test-only",
                "uten.bootstrap.admin-login=stock-weight-capture-bootstrap-admin-test",
                "uten.bootstrap.admin-password=StockWeightCaptureAdminPass-1!"
        })
class StockDocWeightCapturePostgresTest {

    private static final PostgreSQLContainer POSTGRES =
            new PostgreSQLContainer("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("fixture_admin")
                    .withPassword("uten");

    @DynamicPropertySource
    static void registerDataSource(DynamicPropertyRegistry registry) {
        POSTGRES.start();
        FixtureDatabaseProperties.bindSameRole(registry, POSTGRES::getJdbcUrl,
                POSTGRES::getUsername, POSTGRES::getPassword);
    }

    @Autowired private JdbcTemplate jdbc;
    @Autowired private PermissionResolver permissions;
    @Autowired private StockDocService stockDocs;
    @Autowired private StockBalanceAdjustmentService balanceAdjustments;
    @Autowired private StockWeightAdjustmentService weightAdjustments;
    @Autowired private com.uten.imp.features.stock.weight.GoodsWeightProfileService weightProfiles;

    @AfterEach
    void clearPrincipal() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void explicitWeightChoiceKeepsPrivateOriginalOperandsAndOnlyMetadataReachesGeneralAudit() throws Exception {
        Fixture f=fixture("raw-proof");String original="1.123456789012345678901234567",recorded="1.123456789012345678901234";
        StockDocSaveRequest incoming=document("OTHER_IN",f);StockDocItemLine input=line(f.goods(),f.unit(),"1",original);
        input.setPrice(BigDecimal.ONE);input.setAmountOriginal(BigDecimal.ONE);input.setAmountLocal(BigDecimal.ONE);incoming.setItems(List.of(input));
        assertThrows(com.uten.imp.common.finance.BusinessPrecisionRequiredException.class,()->stockDocs.create(incoming));
        assertEquals(0,count("SELECT count(*) FROM stock_documents WHERE warehouse_id=?",f.warehouse()));
        assertEquals(0,count("SELECT count(*) FROM business_numeric_input_evidence WHERE actor_id=?",f.user()));
        try(var chosen=com.uten.imp.common.finance.BusinessPrecisionContext.use(Map.of("weight.kg-field",new com.uten.imp.common.finance.BusinessPrecisionContext.Choice(24,"DOWN"),"weight.to-kg",new com.uten.imp.common.finance.BusinessPrecisionContext.Choice(24,"DOWN")))){
            StockDocDetail saved=stockDocs.create(incoming);var item=saved.getItems().getFirst();
            assertThat(item.getWeightExact()).isEqualTo(recorded);assertEquals(1,item.getWeightInputEvidence().size());
            var evidence=item.getWeightInputEvidence().getFirst();assertEquals(original,evidence.originalDecimal());assertEquals(recorded,evidence.recordedDecimal());
            assertEquals("KG",evidence.originalUnit().code());assertEquals(f.user(),evidence.actorId());assertEquals(24,evidence.usedPolicy().get("weight.kg-field").scale());
            String redacted=jdbc.queryForObject("SELECT fn_audit_redact_row('business_numeric_input_evidence',to_jsonb(evidence))::text FROM business_numeric_input_evidence evidence WHERE evidence.id=?",String.class,evidence.id());
            var fields=new com.fasterxml.jackson.databind.ObjectMapper().readTree(redacted);
            assertTrue(fields.has("id"));assertTrue(fields.has("actor_id"));assertFalse(fields.has("original_decimal"));assertFalse(fields.has("recorded_decimal"));assertFalse(fields.has("precision_policy"));assertFalse(fields.has("original_unit"));
            assertThrows(org.springframework.dao.DataAccessException.class,()->jdbc.update("UPDATE business_numeric_input_evidence SET original_decimal='9' WHERE id=?",evidence.id()));
            assertThrows(org.springframework.dao.DataAccessException.class,()->jdbc.update("DELETE FROM business_numeric_input_evidence WHERE id=?",evidence.id()));
            assertThrows(org.springframework.dao.DataAccessException.class,()->jdbc.execute("TRUNCATE business_numeric_input_evidence"));
            var sample=new com.uten.imp.features.stock.weight.dto.WeightSampleRequest(new BigDecimal("2"),new BigDecimal("1000.123456789012345678901234"),"G",null,f.supplier(),f.warehouse(),false,"原数证据测试","raw-sample-"+UUID.randomUUID());
            weightProfiles.recordSample(f.goods(),sample);weightProfiles.recordSample(f.goods(),sample);
            assertEquals(1,count("SELECT count(*) FROM business_numeric_input_evidence WHERE owner_kind='GOODS_WEIGHT_OBSERVATION' AND owner_id=? AND field_key='WEIGHT_KG'",f.goods()));
            Map<String,Object> sampleRaw=jdbc.queryForMap("SELECT original_decimal,original_unit->>'code' unit,recorded_decimal FROM business_numeric_input_evidence WHERE owner_kind='GOODS_WEIGHT_OBSERVATION' AND owner_id=?",f.goods());
            assertEquals("1000.123456789012345678901234",sampleRaw.get("original_decimal"));assertEquals("G",sampleRaw.get("unit"));assertEquals("1.000123456789012345678901",sampleRaw.get("recorded_decimal"));
            var update=new com.uten.imp.features.stock.weight.dto.WeightProfileUpdateRequest(0L,new BigDecimal("0.123456789012345678901234567"),null,null,null,null,true,"AUTO");
            var profile=weightProfiles.updateProfile(f.goods(),update).profile();assertEquals(1,profile.inputEvidence().size());
            assertEquals("0.123456789012345678901234567",profile.inputEvidence().getFirst().originalDecimal());
            assertEquals(1,weightProfiles.updateProfile(f.goods(),update).profile().version());
            assertEquals(1,count("SELECT count(*) FROM business_numeric_input_evidence WHERE owner_kind='GOODS_WEIGHT_PROFILE' AND owner_id=?",f.goods()));
        }
    }

    @Test
    void exactScaleReadingCountSampleAndProfileReplayKeepAllDigitsWithoutDuplicateEffects(){
        Fixture f=fixture("exact");String original="1.123456789012345678901234";
        StockDocSaveRequest inbound=document("OTHER_IN",f);StockDocItemLine item=line(f.goods(),f.unit(),"2",original);
        item.setPrice(BigDecimal.ONE);item.setAmountOriginal(new BigDecimal("2"));item.setAmountLocal(new BigDecimal("2"));inbound.setItems(List.of(item));
        StockDocDetail created=stockDocs.approve(stockDocs.create(inbound).getId());
        assertThat(created.getItems().getFirst().getWeightExact()).isEqualTo(original);
        assertMovement(created.getId(),original,"MEASURED");assertBalance(f,"2",original,false);
        var sample=new com.uten.imp.features.stock.weight.dto.WeightSampleRequest(new BigDecimal("2"),new BigDecimal(original),"KG",null,f.supplier(),f.warehouse(),false,"原读数高精度","weight-sample-"+UUID.randomUUID());
        weightProfiles.recordSample(f.goods(),sample);weightProfiles.recordSample(f.goods(),sample);
        assertEquals(1,count("SELECT count(*) FROM goods_weight_observations WHERE capture_key=?","SAMPLE:"+f.goods()+":"+sample.idempotencyKey()));
        assertThat((BigDecimal)jdbc.queryForMap("SELECT weight_kg FROM goods_weight_observations WHERE capture_key=?","SAMPLE:"+f.goods()+":"+sample.idempotencyKey()).get("weight_kg")).isEqualByComparingTo(original);
        var detail=weightProfiles.updateProfile(f.goods(),new com.uten.imp.features.stock.weight.dto.WeightProfileUpdateRequest(0L,new BigDecimal("0.000000000000000000000001"),null,null,null,null,true,"AUTO"));
        assertEquals(1,detail.profile().version());
        var replay=weightProfiles.updateProfile(f.goods(),new com.uten.imp.features.stock.weight.dto.WeightProfileUpdateRequest(0L,new BigDecimal("0.000000000000000000000001"),null,null,null,null,true,"AUTO"));
        assertEquals(1,replay.profile().version());
        assertThat(replay.profile().defaultTareKg()).isEqualByComparingTo("0.000000000000000000000001");
        StockDocSaveRequest outgoing=document("OTHER_OUT",f);outgoing.setItems(List.of(line(f.goods(),f.unit(),"2",original)));
        StockDocDetail out=stockDocs.approve(stockDocs.create(outgoing).getId());assertBalance(f,"0","0",false);
        stockDocs.reverse(out.getId());assertBalance(f,"2",original,false);
    }

    @Test
    void manualDocumentsCountsAndAuthorizedAdjustmentKeepWeightLedgerAndLearningInStep() {
        Fixture f = fixture("wc");

        // 1. 其它入库 100 个, 实称 25.5 kg: 流水实称, 余额重量已知, 登记其它入库观测(带供应商)。
        StockDocSaveRequest inbound = document("OTHER_IN", f);
        inbound.setSupplierId(f.supplier());
        StockDocItemLine inLine = line(f.goods(), f.unit(), "100", "25.5");
        inLine.setPrice(BigDecimal.ONE);
        inLine.setAmountOriginal(new BigDecimal("100"));
        inLine.setAmountLocal(new BigDecimal("100"));
        inbound.setItems(List.of(inLine));
        StockDocDetail in = stockDocs.approve(stockDocs.create(inbound).getId());
        UUID inItem = in.getItems().getFirst().getId();
        assertThat(in.getItems().getFirst().getWeight()).isEqualByComparingTo("25.5");
        assertMovement(in.getId(), "25.5", "MEASURED");
        assertBalance(f, "100", "25.5", false);
        Map<String, Object> inObservation = observation("OTHER_IN:" + inItem);
        assertEquals("REFERENCE", inObservation.get("role"));
        assertEquals(f.supplier(), inObservation.get("supplier_id"));
        assertThat((BigDecimal) inObservation.get("qty_base")).isEqualByComparingTo("100");
        assertThat((BigDecimal) inObservation.get("weight_kg")).isEqualByComparingTo("25.5");
        assertEquals("ACTIVE", inObservation.get("stage"));

        // 2. 盘点: 实盘 100 个(盘盈盘亏 0), 实盘重量 26 kg -> 没有数量流水, 盘点定重 25.5 -> 26, 余额重量 26 不再是估算。
        StockDocSaveRequest count = document("CHECK", f);
        StockDocItemLine countLine = line(f.goods(), f.unit(), "0", null);
        countLine.setCountQty(new BigDecimal("100"));
        countLine.setCountWeight(new BigDecimal("26"));
        count.setItems(List.of(countLine));
        StockDocDetail countDraft = stockDocs.create(count);
        assertThat(countDraft.getItems().getFirst().getBookWeight()).isEqualByComparingTo("25.5");
        assertThat(countDraft.getItems().getFirst().getCountWeight()).isEqualByComparingTo("26");
        StockDocDetail counted = stockDocs.approve(countDraft.getId());
        UUID countItem = counted.getItems().getFirst().getId();
        assertEquals(0, count("SELECT count(*) FROM stock_movements WHERE source_doc_id=?", counted.getId()));
        Map<String, Object> countRow = jdbc.queryForMap("""
                SELECT kind, weight_before, weight_after, reason FROM stock_weight_adjustments
                WHERE source_doc_id=? AND source_item_id=? AND kind='COUNT'
                """, counted.getId(), countItem);
        assertThat((BigDecimal) countRow.get("weight_before")).isEqualByComparingTo("25.5");
        assertThat((BigDecimal) countRow.get("weight_after")).isEqualByComparingTo("26");
        assertEquals("盘点", countRow.get("reason"));
        assertBalance(f, "100", "26", false);
        assertEquals("REFERENCE", observation("COUNT:" + countItem).get("role"));

        // 3. 盘点红冲: 撤销定重回到 25.5, 盘点观测标成已红冲。
        stockDocs.reverse(counted.getId());
        assertThat(jdbc.queryForObject("""
                SELECT weight_after FROM stock_weight_adjustments
                WHERE source_doc_id=? AND source_item_id=? AND kind='REVERSAL'
                """, BigDecimal.class, counted.getId(), countItem)).isEqualByComparingTo("25.5");
        assertBalance(f, "100", "25.5", false);
        assertEquals("REVERSED", observation("COUNT:" + countItem).get("stage"));

        // 4. 保存盘点单后有人核重, 账面重量变了: 带实盘重量的盘点不能按旧快照审核。
        StockDocSaveRequest stale = document("CHECK", f);
        StockDocItemLine staleLine = line(f.goods(), f.unit(), "0", null);
        staleLine.setCountQty(new BigDecimal("100"));
        staleLine.setCountWeight(new BigDecimal("24"));
        stale.setItems(List.of(staleLine));
        UUID staleId = stockDocs.create(stale).getId();
        weightAdjustments.setWeight(new StockWeightAdjustmentService.SetWeightCommand(
                StockWeightAdjustmentService.KIND_MANUAL, f.warehouse(), f.goods(), null, new BigDecimal("25"),
                new BigDecimal("25.5"), true, null, null, null, OffsetDateTime.now(), "复称核对", null, f.user()));
        ApiException staleFailure = assertThrows(ApiException.class, () -> stockDocs.approve(staleId));
        assertEquals(ErrorCode.CONFLICT, staleFailure.getCode());
        assertThat(staleFailure.getMessage()).contains("重量已变化");
        stockDocs.delete(staleId);

        // 5. 授权调整只改重量(数量不变): 记盘点定重(原因「授权调整」), 不登记称重观测。
        StockBalanceAdjustmentRequest adjust = new StockBalanceAdjustmentRequest();
        adjust.setIdempotencyKey("b1-weight-adjust-" + f.goods());
        adjust.setWarehouseId(f.warehouse());
        adjust.setGoodsId(f.goods());
        adjust.setExpectedQty(new BigDecimal("100"));
        adjust.setTargetQty(new BigDecimal("100"));
        adjust.setTargetWeightKg(new BigDecimal("27"));
        adjust.setReason("称重核对");
        var adjusted = balanceAdjustments.adjust(adjust);
        assertThat(adjusted.afterWeightKg()).isEqualByComparingTo("27");
        assertThat(adjusted.deltaQty()).isEqualByComparingTo("0");
        assertEquals("授权调整", jdbc.queryForObject(
                "SELECT reason FROM stock_weight_adjustments WHERE source_doc_id=? AND kind='COUNT'",
                String.class, adjusted.documentId()));
        assertEquals(0, count("SELECT count(*) FROM goods_weight_observations WHERE source_doc_id=?",
                adjusted.documentId()));
        assertBalance(f, "100", "27", false);
        assertEquals(adjusted.documentId(), balanceAdjustments.adjust(adjust).documentId(), "同键重放");

        // 6. 其它出库 10 个实称 2.6 kg -> 核对观测; 红冲按原流水镜像回 27, 观测已红冲。
        StockDocSaveRequest outbound = document("OTHER_OUT", f);
        outbound.setItems(List.of(line(f.goods(), f.unit(), "10", "2.6")));
        StockDocDetail out = stockDocs.approve(stockDocs.create(outbound).getId());
        UUID outItem = out.getItems().getFirst().getId();
        assertBalance(f, "90", "24.4", false);
        assertEquals("CHECK", observation("OTHER_OUT:" + outItem).get("role"));
        stockDocs.reverse(out.getId());
        assertBalance(f, "100", "27", false);
        assertEquals("REVERSED", observation("OTHER_OUT:" + outItem).get("stage"));
    }

    @Test
    void massUnitGoodsDropClientWeightAndRejectCountWeight() {
        Fixture f = fixture("wx");
        UUID kilogram = UUID.randomUUID();
        jdbc.update("INSERT INTO units(id, code, name, status) VALUES (?, ?, '千克', '使用')", kilogram, "KG-" + kilogram);
        jdbc.update("""
                INSERT INTO unit_measurement_profiles(unit_id, measurement_dimension, mass_unit_code, provenance)
                VALUES (?, 'MASS', 'KG', 'MANUAL_GOVERNANCE')
                """, kilogram);
        UUID rice = goods("RICE-" + kilogram, kilogram);

        StockDocSaveRequest inbound = document("OTHER_IN", f);
        inbound.setItems(List.of(line(rice, kilogram, "12", "5")));
        StockDocDetail in = stockDocs.approve(stockDocs.create(inbound).getId());
        assertThat(in.getItems().getFirst().getWeight()).as("按重量计的货品丢弃客户端重量").isNull();
        assertMovement(in.getId(), "12", "EXACT");
        assertEquals(0, count("SELECT count(*) FROM goods_weight_observations WHERE goods_id=?", rice));

        StockDocSaveRequest count = document("CHECK", f);
        StockDocItemLine countLine = line(rice, kilogram, "0", null);
        countLine.setCountQty(new BigDecimal("12"));
        countLine.setCountWeight(new BigDecimal("12.5"));
        count.setItems(List.of(countLine));
        ApiException rejected = assertThrows(ApiException.class, () -> stockDocs.create(count));
        assertEquals(ErrorCode.CONFLICT, rejected.getCode());
        assertThat(rejected.getMessage()).contains("按重量计的货品不用单独填重量");
    }

    private record Fixture(UUID warehouse, UUID goods, UUID unit, UUID supplier, UUID user) {
    }

    private Fixture fixture(String prefix) {
        String tag = prefix + "-" + UUID.randomUUID().toString().substring(0, 8);
        UUID department = UUID.randomUUID();
        UUID employee = UUID.randomUUID();
        UUID user = UUID.randomUUID();
        UUID warehouse = UUID.randomUUID();
        UUID unit = UUID.randomUUID();
        UUID supplier = UUID.randomUUID();
        jdbc.update("INSERT INTO departments(id, code, name, level) VALUES (?, ?, ?, '一级部门')",
                department, "DEPT-" + tag, "称重部门-" + tag);
        jdbc.update("""
                INSERT INTO employees(id, code, full_name, id_type, department_id, hire_date, status, employment_type)
                VALUES (?, ?, ?, '其他', ?, DATE '2026-01-01', 'active', 'regular')
                """, employee, "EMP-" + tag, "称重员-" + tag, department);
        jdbc.update("""
                INSERT INTO users(id, employee_id, login_account, password_hash, must_change_password, is_super_admin, status)
                VALUES (?, ?, ?, 'stub-not-used', false, true, 'active')
                """, user, employee, "SU-" + tag);
        jdbc.update("INSERT INTO warehouses(id, code, name, status) VALUES (?, ?, ?, '使用')",
                warehouse, "WH-" + tag, "称重仓-" + tag);
        jdbc.update("INSERT INTO units(id, code, name, status) VALUES (?, ?, '个', '使用')", unit, "PCS-" + tag);
        jdbc.update("""
                INSERT INTO suppliers(id, code, name, status, code_sequence)
                VALUES (?, ?, ?, '使用', (SELECT coalesce(max(code_sequence), 0) + 1 FROM suppliers))
                """, supplier, "SUP-" + tag, "称重供应商-" + tag);
        UUID goods = goods("G-" + tag, unit);
        var snapshot = permissions.authorizationSnapshot(user, employee, true);
        AuthUser principal = new AuthUser(user, employee, "SU-" + tag, snapshot.permissions(), false, true, true);
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(principal, null, principal.getAuthorities()));
        return new Fixture(warehouse, goods, unit, supplier, user);
    }

    private UUID goods(String code, UUID unit) {
        UUID id = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO goods(id, code, name, source_type, status, unit_id, price, code_sequence)
                VALUES (?, ?, ?, '采购', '使用', ?, 1, (SELECT coalesce(max(code_sequence), 0) + 1 FROM goods))
                """, id, code, "称重货品-" + code, unit);
        return id;
    }

    private static StockDocSaveRequest document(String type, Fixture f) {
        StockDocSaveRequest request = new StockDocSaveRequest();
        request.setDocType(type);
        request.setBillDate(BusinessTime.today());
        request.setWarehouseId(f.warehouse());
        return request;
    }

    private static StockDocItemLine line(UUID goods, UUID unit, String qty, String weightKg) {
        StockDocItemLine line = new StockDocItemLine();
        line.setGoodsId(goods);
        line.setUnitId(unit);
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));
        line.setWeight(weightKg == null ? null : new BigDecimal(weightKg));
        return line;
    }

    private void assertMovement(UUID document, String weightKg, String source) {
        Map<String, Object> row = jdbc.queryForMap(
                "SELECT weight, weight_source FROM stock_movements WHERE source_doc_id=? ORDER BY ledger_seq LIMIT 1",
                document);
        assertThat((BigDecimal) row.get("weight")).isEqualByComparingTo(weightKg);
        assertEquals(source, row.get("weight_source"));
    }

    private void assertBalance(Fixture f, String qty, String weightKg, boolean estimated) {
        Map<String, Object> row = jdbc.queryForMap(
                "SELECT qty, weight, weight_estimated FROM stock_balances WHERE warehouse_id=? AND goods_id=?",
                f.warehouse(), f.goods());
        assertThat((BigDecimal) row.get("qty")).isEqualByComparingTo(qty);
        assertThat((BigDecimal) row.get("weight")).isEqualByComparingTo(weightKg);
        assertEquals(estimated, row.get("weight_estimated"));
    }

    private Map<String, Object> observation(String captureKey) {
        return jdbc.queryForMap("""
                SELECT role, supplier_id, qty_base, weight_kg, stage FROM goods_weight_observations WHERE capture_key=?
                """, captureKey);
    }

    private int count(String sql, Object argument) {
        return jdbc.queryForObject(sql, Integer.class, argument);
    }
}
