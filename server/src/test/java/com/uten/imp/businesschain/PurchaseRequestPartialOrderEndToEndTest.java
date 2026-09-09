package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.BatchDecisionItem;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.FinanceApproval;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.order.dto.OrderDetail;
import com.uten.imp.features.purchase.order.dto.OrderItemLine;
import com.uten.imp.features.purchase.order.dto.OrderSaveRequest;
import com.uten.imp.features.purchase.request.PurchaseRequestService;
import com.uten.imp.features.purchase.request.dto.RequestItemDto;
import com.uten.imp.features.purchase.request.dto.RequestItemLine;
import com.uten.imp.features.purchase.request.dto.RequestSaveRequest;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;

/** Actual approved request -> partial orders -> finance decisions, with no synthetic ordered quantities. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.policy-intelligence.enabled=false","uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class PurchaseRequestPartialOrderEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) { FullChainEndToEndTest.registerDataSource(registry); }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PurchaseRequestService requests;
    @Autowired PurchaseOrderService orders;
    @Autowired ProcurementFinanceApprovalService finance;
    @Autowired TaskClaimService claims;
    private FullChainEndToEndTest harness;
    @BeforeEach void prepare() { harness=new FullChainEndToEndTest();beans.autowireBean(harness); }
    @AfterEach void clearSecurity() { SecurityContextHolder.clearContext(); }

    @Test
    void applicantAndPartialCommitmentsStayConsistentAcrossDetailAndDecomposition() {
        Fixture f=fixture("partial-detail");
        var detail=requests.detail(f.request());
        assertThat(detail.getApplicantId()).isEqualTo(f.applicant());
        assertThat(detail.getApplicantName()).isEqualTo("分批申请人-partial-detail");
        assertThat(detail.getMakerId()).isEqualTo(f.world().employeeId()).isNotEqualTo(f.applicant());
        assertBalances(f,f.first(),"2","3","5");
        assertBalances(f,f.second(),"0","0","4");
        assertThat(requests.decompositionPreview(List.of(f.first(),f.first()))).hasSize(1);

        // Selecting just one line and a partial quantity does not copy the whole request.
        OrderDetail partial=createOrder(f,List.of(orderLine(f,f.first(),"2")));
        assertThat(partial.getItems()).hasSize(1);
        assertThat(partial.getItems().getFirst().getQty()).isEqualByComparingTo("2");
        assertThat(partial.getItems().getFirst().getRequestItemId()).isEqualTo(f.first());
        assertBalances(f,f.first(),"2","3","5"); // unsubmitted draft is not a financial commitment
        submit(f,partial.getId());
        assertBalances(f,f.first(),"2","5","3");
        assertBalances(f,f.second(),"0","0","4");
        assertThat(db.queryForList("SELECT request_item_id FROM purchase_order_item_sources WHERE order_item_id=?",UUID.class,
                partial.getItems().getFirst().getId())).containsExactly(f.first());
        assertThatThrownBy(()->finance.submit("PURCHASE",partial.getId())).isInstanceOf(ApiException.class);
        assertThat(db.queryForObject("SELECT count(*) FROM procurement_order_approval_cases WHERE order_id=? AND status='PENDING'",Integer.class,partial.getId())).isEqualTo(1);
        assertBalances(f,f.first(),"2","5","3");

        // A later batch explicitly chooses both lines with independent quantities.
        OrderDetail selected=createOrder(f,List.of(orderLine(f,f.first(),"1"),orderLine(f,f.second(),"2")));
        assertThat(selected.getItems()).hasSize(2);
        submit(f,selected.getId());
        assertBalances(f,f.first(),"2","6","2");
        assertBalances(f,f.second(),"0","2","2");
        assertThat(db.queryForObject("SELECT qty FROM purchase_request_items WHERE id=?",BigDecimal.class,f.first())).isEqualByComparingTo("10");
    }

    @Test
    void rejectionResubmissionAndOrderReversalRestoreOnlyTheirOwnCommittedQuantity() {
        Fixture f=fixture("partial-restore");
        reject(f,f.pendingOrder(),"本批先暂停采购");
        assertBalances(f,f.first(),"2","0","8");
        assertBalances(f,f.second(),"0","0","4");
        harness.loginAs(f.world().superAdminUserId());
        orders.reverse(f.approvedOrder());
        assertBalances(f,f.first(),"0","0","10");
        assertThatThrownBy(()->orders.reverse(f.approvedOrder())).isInstanceOf(ApiException.class);
        assertBalances(f,f.first(),"0","0","10");

        FinanceApproval secondAttempt=submit(f,f.pendingOrder());
        assertThat(secondAttempt.attempt()).isEqualTo(2);
        assertBalances(f,f.first(),"0","3","7");
        harness.loginAs(f.reviewer());
        BatchDecisionItem decision=decision(secondAttempt);
        finance.approveBatch(List.of(decision),"按本次申请分批采购");
        harness.loginAs(f.world().superAdminUserId());
        assertBalances(f,f.first(),"3","0","7");
        harness.loginAs(f.reviewer());
        assertThatThrownBy(()->finance.approveBatch(List.of(decision),"重复请求")).isInstanceOf(ApiException.class);
        harness.loginAs(f.world().superAdminUserId());
        assertBalances(f,f.first(),"3","0","7");
        orders.reverse(f.pendingOrder());
        assertBalances(f,f.first(),"0","0","10");
        assertThat(db.queryForObject("SELECT count(*) FROM procurement_order_approval_cases WHERE order_id=?",Integer.class,f.pendingOrder())).isEqualTo(2);
    }

    @Test
    void explicitOverbuyKeepsActualQuantityAndRemainingFloorWhileInvalidBatchRollsBack() {
        Fixture f=fixture("partial-overbuy");
        long before=orderCount(f);
        for(String invalid:List.of("0","-1")) {
            assertThatThrownBy(()->createOrder(f,List.of(orderLine(f,f.second(),"1"),orderLine(f,f.first(),invalid))))
                    .isInstanceOf(ApiException.class).hasMessageContaining("数量必须大于 0");
            assertThat(orderCount(f)).isEqualTo(before);
            assertBalances(f,f.first(),"2","3","5");
            assertBalances(f,f.second(),"0","0","4");
        }
        // Existing explicit overbuy policy is intentional: do not truncate 6 to the remaining 5.
        OrderDetail overbuy=createOrder(f,List.of(orderLine(f,f.first(),"6")));
        submit(f,overbuy.getId());
        assertBalances(f,f.first(),"2","9","0");
        assertThat(overbuy.getItems().getFirst().getQty()).isEqualByComparingTo("6");
        approve(f,overbuy.getId());
        assertBalances(f,f.first(),"8","3","0");
        assertThat(db.queryForObject("SELECT alloc_qty FROM purchase_order_item_sources WHERE order_item_id=?",BigDecimal.class,
                overbuy.getItems().getFirst().getId())).isEqualByComparingTo("6");
        reject(f,f.pendingOrder(),"取消未批准批次");
        assertBalances(f,f.first(),"8","0","2");
        orders.reverse(overbuy.getId());
        assertBalances(f,f.first(),"2","0","8");
    }

    private Fixture fixture(String tag) {
        var world=harness.seedWorld(tag);harness.loginAs(world.superAdminUserId());
        UUID applicant=UUID.randomUUID();
        db.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                VALUES (?,?,?,'其他',?,CURRENT_DATE,'active','regular')
                """,applicant,"APP-"+tag,"分批申请人-"+tag,world.departmentId());
        UUID reviewer=harness.createUserWithPerms(world,"REV-"+tag,"finance_order_approval:view","finance_order_approval:approve","finance_order_approval:reject");
        var request=new RequestSaveRequest();request.setBillDate(BusinessTime.today());request.setWarehouseId(world.warehouseId());
        request.setDepartmentId(world.departmentId());request.setApplicantId(applicant);
        request.setItems(List.of(requestLine(world,world.goodsD(),"10"),requestLine(world,world.goodsE(),"4")));
        var created=requests.create(request);requests.approve(created.getId());
        UUID first=created.getItems().getFirst().getId(),second=created.getItems().get(1).getId();
        var initial=new Fixture(world,applicant,reviewer,created.getId(),first,second,null,null);
        UUID approved=createOrder(initial,List.of(orderLine(initial,first,"2"))).getId();
        submit(initial,approved);approve(initial,approved);
        UUID pending=createOrder(initial,List.of(orderLine(initial,first,"3"))).getId();submit(initial,pending);
        return new Fixture(world,applicant,reviewer,created.getId(),first,second,approved,pending);
    }
    private RequestItemLine requestLine(FullChainEndToEndTest.World world,UUID goods,String qty) {
        var line=new RequestItemLine();line.setGoodsId(goods);line.setUnitId(world.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(qty));return line;
    }
    private OrderItemLine orderLine(Fixture f,UUID source,String qty) {
        RequestItemDto item=requests.detail(f.request()).getItems().stream().filter(row->row.getId().equals(source)).findFirst().orElseThrow();
        var line=new OrderItemLine();line.setGoodsId(item.getGoodsId());line.setUnitId(item.getUnitId());line.setUnitRate(item.getUnitRate());
        line.setRequestItemId(source);line.setQty(new BigDecimal(qty));line.setPrice(new BigDecimal("50"));
        line.setAmountOriginal(line.getQty().multiply(line.getPrice()));line.setAmountLocal(line.getAmountOriginal());return line;
    }
    private OrderDetail createOrder(Fixture f,List<OrderItemLine> lines) {
        harness.loginAs(f.world().superAdminUserId());
        var request=new OrderSaveRequest();request.setBillDate(BusinessTime.today());request.setSupplierId(f.world().supplierId());
        request.setWarehouseId(f.world().warehouseId());request.setCurrencyId(f.world().currencyId());request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);
        request.setSettlementMethodId(db.queryForObject("SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted ORDER BY code LIMIT 1",UUID.class));
        request.setItems(lines);var result=orders.createBatch(request);assertThat(result).hasSize(1);return result.getFirst();
    }
    private FinanceApproval submit(Fixture f,UUID order) {harness.loginAs(f.world().superAdminUserId());return finance.submit("PURCHASE",order);}
    private void approve(Fixture f,UUID order) {harness.loginAs(f.reviewer());harness.approvePendingFinance("PURCHASE",order);harness.loginAs(f.world().superAdminUserId());}
    private BatchDecisionItem decision(FinanceApproval approval) {
        var claim=claims.claim("PROCUREMENT_FINANCE_APPROVE",approval.caseId().toString());
        return new BatchDecisionItem(approval.caseId(),approval.version(),claim.claimId());
    }
    private void reject(Fixture f,UUID order,String reason) {
        harness.loginAs(f.reviewer());
        var raw=db.queryForObject("SELECT id,version FROM procurement_order_approval_cases WHERE order_type='PURCHASE' AND order_id=? AND status='PENDING'",
                (rs,row)->new BatchDecisionItem(rs.getObject(1,UUID.class),rs.getLong(2)),order);
        var claim=claims.claim("PROCUREMENT_FINANCE_APPROVE",raw.caseId().toString());
        finance.rejectBatch(List.of(new BatchDecisionItem(raw.caseId(),raw.expectedVersion(),claim.claimId())),reason);
        harness.loginAs(f.world().superAdminUserId());
    }
    private void assertBalances(Fixture f,UUID source,String ordered,String pending,String remaining) {
        var row=requests.detail(f.request()).getItems().stream().filter(item->item.getId().equals(source)).findFirst().orElseThrow();
        assertThat(row.getOrderedQty()).isEqualByComparingTo(ordered);assertThat(row.getPendingQty()).isEqualByComparingTo(pending);assertThat(row.getRemainingQty()).isEqualByComparingTo(remaining);
        if(new BigDecimal(remaining).signum()>0) {
            var preview=requests.decompositionPreview(List.of(source)).getFirst();
            assertThat(preview.orderedQty()).isEqualByComparingTo(ordered);assertThat(preview.pendingQty()).isEqualByComparingTo(pending);assertThat(preview.remainingQty()).isEqualByComparingTo(remaining);
            assertThat(preview.requestedQty()).isEqualByComparingTo(row.getQty());
        } else assertThatThrownBy(()->requests.decompositionPreview(List.of(source))).isInstanceOf(ApiException.class).hasMessageContaining("无可分解数量");
    }
    private long orderCount(Fixture f) {return db.queryForObject("SELECT count(*) FROM purchase_orders WHERE supplier_id=?",Long.class,f.world().supplierId());}
    private record Fixture(FullChainEndToEndTest.World world,UUID applicant,UUID reviewer,UUID request,UUID first,UUID second,UUID approvedOrder,UUID pendingOrder) {}
}
