package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.subcontract.draw.SubcontractDrawCommandService;
import com.uten.imp.features.subcontract.draw.SubcontractDrawContracts.*;
import com.uten.imp.features.subcontract.draw.SubcontractDrawQueryService;
import com.uten.imp.features.subcontract.material_issue.SubcontractSelectedOutboundContracts.Request;
import com.uten.imp.features.subcontract.material_issue.SubcontractSelectedOutboundService;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemLine;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueSaveRequest;
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
import java.util.Map;
import java.util.UUID;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false","uten.concurrency.verify-nested-footprint=true",
        "uten.workshop-material.auto-close.enabled=false","uten.inventory.value-work.enabled=false","uten.policy-intelligence.enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class SubcontractSelectedOutboundQuantityTopUpPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry properties){FullChainEndToEndTest.registerDataSource(properties);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SubcontractSelectedOutboundService commands;
    @Autowired SubcontractDrawQueryService queries;
    @Autowired SubcontractDrawCommandService draws;
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test void shortSelectedAIsCompletedByANewPlanDrawWithoutRepeatingPendingB() {
        var fixture=new SubcontractSelectedOutboundEndToEndTest();beans.autowireBean(fixture);fixture.setup();
        var s=fixture.scenario(false,world->{});
        String originalB=row(s.bItem()),originalBReservation=reservations(s.source(),s.b());
        var firstRequest=fixture.request(s,s.aItem(),"6");
        var first=commands.execute(s.source(),firstRequest);
        amount("10",plan(s.orderItem(),s.a(),"planned_qty"));amount("6",plan(s.orderItem(),s.a(),"issued_qty"));
        amount("4",db.queryForObject("SELECT needed_qty-sent_qty-pending_qty FROM fn_subcontract_draw_facts(?) WHERE goods_id=?",BigDecimal.class,s.orderItem(),s.a()));
        amount("20",db.queryForObject("SELECT pending_qty FROM fn_subcontract_draw_facts(?) WHERE goods_id=?",BigDecimal.class,s.orderItem(),s.b()));
        unchangedB(s,originalB,originalBReservation);

        // ADR-143 2026-11-09 按行领料契约: 候选行 = 每条开放计划行 × 此刻有量的仓。只有 A 的补领 4 有默认量;
        // B 的 20 已全数待仓库发、库存被原草稿占着, 只留一条「未确定」仓位、不可输入的 0 行(任务不静默消失)。
        var preview=queries.preview(new DrawPreviewRequest(List.of(new DrawItemRequest(s.orderItem(),null))));
        assertThat(preview.lines()).hasSize(2);
        var topUpRow=candidate(preview,s.a());var pendingRow=candidate(preview,s.b());
        assertThat(topUpRow.warehouseId()).isEqualTo(s.world().warehouseId());
        amount("4",topUpRow.qty());amount("4",topUpRow.warehouseAvailableQty());
        assertThat(pendingRow.warehouseId()).isNull();
        amount("0",pendingRow.qty());amount("0",pendingRow.warehouseAvailableQty());
        amount("4",preview.tasks().getFirst().qty());
        // 待发的 B 不能再领一份: 未确定仓位的行交不上去; 绕过页面按原仓直接给 B 下行, 服务端同样拒绝且什么都不写。
        UUID bPlan=pendingRow.planItemId();int pendingBefore=pendingLines(s.orderItem());
        assertThatThrownBy(()->queries.preview(new DrawPreviewRequest(List.of(lines(s.orderItem(),
                new DrawLineRequest(bPlan,null,BigDecimal.ONE))))))
                .isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED));
        assertThatThrownBy(()->draws.submit(new DrawSubmitRequest(List.of(lines(s.orderItem(),
                new DrawLineRequest(bPlan,s.world().warehouseId(),new BigDecimal("20")))),"short-selected-repeat-b-"+UUID.randomUUID())))
                .isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));
        assertThat(pendingLines(s.orderItem())).isEqualTo(pendingBefore);unchangedB(s,originalB,originalBReservation);
        // 领料页照候选行提交(lines): 只带仓已确定且数量 > 0 的行 = A@仓 4, B 的 0 行不进入提交。
        var submitted=preview.lines().stream().filter(line->line.warehouseId()!=null&&line.qty().signum()>0)
                .map(line->new DrawLineRequest(line.planItemId(),line.warehouseId(),line.qty())).toList();
        assertThat(submitted).extracting(DrawLineRequest::planItemId).containsExactly(topUpRow.planItemId());
        var topUp=draws.submit(new DrawSubmitRequest(List.of(lines(s.orderItem(),submitted.toArray(DrawLineRequest[]::new))),
                "short-selected-topup-"+UUID.randomUUID()));
        assertThat(topUp.issueIds()).hasSize(1);UUID topUpId=topUp.issueIds().getFirst();
        assertThat(topUpId).isNotEqualTo(s.source()).isNotEqualTo(first.executionIssueId());
        // B 进了空闲库存后候选行变成可输入的 0 行, 但需求已被待发全数覆盖: 填数只得到行级上限 0 的 409, 不会重复领。
        ReflectionTestUtils.invokeMethod(fixture.h,"otherIn",s.world(),s.world().warehouseId(),s.b(),null,"5","5");
        var freeB=candidate(queries.preview(new DrawPreviewRequest(List.of(new DrawItemRequest(s.orderItem(),null)))),s.b());
        assertThat(freeB.warehouseId()).isEqualTo(s.world().warehouseId());
        amount("0",freeB.qty());amount("5",freeB.warehouseAvailableQty());
        var repeatB=lines(s.orderItem(),new DrawLineRequest(bPlan,s.world().warehouseId(),new BigDecimal("5")));
        int pendingWithTopUp=pendingLines(s.orderItem());
        assertThatThrownBy(()->queries.preview(new DrawPreviewRequest(List.of(repeatB))))
                .isInstanceOfSatisfying(ApiException.class,error->rejectedAtZeroRowMaximum(error,s.orderItem(),bPlan));
        assertThatThrownBy(()->draws.submit(new DrawSubmitRequest(List.of(repeatB),"short-selected-repeat-free-b-"+UUID.randomUUID())))
                .isInstanceOfSatisfying(ApiException.class,error->rejectedAtZeroRowMaximum(error,s.orderItem(),bPlan));
        assertThat(pendingLines(s.orderItem())).isEqualTo(pendingWithTopUp);unchangedB(s,originalB,originalBReservation);
        var topUpReview=commands.review(topUpId);assertThat(topUpReview.document().getItems()).hasSize(1);
        var supplement=topUpReview.document().getItems().getFirst();
        assertThat(supplement.getGoodsId()).isEqualTo(s.a());
        amount("4",supplement.getQty());amount("4",supplement.getRequestedQty());
        unchangedB(s,originalB,originalBReservation);

        var body=new MaterialIssueSaveRequest();body.setBillDate(topUpReview.document().getBillDate());
        body.setWarehouseId(topUpReview.document().getWarehouseId());body.setSupplierId(topUpReview.document().getSupplierId());
        var line=new MaterialIssueItemLine();line.setId(supplement.getId());line.setPlanItemId(supplement.getPlanItemId());
        line.setOrderItemId(supplement.getOrderItemId());line.setGoodsId(supplement.getGoodsId());line.setColorId(supplement.getColorId());
        line.setUnitId(supplement.getUnitId());line.setUnitRate(supplement.getUnitRate());line.setQty(new BigDecimal("4"));body.setItems(List.of(line));
        commands.execute(topUpId,new Request("short-selected-issue-topup-"+UUID.randomUUID(),topUpReview.fingerprint(),List.of(supplement.getId()),body));
        amount("10",plan(s.orderItem(),s.a(),"issued_qty"));amount("0",plan(s.orderItem(),s.b(),"issued_qty"));
        unchangedB(s,originalB,originalBReservation);
        commands.execute(s.source(),fixture.request(s,s.bItem(),"20"));
        amount("10",plan(s.orderItem(),s.a(),"planned_qty"));amount("20",plan(s.orderItem(),s.b(),"planned_qty"));
        amount("10",plan(s.orderItem(),s.a(),"issued_qty"));amount("20",plan(s.orderItem(),s.b(),"issued_qty"));
        var summary=db.queryForMap("SELECT * FROM fn_subcontract_draw_summary(?)",s.orderItem());
        amount("10",(BigDecimal)summary.get("drawn_qty"));amount("0",(BigDecimal)summary.get("pending_qty"));
        amount("0",(BigDecimal)summary.get("drawable_qty"));assertThat(summary.get("all_sent")).isEqualTo(true);
        amount("10",supplier(s.orderItem(),s.a()));amount("20",supplier(s.orderItem(),s.b()));
        assertThat(pendingLines(s.orderItem())).isZero();
        assertThat(commands.execute(s.source(),firstRequest)).isEqualTo(first);
        assertThat(db.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_id IN (?,?,?)",Integer.class,s.source(),first.executionIssueId(),topUpId)).isEqualTo(3);
        System.out.println("SC_SHORT_TOPUP_PASS: first A=6; pending B=20 unchanged; new draw only A=4 (B 0-row, repeat B rejected); final issued A=10/B=20; pending=0; replay movements=3");
    }
    private static DrawPreviewLine candidate(DrawPreview preview,UUID goods){
        var rows=preview.lines().stream().filter(line->line.goodsId().equals(goods)).toList();
        assertThat(rows).as("goods %s candidate rows in %s",goods,preview.lines()).hasSize(1);return rows.getFirst();
    }
    private static DrawItemRequest lines(UUID orderItem,DrawLineRequest...lines){return new DrawItemRequest(orderItem,null,null,null,List.of(lines));}
    private static void rejectedAtZeroRowMaximum(ApiException error,UUID orderItem,UUID plan){
        assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
        assertThat(error.details()).containsEntry("kind","SUBCONTRACT_DRAW_QUANTITY_EXCEEDED")
                .containsEntry("quantities",List.of(Map.of("orderItemId",orderItem,"planItemId",plan,"maximumQtyExact","0")));
    }
    private void unchangedB(SubcontractSelectedOutboundEndToEndTest.Scenario s,String row,String reservations){assertThat(row(s.bItem())).isEqualTo(row);assertThat(reservations(s.source(),s.b())).isEqualTo(reservations);}
    private int pendingLines(UUID orderItem){return db.queryForObject("SELECT count(*) FROM subcontract_material_issue_items item JOIN subcontract_material_issues issue ON issue.id=item.issue_id WHERE item.order_item_id=? AND issue.status=0 AND NOT issue.is_deleted AND NOT item.is_deleted",Integer.class,orderItem);}
    private String row(UUID id){return db.queryForObject("SELECT to_jsonb(item)::text FROM subcontract_material_issue_items item WHERE id=?",String.class,id);}
    private String reservations(UUID source,UUID goods){return db.queryForObject("SELECT jsonb_agg(to_jsonb(r) ORDER BY id)::text FROM stock_reservations r WHERE source_doc_id=? AND goods_id=?",String.class,source,goods);}
    private BigDecimal plan(UUID orderItem,UUID goods,String field){return db.queryForObject("SELECT "+field+" FROM subcontract_material_plan_items WHERE order_item_id=? AND goods_id=? AND NOT is_deleted",BigDecimal.class,orderItem,goods);}
    private BigDecimal supplier(UUID orderItem,UUID goods){return db.queryForObject("SELECT sum(supplier_ending) FROM subcontract_material_issue_items WHERE order_item_id=? AND goods_id=? AND NOT is_deleted",BigDecimal.class,orderItem,goods);}
    private void amount(String expected,BigDecimal actual){assertThat(actual).isEqualByComparingTo(expected);}
}
