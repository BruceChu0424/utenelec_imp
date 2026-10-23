package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.documents.DocumentUnapprovalService;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService;
import com.uten.imp.features.subcontract.material_issue.SubcontractSelectedOutboundContracts.Request;
import com.uten.imp.features.subcontract.material_issue.SubcontractSelectedOutboundService;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueDetail;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemLine;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueSaveRequest;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.boot.webmvc.test.autoconfigure.MockMvcPrint;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import java.math.BigDecimal;
import java.util.*;
import static com.uten.imp.testsupport.BusinessHttpRequests.authenticated;
import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

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
@AutoConfigureMockMvc(print=MockMvcPrint.NONE)
class SubcontractSelectedOutboundUnapprovalPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry properties){FullChainEndToEndTest.registerDataSource(properties);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SubcontractSelectedOutboundService commands;
    @Autowired SubcontractMaterialIssueService issues;
    @Autowired DocumentUnapprovalService unapprovals;
    @Autowired MockMvc http;
    @Autowired ObjectMapper json;
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test void fullApprovalPublicUnapprovalThenFullApprovalUsesNewHeaderAndRows() throws Exception {
        var fixture=fixture();var s=fixture.scenario(false,world->{});
        var firstRequest=command(s.source(),null);var first=commands.execute(s.source(),firstRequest);
        assertThat(first.executionIssueId()).isEqualTo(s.source());
        Set<UUID> originalRows=ids(issues.detail(s.source()));
        var draft=unapprove(s.source());assertNewIdentity(s.source(),originalRows,draft);
        readyExactlyOnce(draft.getId());
        var reopened=unapprove(s.source());assertThat(reopened.getId()).isEqualTo(draft.getId());readyExactlyOnce(draft.getId());
        var next=commands.execute(draft.getId(),command(draft.getId(),null));
        assertThat(next.executionIssueId()).isEqualTo(draft.getId());
        assertThat(commands.execute(s.source(),firstRequest)).isEqualTo(first);
        assertThrows(ApiException.class,()->commands.execute(s.source(),new Request("old-reversed-"+UUID.randomUUID(),firstRequest.fingerprint(),firstRequest.itemIds(),firstRequest.document())));
        finalQuantities(s);
        System.out.println("SC_PUBLIC_UNAPPROVE_FULL_PASS: old header=-1; successor header/rows are fresh UUIDs; full selected approval succeeds; old receipt remains replay-only");
    }

    @Test void splitExecutionPublicUnapprovalThenFullApprovalKeepsOriginalBPending() throws Exception {
        var fixture=fixture();var s=fixture.scenario(false,world->{});
        String originalB=row(s.bItem()),originalReservations=reservations(s.source(),s.b());
        var first=commands.execute(s.source(),fixture.request(s,s.aItem(),"10"));
        Set<UUID> executionRows=ids(issues.detail(first.executionIssueId()));
        var draft=unapprove(first.executionIssueId());assertNewIdentity(first.executionIssueId(),executionRows,draft);
        assertThat(ids(draft)).doesNotContain(s.aItem());readyExactlyOnce(draft.getId());
        commands.execute(draft.getId(),command(draft.getId(),null));
        assertThat(row(s.bItem())).isEqualTo(originalB);assertThat(reservations(s.source(),s.b())).isEqualTo(originalReservations);
        assertThat(db.queryForObject("SELECT is_deleted AND warehouse_split_at IS NOT NULL FROM subcontract_material_issue_items WHERE id=?",Boolean.class,s.aItem())).isTrue();
        assertThat(issues.detail(s.source()).getStatus()).isZero();
        amount("10",issued(s,s.a()));amount("0",issued(s,s.b()));
        System.out.println("SC_PUBLIC_UNAPPROVE_SPLIT_PASS: reversed S remains -1; fresh successor approves; original retired A stays retired; B row/reservations unchanged");
    }

    @Test void fullApprovalPublicUnapprovalThenPartialAAndRemainingBPreservesB() throws Exception {
        var fixture=fixture();var s=fixture.scenario(false,world->{});
        commands.execute(s.source(),command(s.source(),null));
        Set<UUID> originalRows=ids(issues.detail(s.source()));
        var draft=unapprove(s.source());assertNewIdentity(s.source(),originalRows,draft);readyExactlyOnce(draft.getId());
        UUID a=draft.getItems().stream().filter(line->line.getGoodsId().equals(s.a())).findFirst().orElseThrow().getId();
        UUID b=draft.getItems().stream().filter(line->line.getGoodsId().equals(s.b())).findFirst().orElseThrow().getId();
        String beforeB=row(b),beforeReservation=reservations(draft.getId(),s.b());
        var partial=commands.execute(draft.getId(),command(draft.getId(),Set.of(a)));
        assertThat(partial.executionIssueId()).isNotEqualTo(draft.getId());
        assertThat(row(b)).isEqualTo(beforeB);assertThat(reservations(draft.getId(),s.b())).isEqualTo(beforeReservation);
        var remainder=commands.execute(draft.getId(),command(draft.getId(),Set.of(b)));
        assertThat(remainder.executionIssueId()).isEqualTo(draft.getId());
        finalQuantities(s);
        System.out.println("SC_PUBLIC_UNAPPROVE_PARTIAL_PASS: successor partial A forks once; B stays untouched until its explicit command; final supplier A=10/B=20");
    }

