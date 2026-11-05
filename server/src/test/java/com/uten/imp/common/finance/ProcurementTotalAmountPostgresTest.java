package com.uten.imp.common.finance;

import com.uten.imp.businesschain.FinanceScopedChain;
import com.uten.imp.businesschain.FinanceScopedChainDatabase;
import com.uten.imp.common.columns.BusinessColumnService;
import com.uten.imp.common.columns.ExtraColumnInput;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.request.PurchaseRequestService;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import java.math.*;
import java.util.*;
import java.util.function.Supplier;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import static com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.*;
import static org.assertj.core.api.Assertions.*;

/** Real current saves/review/revisions and actual SQL guards; no trigger suppression or invented legacy rows. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(properties={"spring.profiles.active=dev","uten.audit.retention.enabled=false",
    "uten.inventory.value-work.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
    "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
    "uten.storage.uploads-enabled=false","uten.jwt.secret=total-input-synthetic-jwt-0123456789-test-only",
    "uten.crypto.pgp-master-key=total-input-synthetic-pgp-0123456789-test-only",
    "uten.crypto.hmac-key=total-input-synthetic-hmac-0123456789-test-only",
    "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@FinanceScopedChain
class ProcurementTotalAmountPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FinanceScopedChainDatabase.register(registry,ProcurementTotalAmountPostgresTest.class);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PurchaseRequestService requests;
    @Autowired PurchaseOrderService purchases;
    @Autowired SubcontractOrderService subcontracts;
    @Autowired ProcurementFinanceApprovalService finance;
    @Autowired TaskClaimService claims;
    @Autowired BusinessColumnService columns;
    @Autowired PlatformTransactionManager transactions;
    Object harness;
    @BeforeEach void prepare()throws Exception {
        var constructor=Class.forName("com.uten.imp.businesschain.FullChainEndToEndTest").getDeclaredConstructor();
        constructor.setAccessible(true);harness=constructor.newInstance();beans.autowireBean(harness);
    }
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test void exactTotalRoundTripsAndFinanceChecksItInsteadOfTruncatedPriceProduct(){
        for(String kind:List.of("PURCHASE","SUBCONTRACT")){
            Fixture f=fixture(kind);
            assertThat(decimal("SELECT total_amount_input FROM "+f.lines()+" WHERE id=?",f.item())).isEqualByComparingTo("100");
            assertThat(decimal("SELECT price FROM "+f.lines()+" WHERE id=?",f.item())).isEqualByComparingTo("0.0333333333");
            UUID pending=submit(f);
            assertThat(decimal("SELECT amount_snapshot FROM procurement_order_approval_cases WHERE id=?",pending)).isEqualByComparingTo("105");
            assertThat(db.queryForObject("SELECT display_snapshot #>> '{items,0,totalAmountInput}' FROM procurement_order_approval_cases WHERE id=?",String.class,pending)).isEqualTo("100");
            approve(f,pending);
            assertSqlRejected(()->db.update("UPDATE "+f.lines()+" SET total_amount_input=101 WHERE id=?",f.item()),null);
            // An actual editable row can hold a bad amount only until the real commercial-snapshot guard checks it.
            Fixture bad=fixture(kind);
            assertSqlRejected(()->new TransactionTemplate(transactions).executeWithoutResult(status->{
                db.execute("CREATE TEMP TABLE commercial_probe(order_type text,order_id uuid,status text,amount_snapshot numeric DEFAULT 105) ON COMMIT DROP");
                db.execute("CREATE TRIGGER commercial_guard BEFORE INSERT ON commercial_probe FOR EACH ROW EXECUTE FUNCTION fn_guard_procurement_finance_commercial_snapshot()");
                db.update("UPDATE "+bad.lines()+" SET amount_original=qty*price+5,amount_local=qty*price+5 WHERE id=?",bad.item());
                db.update("INSERT INTO commercial_probe(order_type,order_id,status)VALUES(?,?,'PENDING')",kind,bad.order());
            }),null);
            assertThat(decimal("SELECT amount_original FROM "+bad.lines()+" WHERE id=?",bad.item())).isEqualByComparingTo("105");
        }
    }

    @Test void javaAndDatabaseAgreeOnReferencesAndExactRevisionRatios(){
        for(String rawQty:List.of("3","6","3000","99999999999999","0.0001")){
            BigDecimal qty=new BigDecimal(rawQty);
            for(String rawTotal:List.of("0","100","1.000000000000000000000001")){
                BigDecimal total=new BigDecimal(rawTotal);
                BigDecimal legacy=total.divide(qty,10,RoundingMode.DOWN);
                assertThat(decimal("SELECT fn_procurement_reference_price(?,?)",total,qty)).isEqualByComparingTo(legacy);
                assertThat(ProcurementReferencePrice.proofPrice(total,qty,null)).isEqualByComparingTo(legacy);
                BigDecimal modern=precision("money.reference-unit-price",10,()->MoneyPolicy.referenceUnitPrice(total,qty));
                // Current arithmetic preserves a finite quotient exactly; only repeating/oversized quotients use the declared choice.
                assertThat(decimal("SELECT fn_business_exact_divide_with_policy(?,?,'money.reference-unit-price','synthetic',24,?::jsonb,false)",
                    total,qty,"{\"version\":1,\"choices\":{\"money.reference-unit-price\":{\"scale\":10,\"rounding\":\"DOWN\"}}}")).isEqualByComparingTo(modern);
            }
        }
        assertThat(decimal("SELECT fn_procurement_revised_total_input(100,3000,6000)")).isEqualByComparingTo(MoneyPolicy.revisedTotalAmountInput(new BigDecimal("100"),new BigDecimal("3000"),new BigDecimal("6000")));
        assertThatThrownBy(()->decimal("SELECT fn_procurement_revised_total_input(100,3000,1000)"))
            .isInstanceOf(RuntimeException.class).hasStackTraceContaining("UTEN_PRECISION_REQUIRED");
        assertThatThrownBy(()->MoneyPolicy.revisedTotalAmountInput(new BigDecimal("100"),new BigDecimal("3000"),new BigDecimal("1000")))
            .isInstanceOf(BusinessPrecisionRequiredException.class);
    }

    @Test void pendingFinanceFreezesTheNewFactWhileOrderIsStillDraft(){
        for(String kind:List.of("PURCHASE","SUBCONTRACT")){
            Fixture f=fixture(kind);UUID pending=submit(f);
            assertThat(decimal("SELECT status FROM "+f.headers()+" WHERE id=?",f.order())).isZero();
            String before=db.queryForObject("SELECT to_jsonb(i)::text FROM "+f.lines()+" i WHERE id=?",String.class,f.item());
            assertSqlRejected(()->db.update("UPDATE "+f.lines()+" SET total_amount_input=101 WHERE id=?",f.item()),null);
            assertThat(db.queryForObject("SELECT to_jsonb(i)::text FROM "+f.lines()+" i WHERE id=?",String.class,f.item())).isEqualTo(before);
            assertThat(db.queryForObject("SELECT status FROM procurement_order_approval_cases WHERE id=?",String.class,pending)).isEqualTo("PENDING");
        }
    }

    @Test void provenRevisionUpdatesTotalBasisAndHeaderWithoutReapplyingOldApproximatePrice(){
        for(String kind:List.of("PURCHASE","SUBCONTRACT")){
            Fixture f=fixture(kind);UUID first=submit(f);approve(f,first);
            String before=db.queryForObject("SELECT to_jsonb(i)::text FROM "+f.lines()+" i WHERE id=?",String.class,f.item());
            login(f.owner());var change=new OrderQtyChangeRequest(List.of(new OrderQtyChangeItem(f.item(),new BigDecimal("6000"))));
            if(kind.equals("PURCHASE"))purchases.changeQty(f.order(),change);else subcontracts.changeQty(f.order(),change);
            assertThat(decimal("SELECT total_amount_input FROM "+f.lines()+" WHERE id=?",f.item())).isEqualByComparingTo("200");
            assertThat(decimal("SELECT amount_original FROM "+f.lines()+" WHERE id=?",f.item())).isEqualByComparingTo("205");
            assertThat(decimal("SELECT total_original FROM "+f.headers()+" WHERE id=?",f.order())).isEqualByComparingTo("205");
            assertThat(decimal("SELECT price FROM "+f.lines()+" WHERE id=?",f.item())).isEqualByComparingTo("0.0333333333");
            assertThat(db.queryForObject("SELECT before_item::text FROM procurement_order_source_revisions WHERE order_type=? AND order_id=?",String.class,kind,f.order())).isEqualTo(before);
            assertThat(db.queryForObject("SELECT fn_procurement_reference_price_matches(to_jsonb(i)) FROM "+f.lines()+" i WHERE id=?",Boolean.class,f.item())).isTrue();
            assertThat(db.queryForObject("SELECT reference_price_precision_policy->>'kind' FROM "+f.lines()+" WHERE id=?",String.class,f.item())).isEqualTo("PROCUREMENT_REFERENCE_PRICE_REVISION");
            assertSqlRejected(()->db.update("UPDATE "+f.lines()+" SET total_amount_input=201 WHERE id=?",f.item()),null);
            assertThat(decimal("SELECT count(*) FROM procurement_order_approval_cases WHERE order_type=? AND order_id=? AND status='PENDING'",kind,f.order())).isEqualByComparingTo("1");
        }
    }

    private Fixture fixture(String kind){
        Object world=call(harness,"seedWorld","total-input-"+UUID.randomUUID());UUID owner=call(world,"superAdminUserId");login(owner);
        UUID reviewer=call(harness,"createUserWithPerms",world,"total-review-"+UUID.randomUUID(),new String[]{"finance_order_approval:view","finance_order_approval:approve"});
        login(owner);UUID unit=call(world,"unitId"),goods=call(world,kind.equals("PURCHASE")?"goodsD":"goodsE"),supplier=call(world,"supplierId"),warehouse=call(world,"warehouseId");
        UUID currency=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted",UUID.class);
        UUID settlement=db.queryForObject("SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted ORDER BY code LIMIT 1",UUID.class);
        String prefix=kind.equals("PURCHASE")?"purchase":"subcontract";
        var fee=columns.create(new BusinessColumnService.Create(prefix+"_order","包装费","AMOUNT","ADD"));
        UUID order;
        if(kind.equals("PURCHASE")){
            var request=new com.uten.imp.features.purchase.request.dto.RequestSaveRequest();request.setBillDate(BusinessTime.today());request.setWarehouseId(warehouse);
            var source=new com.uten.imp.features.purchase.request.dto.RequestItemLine();source.setGoodsId(goods);source.setUnitId(unit);source.setUnitRate(BigDecimal.ONE);source.setQty(new BigDecimal("10000"));request.setItems(List.of(source));
            var saved=requests.create(request);requests.approve(saved.getId());
            var body=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();body.setBillDate(BusinessTime.today());body.setSupplierId(supplier);body.setWarehouseId(warehouse);body.setCurrencyId(currency);body.setExchangeRate(BigDecimal.ONE);body.setTaxRate(BigDecimal.ZERO);body.setSettlementMethodId(settlement);
            var line=new com.uten.imp.features.purchase.order.dto.OrderItemLine();line.setGoodsId(goods);line.setUnitId(unit);line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal("3000"));line.setTotalAmountInput(new BigDecimal("100"));line.setRequestItemId(saved.getItems().getFirst().getId());line.setExtraColumns(List.of(new ExtraColumnInput(fee.id(),"5")));body.setItems(List.of(line));
            order=precision("money.reference-unit-price",10,()->purchases.create(body).getId());
        }else{
            UUID material=call(harness,"addSubcontractDirectMaterial",world,goods,"1");call(harness,"receiveSubcontractMaterial",world,material,"10000");
            var body=new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();body.setBillDate(BusinessTime.today());body.setSupplierId(supplier);body.setWarehouseId(warehouse);body.setCurrencyId(currency);body.setExchangeRate(BigDecimal.ONE);body.setTaxRate(BigDecimal.ZERO);body.setSettlementMethodId(settlement);
            var line=new com.uten.imp.features.subcontract.order.dto.OrderItemLine();line.setGoodsId(goods);line.setUnitId(unit);line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal("3000"));line.setTotalAmountInput(new BigDecimal("100"));line.setExtraColumns(List.of(new ExtraColumnInput(fee.id(),"5")));body.setItems(List.of(line));
            order=precision("money.reference-unit-price",10,()->subcontracts.create(body).getId());
        }
        UUID item=db.queryForObject("SELECT id FROM "+prefix+"_order_items WHERE order_id=?",UUID.class,order);
        return new Fixture(kind,prefix,owner,reviewer,order,item);
    }
    private UUID submit(Fixture f){login(f.owner());finance.submit(f.kind(),f.order());return db.queryForObject("SELECT id FROM procurement_order_approval_cases WHERE order_type=? AND order_id=? AND status='PENDING'",UUID.class,f.kind(),f.order());}
    private void approve(Fixture f,UUID id){login(f.reviewer());long version=db.queryForObject("SELECT version FROM procurement_order_approval_cases WHERE id=?",Long.class,id);UUID claim=claims.claim("PROCUREMENT_FINANCE_APPROVE",id.toString()).claimId();finance.approveBatch(List.of(new BatchDecisionItem(id,version,claim)),null,BigDecimal.ONE);login(f.owner());}
    private void login(UUID user){call(harness,"loginAs",user);}
    private BigDecimal decimal(String sql,Object...args){return db.queryForObject(sql,BigDecimal.class,args);}
    private static void assertSqlRejected(Runnable action,String message){
        var check=assertThatThrownBy(action::run).isInstanceOf(DataAccessException.class).satisfies(failure->{
            Throwable cause=failure;while(cause.getCause()!=null)cause=cause.getCause();
            assertThat(cause).isInstanceOf(java.sql.SQLException.class);
            assertThat(((java.sql.SQLException)cause).getSQLState()).isIn("23514","55000");
        });if(message!=null)check.hasStackTraceContaining(message);
    }
    @SuppressWarnings("try")
    private static <T>T precision(String key,int scale,Supplier<T> body){try(var choice=BusinessPrecisionContext.use(Map.of(key,new BusinessPrecisionContext.Choice(scale,"DOWN")))){return body.get();}catch(RuntimeException|Error failure){throw failure;}catch(Exception failure){throw new AssertionError(failure);}}
    @SuppressWarnings("unchecked") private static <T>T call(Object target,String method,Object...args){return (T)ReflectionTestUtils.invokeMethod(target,method,args);}
    private record Fixture(String kind,String prefix,UUID owner,UUID reviewer,UUID order,UUID item){String headers(){return prefix+"_orders";}String lines(){return prefix+"_order_items";}}
}
