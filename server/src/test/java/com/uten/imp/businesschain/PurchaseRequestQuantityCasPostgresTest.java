package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.purchase.request.*;
import com.uten.imp.features.purchase.request.dto.*;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.order.dto.*;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import java.math.BigDecimal;
import java.util.*;
import java.util.concurrent.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;

/** Real request/order/financial occupancy paths with persistent CAS and canonical locks. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
        "uten.inventory.value-work-initial-delay-ms=3600000","uten.workshop-material.auto-close.enabled=false",
        "uten.policy-intelligence.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@AutoConfigureMockMvc(print=MockMvcPrint.NONE)
class PurchaseRequestQuantityCasPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry p){FullChainEndToEndTest.registerDataSource(p);}
    @Autowired PurchaseRequestService requests;
    @Autowired PurchaseRequestItemRepository items;
    @Autowired PurchaseOrderService orders;
    @Autowired ProcurementFinanceApprovalService finance;
    @Autowired com.uten.imp.common.concurrency.ProcurementMutationLocks locks;
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired PlatformTransactionManager transactions;
    @Autowired JdbcTemplate db;
    @Autowired MockMvc http;
    @Autowired ObjectMapper json;
    @AfterEach void clear(){SecurityContextHolder.clearContext();}
    record Case(FullChainEndToEndTest harness,FullChainEndToEndTest.World world,UUID request,List<UUID> items,Authentication actor){}
    record Recreated(Long version,String sqlState){}

    @Test void twoConcurrentQuantityEditsHaveExactlyOneSuccessAndOneConflict() throws Exception {
        var c=prepare(1);UUID item=c.items().getFirst();long version=row(c,item).getRowVersion();
        var start=new CountDownLatch(1);
        try(var workers=Executors.newFixedThreadPool(2)){
            var first=workers.submit(()->{start.await();return change(c,item,"20",version,c.actor());});
            var second=workers.submit(()->{start.await();return change(c,item,"30",version,c.actor());});
            start.countDown();List<Integer> statuses=List.of(first.get(30,TimeUnit.SECONDS),second.get(30,TimeUnit.SECONDS));
            assertEquals(1,statuses.stream().filter(v->v==200).count());assertEquals(1,statuses.stream().filter(v->v==409).count());
        }
        login(c);var finalRow=row(c,item);assertEquals(version+1,finalRow.getRowVersion());
        assertTrue(finalRow.getQty().compareTo(new BigDecimal("20"))==0 || finalRow.getQty().compareTo(new BigDecimal("30"))==0);
        assertVersionMatchesDatabase(item,finalRow);
    }

    @Test void quantityAbaAndNativeMutationsCannotMakeTheOriginalVersionValidAgain() throws Exception {
        var c=prepare(1);UUID item=c.items().getFirst();long original=row(c,item).getRowVersion();
        assertEquals(200,change(c,item,"20",original,c.actor()));login(c);long next=row(c,item).getRowVersion();
        assertEquals(200,change(c,item,"10",next,c.actor()));login(c);
        assertEquals(original+2,row(c,item).getRowVersion());
        assertEquals(409,change(c,item,"37",original,c.actor()));login(c);
        long beforeNative=row(c,item).getRowVersion();
        db.update("UPDATE purchase_request_items SET remark='native source change' WHERE id=?",item);
        assertEquals(beforeNative+1,row(c,item).getRowVersion());
        assertEquals(409,change(c,item,"37",beforeNative,c.actor()));login(c);
        assertEquals(0,BigDecimal.TEN.compareTo(row(c,item).getQty()));
    }

    @Test void pendingSubmissionHoldsTheSharedSourcePrefixAndWaitingQuantityEditRechecksCommittedOccupancy() throws Exception {
        var c=prepare(1);UUID item=c.items().getFirst();long version=row(c,item).getRowVersion();
        UUID order=createOrder(c,List.of(item),"2");
        var held=new CountDownLatch(1);var release=new CountDownLatch(1);
        try(var workers=Executors.newFixedThreadPool(2)){
            var submit=workers.submit(()->{
                login(c);
                try {new TransactionTemplate(transactions).executeWithoutResult(tx->{
                    var guard=locks.order("PURCHASE",order);guard.verifyUnchanged();
                    finance.submit("PURCHASE",order);held.countDown();
                    try{assertTrue(release.await(15,TimeUnit.SECONDS));}catch(InterruptedException e){throw new RuntimeException(e);}
                });}finally{SecurityContextHolder.clearContext();}
            });
            assertTrue(held.await(15,TimeUnit.SECONDS));
            var adjusting=workers.submit(()->change(c,item,"37",version,c.actor()));
            boolean blocked=false;
            for(int attempt=0;attempt<80&&!blocked;attempt++){
                blocked=Boolean.TRUE.equals(db.queryForObject("""
                        SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=current_database()
                          AND wait_event_type='Lock' AND query LIKE '%purchase_requests%FOR UPDATE%')
                        """,Boolean.class));
                if(!blocked)Thread.sleep(25);
            }
            assertTrue(blocked,"the real qty command must wait on the existing canonical request prefix");
            assertFalse(adjusting.isDone());release.countDown();submit.get(20,TimeUnit.SECONDS);
            assertEquals(400,adjusting.get(20,TimeUnit.SECONDS));
        }finally{release.countDown();}
        login(c);assertEquals(0,BigDecimal.TEN.compareTo(row(c,item).getQty()));
        assertEquals(0,new BigDecimal("2").compareTo(row(c,item).getPendingQty()));
        assertEquals(version,row(c,item).getRowVersion(),"occupancy history does not invent a row edit");
    }

    @Test void mergedOrderSecondarySourceIsPendingAndPrimaryFallbackDoesNotDoubleCountMappedSources() throws Exception {
        var c=prepare(2);UUID order=createOrder(c,c.items(),"12");finance.submit("PURCHASE",order);
        UUID secondary=db.queryForObject("""
                SELECT src.request_item_id FROM purchase_order_item_sources src
                JOIN purchase_order_items oi ON oi.id=src.order_item_id
                WHERE oi.order_id=? AND src.request_item_id<>oi.request_item_id
                """,UUID.class,order);
        var selected=row(c,secondary);assertTrue(selected.getPendingQty().signum()>0);
        assertEquals(400,change(c,secondary,"37",selected.getRowVersion(),c.actor()));login(c);
        BigDecimal sum=c.items().stream().map(id->row(c,id).getPendingQty()).reduce(BigDecimal.ZERO,BigDecimal::add);
        assertEquals(0,new BigDecimal("12").compareTo(sum),"primary reference must not double count the source map");
        assertEquals(0,BigDecimal.TEN.compareTo(row(c,secondary).getQty()));
    }

    @Test void currentPermissionsAndExactRequestItemMembershipAreRequiredButNoMakerScopeIsInvented() throws Exception {
        var c=prepare(1);var other=prepare(1);login(c);UUID item=c.items().getFirst();long version=row(c,item).getRowVersion();
        var limited=new AuthUser(c.world().superAdminUserId(),c.world().employeeId(),"qty-reader",
                Set.of("purchase_request:view"),false,true,false);
        var denied=new UsernamePasswordAuthenticationToken(limited,null,limited.getAuthorities());
        assertEquals(403,change(c,item,"37",version,denied));
        assertEquals(404,change(c,other.items().getFirst(),"37",version,c.actor()));
        login(c);assertEquals(0,BigDecimal.TEN.compareTo(row(c,item).getQty()));
    }

    @Test void oldQuantityOnlyBodyAndCurrentlyClosedStoppedOrDeletedItemsCannotWrite() throws Exception {
        var c=prepare(1);UUID item=c.items().getFirst();long version=row(c,item).getRowVersion();
        var old=http.perform(put(path(c,item)).with(authentication(c.actor())).contentType("application/json")
                .content("{\"qty\":37}")).andReturn().getResponse();
        assertEquals(422,old.getStatus());
        db.update("UPDATE purchase_requests SET is_closed=TRUE WHERE id=?",c.request());
        assertEquals(400,change(c,item,"37",version,c.actor()));
        db.update("UPDATE purchase_requests SET is_closed=FALSE,is_stopped=TRUE WHERE id=?",c.request());
        assertEquals(400,change(c,item,"37",version,c.actor()));
        db.update("UPDATE purchase_requests SET is_stopped=FALSE WHERE id=?",c.request());
        db.update("UPDATE purchase_request_items SET is_deleted=TRUE WHERE id=?",item);
        assertEquals(404,change(c,item,"37",version,c.actor()));
        assertEquals(0,BigDecimal.TEN.compareTo(db.queryForObject("SELECT qty FROM purchase_request_items WHERE id=?",BigDecimal.class,item)));
    }

    @Test void retainedSameUuidRecreationAdvancesTheEpochAndJpaDtoReadsTheDatabaseGeneratedValue() throws Exception {
        var c=prepare(1);UUID item=c.items().getFirst();var old=row(c,item);long version=old.getRowVersion();
        db.update("DELETE FROM purchase_request_items WHERE id=?",item);
        assertEquals(1,db.queryForObject("SELECT count(*) FROM business_record_history WHERE source_table='purchase_request_items' AND source_id=? AND operation='DELETE'",Integer.class,item.toString()));
        var restored=new PurchaseRequestItem();restored.setId(item);restored.setRequestId(c.request());
        restored.setBillNo(requests.detail(c.request()).getBillNo());restored.setBillDate(BusinessTime.today());restored.setLineNo(1);
        restored.setGoodsId(old.getGoodsId());restored.setGoodsCodeSnapshot(old.getGoodsCodeSnapshot());
        restored.setGoodsNameSnapshot(old.getGoodsNameSnapshot());restored.setGoodsSnapshotSource(old.getGoodsSnapshotSource());
        restored.setGoodsSnapshotLockedAt(old.getGoodsSnapshotLockedAt());restored.setUnitId(old.getUnitId());restored.setUnitRate(old.getUnitRate());
        restored.setQty(BigDecimal.TEN);
        var saved=items.saveAndFlush(restored);
        assertEquals(version+1,saved.getRowVersion(),"ORM must retrieve the INSERT trigger epoch instead of returning seed0");
        var current=row(c,item);assertVersionMatchesDatabase(item,current);assertEquals(version+1,current.getRowVersion());
        assertEquals(409,change(c,item,"37",version,c.actor()));
        assertConcurrentRecreation(org.springframework.transaction.TransactionDefinition.ISOLATION_READ_COMMITTED);
        assertConcurrentRecreation(org.springframework.transaction.TransactionDefinition.ISOLATION_REPEATABLE_READ);
    }

    private void assertConcurrentRecreation(int isolation) throws Exception {
        var c=prepare(1);UUID item=c.items().getFirst();long original=row(c,item).getRowVersion();
        String savedRow=db.queryForObject("SELECT to_jsonb(i)::text FROM purchase_request_items i WHERE id=?",String.class,item);
        var deleted=new CountDownLatch(1);var commitDelete=new CountDownLatch(1);
        try(var workers=Executors.newFixedThreadPool(2)) {
            var deleting=workers.submit(()->new TransactionTemplate(transactions).executeWithoutResult(tx->{
                db.update("UPDATE purchase_request_items SET remark='concurrent epoch' WHERE id=?",item);
                db.update("DELETE FROM purchase_request_items WHERE id=?",item);
                deleted.countDown();
                try { assertTrue(commitDelete.await(15,TimeUnit.SECONDS)); }
                catch(InterruptedException interrupted) { throw new RuntimeException(interrupted); }
            }));
            assertTrue(deleted.await(15,TimeUnit.SECONDS));
            var inserting=workers.submit(()->{
                var transaction=new TransactionTemplate(transactions);transaction.setIsolationLevel(isolation);
                try {
                    Long version=transaction.execute(tx->{
                        // Establish the RR snapshot while the original row and
                        // its uncommitted deletion are still visible as old facts.
                        assertNotNull(db.queryForObject("SELECT qty FROM purchase_request_items WHERE id=?",BigDecimal.class,item));
                        return db.queryForObject("""
                                INSERT INTO purchase_request_items
                                SELECT (jsonb_populate_record(NULL::purchase_request_items,
                                    jsonb_set(CAST(? AS jsonb),'{row_version}','0'::jsonb))).*
                                RETURNING row_version
                                """,Long.class,savedRow);
                    });
                    return new Recreated(version,null);
                } catch(org.springframework.dao.DataAccessException failure) {
                    for(Throwable cause=failure;cause!=null;cause=cause.getCause())
                        if(cause instanceof java.sql.SQLException sql)return new Recreated(null,sql.getSQLState());
                    throw failure;
                }
            });
            boolean waiting=false;
            for(int attempt=0;attempt<80&&!waiting;attempt++) {
                waiting=Boolean.TRUE.equals(db.queryForObject("""
                        SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=current_database()
                          AND wait_event_type='Lock' AND query LIKE 'INSERT INTO purchase_request_items%')
                        """,Boolean.class));
                if(!waiting)Thread.sleep(25);
            }
            assertTrue(waiting,"same-ID insert must actually wait for the uncommitted delete");
            assertFalse(inserting.isDone());commitDelete.countDown();deleting.get(20,TimeUnit.SECONDS);
            Recreated result=inserting.get(20,TimeUnit.SECONDS);
            if(isolation==org.springframework.transaction.TransactionDefinition.ISOLATION_READ_COMMITTED) {
                assertNull(result.sqlState());assertEquals(original+2,result.version());
                login(c);var current=row(c,item);assertVersionMatchesDatabase(item,current);
                assertEquals(original+2,current.getRowVersion());
                assertEquals(409,change(c,item,"37",original,c.actor()));
                assertEquals(409,change(c,item,"37",original+1,c.actor()));
            } else {
                assertNull(result.version());assertEquals("40001",result.sqlState(),"stale RR must fail closed without resetting the epoch");
                assertEquals(0,db.queryForObject("SELECT count(*) FROM purchase_request_items WHERE id=?",Integer.class,item));
            }
        } finally { commitDelete.countDown(); }
    }

    private Case prepare(int count){
        var harness=new FullChainEndToEndTest();beans.autowireBean(harness);var world=harness.seedWorld("qty-cas-"+UUID.randomUUID());
        // Each isolated world owns a real, active, explicitly authorized reviewer.
        harness.createUserWithPerms(world,"QREV-"+UUID.randomUUID(),
                "finance_order_approval:view","finance_order_approval:approve","finance_order_approval:reject");
        harness.loginAs(world.superAdminUserId());var request=new RequestSaveRequest();request.setBillDate(BusinessTime.today());request.setWarehouseId(world.warehouseId());
        request.setDepartmentId(world.departmentId());request.setApplicantId(world.employeeId());
        var lines=new ArrayList<RequestItemLine>();for(int i=0;i<count;i++){var line=new RequestItemLine();line.setLineNo(i+1);line.setGoodsId(world.goodsD());
            line.setUnitId(world.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(BigDecimal.TEN);lines.add(line);}
        request.setItems(lines);var created=requests.create(request);requests.approve(created.getId());
        return new Case(harness,world,created.getId(),created.getItems().stream().map(RequestItemDto::getId).toList(),SecurityContextHolder.getContext().getAuthentication());
    }
    private UUID createOrder(Case c,List<UUID> sources,String qty){
        login(c);var input=new OrderSaveRequest();input.setBillDate(BusinessTime.today());input.setSupplierId(c.world().supplierId());
        input.setWarehouseId(c.world().warehouseId());input.setCurrencyId(c.world().currencyId());input.setExchangeRate(BigDecimal.ONE);input.setTaxRate(BigDecimal.ZERO);
        input.setSettlementMethodId(db.queryForObject("SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted ORDER BY code LIMIT 1",UUID.class));
        var line=new OrderItemLine();line.setGoodsId(c.world().goodsD());line.setUnitId(c.world().unitId());line.setUnitRate(BigDecimal.ONE);
        line.setRequestItemId(sources.getFirst());line.setRequestItemIds(sources);line.setQty(new BigDecimal(qty));line.setPrice(new BigDecimal("50"));input.setItems(List.of(line));
        var made=orders.createBatch(input);assertEquals(1,made.size());return made.getFirst().getId();
    }
    private void login(Case c){c.harness().loginAs(c.world().superAdminUserId());}
    private RequestItemDto row(Case c,UUID id){return requests.detail(c.request()).getItems().stream().filter(it->it.getId().equals(id)).findFirst().orElseThrow();}
    private void assertVersionMatchesDatabase(UUID id,RequestItemDto item){assertEquals(db.queryForObject("SELECT row_version FROM purchase_request_items WHERE id=?",Long.class,id),item.getRowVersion());}
    private String path(Case c,UUID id){return "/api/purchase/requests/"+c.request()+"/items/"+id+"/qty";}
    private int change(Case c,UUID id,String qty,long version,Authentication actor) throws Exception {
        return http.perform(put(path(c,id)).with(authentication(actor)).contentType("application/json")
                .content(json.writeValueAsBytes(Map.of("qty",new BigDecimal(qty),"expectedVersion",version))))
                .andReturn().getResponse().getStatus();
    }
}