    private SubcontractSelectedOutboundEndToEndTest fixture(){var fixture=new SubcontractSelectedOutboundEndToEndTest();beans.autowireBean(fixture);fixture.setup();return fixture;}
    private MaterialIssueDetail unapprove(UUID original) throws Exception {
        var capability=unapprovals.capability("subcontractMaterialIssue",original);
        assertThat(capability.eligible()||"OPEN_SUCCESSOR".equals(capability.nextAction())).as(capability.reasons().toString()).isTrue();
        var actor=SecurityContextHolder.getContext().getAuthentication();
        var response=http.perform(post("/api/documents/subcontractMaterialIssue/"+original+"/unapprove")
                .with(authenticated(actor)).contentType(MediaType.APPLICATION_JSON).content(json.writeValueAsString(Map.of(
                        "idempotencyKey","sc-public-unapprove-"+UUID.randomUUID(),"reason","核对后按新草稿重新出仓",
                        "expectedSnapshot",capability.factsSnapshot())))).andReturn().getResponse();
        SecurityContextHolder.getContext().setAuthentication(actor);
        assertThat(response.getStatus()).as(response.getContentAsString()).isEqualTo(200);
        var payload=json.readTree(response.getContentAsString());UUID next=UUID.fromString(payload.path("id").asText());
        assertThat(payload.path("unapprovalOriginalId").asText()).isEqualTo(original.toString());
        return issues.detail(next);
    }
    private void assertNewIdentity(UUID original,Set<UUID> originalRows,MaterialIssueDetail draft){
        assertThat(draft.getId()).isNotEqualTo(original);assertThat(draft.getStatus()).isZero();
        assertThat(issues.detail(original).getStatus()).isEqualTo((short)-1);
        assertThat(ids(draft)).hasSize(originalRows.size()).doesNotContainAnyElementsOf(originalRows);
        assertThat(db.queryForObject("SELECT draft_id FROM document_unapprovals WHERE family='subcontractMaterialIssue' AND original_id=?",UUID.class,original)).isEqualTo(draft.getId());
    }
    private void readyExactlyOnce(UUID draft){assertThat(db.queryForObject("SELECT count(*) FROM business_outbox WHERE event_type='SUBCONTRACT_OUTBOUND_READY' AND aggregate_id=?",Integer.class,draft)).isEqualTo(1);}
    private Request command(UUID source,Set<UUID> selected){
        var review=commands.review(source);var document=review.document();var body=new MaterialIssueSaveRequest();
        body.setBillDate(document.getBillDate());body.setWarehouseId(document.getWarehouseId());body.setSupplierId(document.getSupplierId());
        List<MaterialIssueItemLine> lines=new ArrayList<>();
        for(var row:document.getItems())if(selected==null||selected.contains(row.getId())){
            var line=new MaterialIssueItemLine();line.setId(row.getId());line.setPlanItemId(row.getPlanItemId());line.setOrderItemId(row.getOrderItemId());
            line.setGoodsId(row.getGoodsId());line.setColorId(row.getColorId());line.setUnitId(row.getUnitId());line.setUnitRate(row.getUnitRate());line.setQty(row.getQty());lines.add(line);
        }
        body.setItems(lines);return new Request("sc-public-cycle-"+UUID.randomUUID(),review.fingerprint(),lines.stream().map(MaterialIssueItemLine::getId).toList(),body);
    }
    private Set<UUID> ids(MaterialIssueDetail detail){return detail.getItems().stream().map(row->row.getId()).collect(java.util.stream.Collectors.toSet());}
    private String row(UUID id){return db.queryForObject("SELECT to_jsonb(item)::text FROM subcontract_material_issue_items item WHERE id=?",String.class,id);}
    private String reservations(UUID source,UUID goods){return db.queryForObject("SELECT jsonb_agg(to_jsonb(r) ORDER BY id)::text FROM stock_reservations r WHERE source_doc_id=? AND goods_id=?",String.class,source,goods);}
    private BigDecimal issued(SubcontractSelectedOutboundEndToEndTest.Scenario s,UUID goods){return db.queryForObject("SELECT issued_qty FROM subcontract_material_plan_items WHERE order_item_id=? AND goods_id=? AND NOT is_deleted",BigDecimal.class,s.orderItem(),goods);}
    private void finalQuantities(SubcontractSelectedOutboundEndToEndTest.Scenario s){
        amount("10",issued(s,s.a()));amount("20",issued(s,s.b()));
        assertThat(db.queryForObject("SELECT all_sent FROM fn_subcontract_draw_summary(?)",Boolean.class,s.orderItem())).isTrue();
        amount("0",db.queryForObject("SELECT sum(qty) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,s.world().warehouseId(),s.a()));
        amount("0",db.queryForObject("SELECT sum(qty) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,s.world().warehouseId(),s.b()));
    }
    private void amount(String expected,BigDecimal actual){assertThat(actual).isEqualByComparingTo(expected);}
}
