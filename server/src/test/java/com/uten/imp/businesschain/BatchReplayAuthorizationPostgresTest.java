package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.quality.ProductionFqcContracts.PassAllBatchRequest;
import com.uten.imp.features.production.quality.ProductionFqcInspectionService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.FinishedInboundBatchConfirmRequest;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalLotRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.BatchArrivalRegistrationRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalRegistrationService;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.*;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialRequisitionService;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialScope;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialSettingsService;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.ThreadLocalRandom;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;

/** A stored result preserves facts, but never a former warehouse/workshop grant. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK, properties={
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false", "uten.production.readiness-reconcile.enabled=false",
        "uten.workshop-material.auto-close.enabled=false", "uten.inventory.value-work.enabled=false",
        "uten.policy-intelligence.enabled=false", "uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true", "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=batch-replay-harness-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=batch-replay-harness-pgp-key-test-only-0123456789",
        "uten.crypto.hmac-key=batch-replay-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=batch-replay-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class BatchReplayAuthorizationPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry properties) {
        FullChainEndToEndTest.registerDataSource(properties);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired StockDocService stock;
    @Autowired ProductionFinishedArrivalRegistrationService arrivals;
    @Autowired ProductionFqcInspectionService quality;
    @Autowired ProductionStockTaskAccessPolicy warehouseAccess;
    @Autowired WorkshopMaterialRequisitionService requisitions;
    @Autowired WorkshopMaterialSettingsService settings;
    @Autowired WorkshopMaterialScope workshopScope;

    @AfterEach void logout() { SecurityContextHolder.clearContext(); }

    @Test void finishedAcceptanceReplayKeepsSelectedResidualFactsButRechecksTheCurrentWarehouseRole() {
        var fixture = fixture();
        var world = fixture.seedWorld("batch-replay-finished-" + shortId());
        ReflectionTestUtils.invokeMethod(fixture,"receiveOpeningInputsForA",world,"20");
        Object report = ReflectionTestUtils.invokeMethod(fixture,"approvedMultiLineReportOfNewPlan",
                world,(Object)new String[]{"3","7"});
        UUID reportId = ReflectionTestUtils.invokeMethod(report,"id");
        fixture.loginAs(world.superAdminUserId());
        var lots = arrivals.batchDetail(List.of(reportId)).getFirst().lots();
        arrivals.batchRegister(new BatchArrivalRegistrationRequest("replay-arrival-"+reportId,
                lots.stream().map(lot->new ArrivalLotRequest(lot.lotId(),world.warehouseId(),"REPLAY",null,null)).toList(),null,false));
        quality.passAll(new PassAllBatchRequest(db.queryForList(
                "SELECT id FROM production_fqc_inspections WHERE source_report_id=? AND status='PENDING'",UUID.class,reportId),
                "replay-pass-"+reportId));
        UUID document = db.queryForObject("SELECT id FROM stock_documents WHERE source_daily_report_id=? AND doc_type='FINISHED_IN' AND status=0 AND NOT is_deleted",
                UUID.class,reportId);
        List<UUID> items = db.queryForList("SELECT id FROM stock_document_items WHERE doc_id=? AND NOT is_deleted ORDER BY qty,id",UUID.class,document);
        UUID actor = fixture.createUserWithPerms(world,"replay-final-"+shortId(),"stock_doc:view","stock_doc:approve");
        UUID employee = employee(actor);
        UUID warehouseDepartment = db.queryForObject("SELECT id FROM departments WHERE code='SUB_WH' AND NOT is_deleted",UUID.class);
        db.update("UPDATE employees SET department_id=? WHERE id=?",warehouseDepartment,employee);
        fixture.loginAs(actor);
        assertThat(warehouseAccess.canAccessWarehouseTasks()).isTrue();
        var command = new FinishedInboundBatchConfirmRequest();
        command.setIdempotencyKey("replay-finished-"+UUID.randomUUID());
        command.setDocumentIds(List.of(document));
        command.setItemIds(List.of(items.getFirst()));
        var first = stock.confirmFinishedInboundBatch(command);
        int movements = movementCount(document);
        String residual = db.queryForObject("SELECT jsonb_agg(to_jsonb(item) ORDER BY item.id)::text FROM stock_document_items item JOIN stock_documents document ON document.id=item.doc_id WHERE document.source_daily_report_id=? AND document.status=0 AND NOT document.is_deleted",String.class,reportId);
        assertThat(stock.confirmFinishedInboundBatch(command).items()).isEqualTo(first.items());
        assertThat(movementCount(document)).isEqualTo(movements);

        db.update("UPDATE employees SET department_id=? WHERE id=?",anotherWorkshop(fixture),employee);
        fixture.loginAs(actor);
        assertAuthority("stock_doc:approve");
        assertThat(warehouseAccess.canAccessWarehouseTasks()).isFalse();
        assertThat(assertThrows(ApiException.class,()->stock.confirmFinishedInboundBatch(command)).getCode()).isEqualTo(ErrorCode.NOT_FOUND);
        assertThat(movementCount(document)).isEqualTo(movements);
        assertThat(db.queryForObject("SELECT jsonb_agg(to_jsonb(item) ORDER BY item.id)::text FROM stock_document_items item JOIN stock_documents document ON document.id=item.doc_id WHERE document.source_daily_report_id=? AND document.status=0 AND NOT document.is_deleted",String.class,reportId)).isEqualTo(residual);
        assertThat(db.queryForObject("SELECT count(*) FROM production_finished_in_confirm_batches WHERE actor_user_id=? AND idempotency_key=?",Integer.class,actor,command.getIdempotencyKey())).isEqualTo(1);
    }

    @Test void fulfilledRequisitionReplayDoesNotReopenDoneOrReissueAndRejectsAFormerWorkshopGrant() {
        Shop shop = shop();
        shop.fixture().loginAs(shop.requester());
        var pending = requisitions.create(new RequisitionCreate("ISSUE",shop.workshop(),
                List.of(new RequisitionLineInput(shop.goods(),null,new BigDecimal("5"),null)),null,"replay-request-"+UUID.randomUUID()));
        shop.fixture().loginAs(shop.issuer());
        var command = new FulfilRequest(pending.rowVersion(),
                List.of(new FulfilLine(pending.lines().getFirst().id(),shop.leaf(),new BigDecimal("5"))),null,"replay-fulfil-"+UUID.randomUUID());
        var first = requisitions.fulfil(pending.id(),command);
        assertThat(first.status()).isEqualTo("DONE");
        UUID document = first.documents().getFirst().documentId();
        int movements = movementCount(document);
        assertThat(requisitions.fulfil(pending.id(),command).id()).isEqualTo(first.id());
        assertThat(movementCount(document)).isEqualTo(movements);
        db.update("UPDATE employees SET department_id=? WHERE id=?",anotherWorkshop(shop.fixture()),employee(shop.issuer()));
        shop.fixture().loginAs(shop.issuer());
        assertAuthority("workshop_material:issue");
        assertThat(workshopScope.canSee(shop.workshop())).isFalse();
        assertThat(assertThrows(ApiException.class,()->requisitions.fulfil(pending.id(),command)).getCode()).isEqualTo(ErrorCode.FORBIDDEN);
        assertThat(movementCount(document)).isEqualTo(movements);
        assertThat(commandCount(pending.id(),"REQUISITION_FULFIL")).isEqualTo(1);
    }

    @Test void cancelledRequisitionReplayRechecksScopeWithoutRequiringTheOldPendingVersion() {
        Shop shop = shop();
        shop.fixture().loginAs(shop.requester());
        var pending = requisitions.create(new RequisitionCreate("ISSUE",shop.workshop(),
                List.of(new RequisitionLineInput(shop.goods(),null,BigDecimal.ONE,null)),null,"replay-cancel-source-"+UUID.randomUUID()));
        var command = new CancelRequest(pending.rowVersion(),"本次撤回领料申请","replay-cancel-"+UUID.randomUUID());
        var first = requisitions.cancel(pending.id(),command);
        assertThat(first.status()).isEqualTo("CANCELLED");
        assertThat(requisitions.cancel(pending.id(),command).id()).isEqualTo(first.id());
        String snapshot = db.queryForObject("SELECT row_to_json(requisition)::text FROM workshop_material_requisitions requisition WHERE id=?",String.class,pending.id());
        db.update("UPDATE employees SET department_id=? WHERE id=?",anotherWorkshop(shop.fixture()),employee(shop.requester()));
        shop.fixture().loginAs(shop.requester());
        assertAuthority("workshop_material:request");
        assertThat(workshopScope.canSee(shop.workshop())).isFalse();
        assertThat(assertThrows(ApiException.class,()->requisitions.cancel(pending.id(),command)).getCode()).isEqualTo(ErrorCode.FORBIDDEN);
        assertThat(commandCount(pending.id(),"REQUISITION_CANCEL")).isEqualTo(1);
        assertThat(db.queryForObject("SELECT row_to_json(requisition)::text FROM workshop_material_requisitions requisition WHERE id=?",String.class,pending.id())).isEqualTo(snapshot);
    }

    private record Shop(FullChainEndToEndTest fixture,UUID workshop,UUID leaf,UUID goods,UUID issuer,UUID requester) { }

    private Shop shop() {
        var fixture = fixture();
        String tag = shortId();
        var world = fixture.seedWorld("replay-workshop-"+tag);
        fixture.loginAs(world.superAdminUserId());
        UUID workshop = anotherWorkshop(fixture);
        UUID kg = UUID.randomUUID();
        int legacy = 900_000_000 + ThreadLocalRandom.current().nextInt(90_000_000);
        db.update("INSERT INTO units(id,legacy_id,code,name,status) VALUES(?,?,?,'千克','使用')",kg,legacy,"REPLAY-KG-"+tag);
        db.update("INSERT INTO unit_measurement_profiles(unit_id,measurement_dimension,mass_unit_code,provenance) VALUES(?,'MASS','KG','MANUAL_GOVERNANCE')",kg);
        UUID goods = UUID.randomUUID();
        db.update("""
                INSERT INTO goods(id,code,name,source_type,status,unit_id,unit_legacy_id,price,code_sequence,
                    issue_method,periodic_cost_basis,bulk_package_qty,owning_warehouse_id,min_qty)
                VALUES(?,?,?,'采购','使用',?,?,1,(SELECT coalesce(max(code_sequence),0)+1 FROM goods),'PERIODIC','OWN',25,?,0)
                """,goods,"REPLAY-M-"+tag,"重放范围材料",kg,legacy,world.warehouseId());
        var receipt = new StockDocSaveRequest();
        receipt.setDocType("OTHER_IN");receipt.setBillDate(BusinessTime.today());receipt.setWarehouseId(world.warehouseId());
        var line = new StockDocItemLine();
        line.setGoodsId(goods);line.setUnitId(kg);line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal("10"));line.setPrice(BigDecimal.ONE);
        line.setAmountOriginal(BigDecimal.TEN);line.setAmountLocal(BigDecimal.TEN);
        receipt.setItems(List.of(line));stock.approve(stock.create(receipt).getId());
        settings.update(workshop,new SettingsRequest(null,0L,true,world.warehouseId(),null,true,BusinessTime.today(),List.of(),"replay-enable-"+UUID.randomUUID()));
        UUID issuer = fixture.createUserWithPerms(world,"replay-issuer-"+tag,"workshop_material:view","workshop_material:issue");
        UUID requester = fixture.createUserWithPerms(world,"replay-requester-"+tag,"workshop_material:view","workshop_material:request");
        db.update("UPDATE employees SET department_id=? WHERE id=?",workshop,employee(requester));
        return new Shop(fixture,workshop,world.warehouseId(),goods,issuer,requester);
    }

    private FullChainEndToEndTest fixture() {
        var fixture = new FullChainEndToEndTest();beans.autowireBean(fixture);return fixture;
    }
    private UUID anotherWorkshop(FullChainEndToEndTest fixture) {
        Object assignment = ReflectionTestUtils.invokeMethod(fixture,"productionAssignment","replay-role-"+shortId());
        return ReflectionTestUtils.invokeMethod(assignment,"workshopId");
    }
    private UUID employee(UUID user) { return db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,user); }
    private int movementCount(UUID document) { return db.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_id=?",Integer.class,document); }
    private int commandCount(UUID request,String kind) { return db.queryForObject("SELECT count(*) FROM workshop_material_commands WHERE target_id=? AND command_kind=?",Integer.class,request,kind); }
    private static String shortId() { return UUID.randomUUID().toString().substring(0,8); }
    private static void assertAuthority(String permission) {
        assertThat(((AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal()).getPermissions()).contains(permission);
    }
}
