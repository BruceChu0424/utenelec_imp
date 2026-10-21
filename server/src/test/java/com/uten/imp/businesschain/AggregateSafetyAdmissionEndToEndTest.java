package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.GroupInput;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static com.uten.imp.businesschain.AggregateMaterialOrderEndToEndTest.amount;
import static org.junit.jupiter.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class AggregateSafetyAdmissionEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }
    @Autowired AutowireCapableBeanFactory beans;
    AggregateMaterialOrderEndToEndTest h;
    @BeforeEach void before() {
        h=new AggregateMaterialOrderEndToEndTest();beans.autowireBean(h);h.before();
    }
    @AfterEach void after() { h.after(); }

    @ParameterizedTest @ValueSource(strings={"0","3","9.9999","10.0001","11"})
    void purchaseMustConfirmTheWholeCurrentSafetyGapBeforeAnyBusinessWrite(String confirmed) {
        var c=h.createWithChild("5",1);h.setRoute(c,c.common(),"BUY");
        h.db.update("UPDATE goods SET min_qty=10 WHERE id=?",c.common());
        var request=h.request(c,List.of(withSafety(h.input(c,c.common(),"BUY","5",false),confirmed)));
        var before=writeCounts(c);
        var reviewed=h.preview.preview(c.analysis(),request);
        amount("10",reviewed.analysis().flatMaterials().stream()
                .filter(row->row.goodsId().equals(c.common())).findFirst().orElseThrow()
                .mainWarehouseSafetyReplenishmentGapQty());
        assertAll(
                ()->assertNotNull(reviewed.groups().getFirst().blockedReason(),"fixed safety gap must be confirmed exactly"),
                ()->assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,
                        ()->h.writer.submit(c.analysis(),h.submit(reviewed,request))).getCode()),
                ()->assertEquals(before,writeCounts(c),"a rejected admission cannot create business or replay facts"));
    }

    @ParameterizedTest @ValueSource(strings={"MAKE","SUBCONTRACT"})
    void unsupportedRoutesCannotHideAnUnfilledPublicSafetyGap(String route) {
        var c=h.createWithChild("5",1);h.setRoute(c,c.common(),route);
        h.db.update("UPDATE goods SET min_qty=3 WHERE id=?",c.common());
        var request=h.request(c,List.of(h.input(c,c.common(),route,"5",false)));
        var before=writeCounts(c);var reviewed=h.preview.preview(c.analysis(),request);
        amount("3",reviewed.analysis().flatMaterials().stream()
                .filter(row->row.goodsId().equals(c.common())).findFirst().orElseThrow()
                .mainWarehouseSafetyReplenishmentGapQty());
        assertAll(
                ()->assertNotNull(reviewed.groups().getFirst().blockedReason()),
                ()->assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,
                        ()->h.writer.submit(c.analysis(),h.submit(reviewed,request))).getCode()),
                ()->assertEquals(before,writeCounts(c)));
    }

    @ParameterizedTest @ValueSource(strings={"MAKE","SUBCONTRACT"})
    void nonPurchaseWithAnAlreadyCoveredSafetyGapKeepsItsActionSnapshotZero(String route) {
        var c=h.createWithChild("5",1);h.setRoute(c,c.common(),route);
        h.db.update("UPDATE goods SET min_qty=3 WHERE id=?",c.common());
        h.db.update("INSERT INTO stock_balances(warehouse_id,goods_id,qty) VALUES (?,?,3)",c.world().warehouseId(),c.common());
        var request=h.request(c,List.of(h.input(c,c.common(),route,"5",false)));
        var reviewed=h.preview.preview(c.analysis(),request);
        var source=reviewed.analysis().flatMaterials().stream().filter(row->row.goodsId().equals(c.common())).findFirst().orElseThrow();
        amount("3",source.safetyStockQty());amount("3",source.mainWarehousePublicAvailableQty());
        amount("0",source.mainWarehouseSafetyReplenishmentGapQty());
        assertNull(reviewed.groups().getFirst().blockedReason());
        var result=h.writer.submit(c.analysis(),h.submit(reviewed,request));
        UUID action=action(result.batches().getFirst().batchId());
        var values=h.db.queryForObject("""
                SELECT requested_qty,safety_replenishment_qty,safety_stock_snapshot_qty,
                       public_available_snapshot_qty,open_safety_supply_snapshot_qty
                FROM preplan_supply_actions WHERE id=?
                """,(row,index)->List.of(row.getBigDecimal(1),row.getBigDecimal(2),row.getBigDecimal(3),row.getBigDecimal(4),row.getBigDecimal(5)),action);
        amount("5",values.getFirst());values.subList(1,values.size()).forEach(value->amount("0",value));
        assertEquals(route,result.batches().getFirst().route());
        assertTrue(h.writer.submit(c.analysis(),h.submit(reviewed,request)).replayed());
    }

    @Test void exactPurchaseSafetyIsSeparateFromPrivateDemandAndPublicExtra() {
        var c=h.createWithChild("5",1);h.setRoute(c,c.common(),"BUY");
        h.db.update("UPDATE goods SET min_qty=10 WHERE id=?",c.common());
        var request=h.request(c,List.of(withSafety(h.input(c,c.common(),"BUY","7",true),"10")));
        var reviewed=h.preview.preview(c.analysis(),request);assertNull(reviewed.groups().getFirst().blockedReason());
        var result=h.writer.submit(c.analysis(),h.submit(reviewed,request));
        var batch=result.batches().getFirst();UUID action=action(batch.batchId());
        var quantities=h.db.queryForObject("""
                SELECT requested_qty,public_surplus_qty,safety_replenishment_qty,safety_stock_snapshot_qty
                FROM preplan_supply_actions WHERE id=?
                """,(row,index)->List.of(row.getBigDecimal(1),row.getBigDecimal(2),row.getBigDecimal(3),row.getBigDecimal(4)),action);
        amount("5",quantities.get(0));amount("2",quantities.get(1));amount("10",quantities.get(2));amount("10",quantities.get(3));
        amount("5",h.db.queryForObject("SELECT SUM(allocated_qty) FROM preplan_supply_action_allocations WHERE action_id=?",BigDecimal.class,action));
        amount("17",h.db.queryForObject("SELECT SUM(qty) FROM purchase_request_items WHERE request_id=? AND NOT is_deleted",BigDecimal.class,batch.documentId()));
        assertEquals(2,h.count("SELECT count(*) FROM purchase_request_items WHERE request_id=? AND NOT is_deleted",batch.documentId()));
        assertTrue(h.writer.submit(c.analysis(),h.submit(reviewed,request)).replayed());
    }

    @Test void onePhysicalSafetyOwnerAlsoCoversOtherPurchaseBatchesWithDifferentDeliveryDates() {
        var c=h.createWithChild("5",2);h.setRoute(c,c.common(),"BUY");
        h.db.update("UPDATE goods SET min_qty=10 WHERE id=?",c.common());
        var ids=h.input(c,c.common(),"BUY","10",false).materialLineIds();assertEquals(2,ids.size());
        var request=h.request(c,List.of(split("a-demand",ids.get(1),"0",11),split("z-safety",ids.get(0),"10",10)));
        var reviewed=h.preview.preview(c.analysis(),request);
        reviewed.groups().forEach(group->assertNull(group.blockedReason()));
        var result=h.writer.submit(c.analysis(),h.submit(reviewed,request));
        assertEquals(2,result.batches().size());
        assertEquals("z-safety",result.batches().getFirst().clientGroupKey(),"the confirmed owner must establish coverage before a sibling rechecks");
        amount("10",h.db.queryForObject("SELECT SUM(safety_replenishment_qty) FROM preplan_supply_actions WHERE analysis_id=?",BigDecimal.class,c.analysis()));
        amount("10",h.db.queryForObject("SELECT SUM(allocated_qty) FROM preplan_supply_action_allocations WHERE analysis_id=?",BigDecimal.class,c.analysis()));
        amount("20",h.db.queryForObject("SELECT SUM(qty) FROM purchase_request_items WHERE goods_id=? AND NOT is_deleted",BigDecimal.class,c.common()));
        amount("0",h.analyses.detail(c.analysis()).flatMaterials().stream().filter(row->row.goodsId().equals(c.common()))
                .findFirst().orElseThrow().mainWarehouseSafetyReplenishmentGapQty());
        assertTrue(h.writer.submit(c.analysis(),h.submit(reviewed,request)).replayed());
    }

    @Test void duplicateSafetyOwnersAreRejectedBeforeEitherBatchExists() {
        var c=h.createWithChild("5",2);h.setRoute(c,c.common(),"BUY");
        h.db.update("UPDATE goods SET min_qty=10 WHERE id=?",c.common());
        var ids=h.input(c,c.common(),"BUY","10",false).materialLineIds();
        var request=h.request(c,List.of(split("first",ids.get(0),"10",10),split("second",ids.get(1),"10",11)));
        var before=writeCounts(c);var reviewed=h.preview.preview(c.analysis(),request);
        reviewed.groups().forEach(group->assertNotNull(group.blockedReason()));
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,()->h.writer.submit(c.analysis(),h.submit(reviewed,request))).getCode());
        assertEquals(before,writeCounts(c));
    }

    private UUID action(UUID batch) {
        return h.db.queryForObject("SELECT action_id FROM preplan_aggregate_batches WHERE id=?",UUID.class,batch);
    }
    private List<Long> writeCounts(AggregateMaterialOrderEndToEndTest.Case c) {
        return List.of(h.count("SELECT count(*) FROM preplan_supply_actions WHERE analysis_id=?",c.analysis()),
                h.count("SELECT count(*) FROM preplan_aggregate_batches WHERE analysis_id=?",c.analysis()),
                h.count("SELECT count(*) FROM production_material_analysis_commands WHERE analysis_id=?",c.analysis()),
                h.count("SELECT count(*) FROM production_plans WHERE material_analysis_id=?",c.analysis()),
                h.count("SELECT count(*) FROM purchase_request_items WHERE goods_id=?",c.common()),
                h.count("SELECT count(*) FROM subcontract_application_items WHERE goods_id=?",c.common()));
    }
    private static GroupInput withSafety(GroupInput input,String safety) {
        return new GroupInput(input.clientGroupKey(),input.materialLineIds(),input.route(),input.qty(),input.allowPublicExtra(),
                input.departmentId(),input.workerId(),input.teamDepartmentId(),input.billDate(),input.deliveryDate(),input.productNo(),
                input.allowedOverproductionRate(),new BigDecimal(safety),input.sourceRequestedQtyByMaterialLineId());
    }
    private static GroupInput split(String key,UUID source,String safety,int days) {
        return new GroupInput(key,List.of(source),"BUY",new BigDecimal("5"),false,null,null,null,null,
                BusinessTime.today().plusDays(days),null,null,new BigDecimal(safety));
    }
}
