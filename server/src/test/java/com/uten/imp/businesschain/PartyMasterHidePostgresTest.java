package com.uten.imp.businesschain;

import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.client.ClientService;
import com.uten.imp.features.master.lifecycle.MasterEntityKind;
import com.uten.imp.features.master.lifecycle.MasterLifecycleService;
import com.uten.imp.features.master.lifecycle.dto.MasterBatchRequests;
import com.uten.imp.features.master.supplier.SupplierService;
import com.uten.imp.features.sales.order.SalesOrderService;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Real migrated database: hiding a party changes selection, never old business identity. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK, properties={
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false", "uten.production.readiness-reconcile.enabled=false",
        "uten.workshop-material.auto-close.enabled=false", "uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true", "uten.storage.malware-scan.provider=test-only"})
class PartyMasterHidePostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired MasterLifecycleService lifecycle;
    @Autowired ClientService clients;
    @Autowired SupplierService suppliers;
    @Autowired SalesOrderService orders;
    @Autowired MasterReferenceValidationPort references;
    @Autowired com.uten.imp.features.finance.arap.ArApLedgerQueryService ledgerQuery;
    @Autowired PlatformTransactionManager transactions;
    FullChainEndToEndTest fixture;
    FullChainEndToEndTest.World world;
    String tag;

    @BeforeEach void seed() {
        fixture = new FullChainEndToEndTest(); beans.autowireBean(fixture);
        tag="HIDE"+UUID.randomUUID().toString().replace("-", "").substring(0,10);
        world=fixture.seedWorld(tag); fixture.loginAs(world.superAdminUserId());
    }
    @AfterEach void clear() { SecurityContextHolder.clearContext(); }
    List<MasterBatchRequests.Item> item(String table, UUID id) {
        return List.of(new MasterBatchRequests.Item(id, db.queryForObject("SELECT version FROM "+table+" WHERE id=?",Long.class,id)));
    }

    @Test void referencedCustomerRequiresConfirmationAndOldOrderCanStillBeEditedAndApproved() {
        var request=fixture.orderRequest(world,world.goodsC(),"2","100");
        var saved=orders.create(request);
        var targets=item("clients",world.clientId());
        var preview=lifecycle.batchDelete(MasterEntityKind.CLIENT,targets);
        assertEquals(0,preview.succeeded());
        assertTrue(preview.results().getFirst().confirmationRequired());
        assertTrue(preview.results().getFirst().references().stream().anyMatch(r->saved.getId().equals(r.id())));
        assertFalse(db.queryForObject("SELECT is_hidden FROM clients WHERE id=?",Boolean.class,world.clientId()));
        var stale=lifecycle.batchDelete(MasterEntityKind.CLIENT,List.of(new MasterBatchRequests.Item(world.clientId(),-1L)),true);
        assertEquals(0,stale.succeeded()); assertFalse(stale.results().getFirst().confirmationRequired());
        assertEquals(1,lifecycle.batchDelete(MasterEntityKind.CLIENT,targets,true).succeeded());
        assertPreserved("clients",world.clientId());
        assertEquals(0,clients.referencePage(null,tag,true,true,1,20).getTotal());
        var historic=clients.referencePage(null,tag,false,true,1,20).getItems().getFirst();
        assertEquals(world.clientId(),historic.id()); assertFalse(historic.selectable());
        var identity=clients.lookup(Set.of(world.clientId()),true).getFirst();
        assertEquals(world.clientId(),identity.id()); assertFalse(identity.selectable());
        assertEquals(world.clientId(),orders.detail(saved.getId()).getClientId());
        request.getItems().getFirst().setId(saved.getItems().getFirst().getId()); request.setRemark("旧业务继续办理");
        assertDoesNotThrow(()->orders.update(saved.getId(),request));
        assertDoesNotThrow(()->orders.approve(saved.getId()));
        var error=assertThrows(ApiException.class,()->orders.create(fixture.orderRequest(world,world.goodsC(),"1","100")));
        assertEquals(ErrorCode.CONFLICT,error.getCode());
        assertEquals(0,lifecycle.batchDelete(MasterEntityKind.CLIENT,targets,true).succeeded());
    }

    @Test void hiddenSupplierKeepsExistingProcurementFinanceApprovalAndHistoricalName() {
        var pending=fixture.submitPurchaseForFinance(world,purchaseOnlyProduct(),world.goodsD(),"1");
        fixture.loginAs(world.superAdminUserId());
        var targets=item("suppliers",world.supplierId());
        var preview=lifecycle.batchDelete(MasterEntityKind.SUPPLIER,targets);
        assertTrue(preview.results().getFirst().confirmationRequired());
        assertEquals(1,lifecycle.batchDelete(MasterEntityKind.SUPPLIER,targets,true).succeeded());
        assertPreserved("suppliers",world.supplierId());
        assertEquals(0,suppliers.referencePage(null,tag,true,1,20).getTotal());
        var historic=suppliers.referencePage(null,tag,false,1,20).getItems().getFirst();
        assertEquals(world.supplierId(),historic.id()); assertFalse(historic.selectable());
        var identity=suppliers.lookup(Set.of(world.supplierId())).getFirst();
        assertEquals(world.supplierId(),identity.getId()); assertFalse(identity.isSelectable());
        new TransactionTemplate(transactions).executeWithoutResult(status-> {
            assertDoesNotThrow(()->references.requireExistingSupplier(world.supplierId()));
        });
        assertEquals(ErrorCode.CONFLICT,assertThrows(ApiException.class,()->new TransactionTemplate(transactions)
                .executeWithoutResult(status->references.requireSelectableSupplier(world.supplierId()))).getCode());
        fixture.loginAs(pending.reviewerUserId());
        assertDoesNotThrow(()->fixture.approvePendingFinance("PURCHASE",pending.orderId()));
        assertEquals(1,db.queryForObject("SELECT status FROM purchase_orders WHERE id=?",Integer.class,pending.orderId()));
        assertEquals(world.supplierId(),db.queryForObject("SELECT supplier_id FROM purchase_orders WHERE id=?",UUID.class,pending.orderId()));
    }

    @Test void confirmedPartyHideDoesNotBypassGoodsBomProtection() {
        var result=lifecycle.batchDelete(MasterEntityKind.GOODS,item("goods",world.goodsB()),true);
        assertEquals(0,result.succeeded()); assertFalse(result.results().getFirst().confirmationRequired());
        assertFalse(db.queryForObject("SELECT is_deleted FROM goods WHERE id=?",Boolean.class,world.goodsB()));
    }

    @Test void realShipmentReceivableAndProcurementPayableKeepEveryAmountAndPartyNameAfterHide() {
        fixture.seedChartOfAccounts();
        var made=fixture.produceFinishedFromOpeningInputs(world,world.goodsA(),"1","1");
        UUID shipment=fixture.createShipment(world,made.orderItemId(),world.goodsA(),"1");
        fixture.shipThroughWarehouse(shipment);
        var pending=fixture.submitPurchaseForFinance(world,purchaseOnlyProduct(),world.goodsD(),"1");
        fixture.loginAs(pending.reviewerUserId()); fixture.approvePendingFinance("PURCHASE",pending.orderId());
        UUID orderItem=db.queryForObject("SELECT id FROM purchase_order_items WHERE order_id=? AND NOT is_deleted",UUID.class,pending.orderId());
        var qty=db.queryForObject("SELECT qty FROM purchase_order_items WHERE id=?",java.math.BigDecimal.class,orderItem);
        fixture.receiveAndPassPurchase(world,orderItem,world.goodsD(),qty,"party-hide-"+tag);
        fixture.loginAs(world.superAdminUserId());
        var before=ledgerSnapshot(); assertTrue(before.size()>=2);
        assertEquals(1,lifecycle.batchDelete(MasterEntityKind.CLIENT,item("clients",world.clientId()),true).succeeded());
        assertEquals(1,lifecycle.batchDelete(MasterEntityKind.SUPPLIER,item("suppliers",world.supplierId()),true).succeeded());
        assertEquals(before,ledgerSnapshot(),"隐藏资料不能改写任何既有应收应付字段、余额或核销状态");
        for(String direction:List.of("AR","AP")) {
            UUID party="AR".equals(direction)?world.clientId():world.supplierId();
            var filter=new com.uten.imp.features.finance.arap.dto.ArApLedgerQueryFilter(
                    null,direction,null,party,null,null,null,null,null,null,null,null);
            var rows=ledgerQuery.list(filter,1,20,null,null).getItems(); assertFalse(rows.isEmpty());
            assertTrue(rows.stream().allMatch(row->"AR".equals(direction)
                    ? row.getClientName()!=null&&row.getClientName().contains(tag)
                    : row.getSupplierName()!=null&&row.getSupplierName().contains(tag)));
        }
    }

    List<String> ledgerSnapshot() {
        return db.queryForList("SELECT to_jsonb(ledger)::text FROM ar_ap_ledger ledger WHERE client_id=? OR supplier_id=? ORDER BY id",
                String.class,world.clientId(),world.supplierId());
    }

    UUID purchaseOnlyProduct() {
        UUID id=UUID.randomUUID();
        fixture.insertGoods(id,"P-"+tag,"采购链成品-"+tag,"自制",world.unitId(),world.unitLegacy());
        fixture.insertBom(id,world.goodsD(),"1");
        return id;
    }

    @Test void confirmationCannotReplaceDeletePermission() {
        UUID actor=fixture.createUserWithPerms(world,tag+"-reader","client:view");
        fixture.loginAs(actor);
        assertEquals(ErrorCode.FORBIDDEN,assertThrows(ApiException.class,
                ()->lifecycle.batchDelete(MasterEntityKind.CLIENT,item("clients",world.clientId()),true)).getCode());
        assertFalse(db.queryForObject("SELECT is_hidden FROM clients WHERE id=?",Boolean.class,world.clientId()));
    }

    void assertPreserved(String table, UUID id) {
        var row=db.queryForMap("SELECT is_deleted,is_hidden,status,hidden_at FROM "+table+" WHERE id=?",id);
        assertEquals(false,row.get("is_deleted")); assertEquals(true,row.get("is_hidden"));
        assertEquals("使用",row.get("status")); assertNotNull(row.get("hidden_at"));
    }
}
