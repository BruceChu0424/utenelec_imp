package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.documents.DocumentUnapprovalService;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.dto.*;
import com.uten.imp.features.stock.valuation.InventoryValueWorkService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.ProductionMaterialReturnConfirmRequest;
import com.uten.imp.application.port.InventoryProductionCostPort;
import com.uten.imp.application.port.InventoryPositionPort;
import com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService;
import com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest;
import org.junit.jupiter.api.*;
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
import java.util.*;

import static org.assertj.core.api.Assertions.*;

/** Real committed Main V840/V3 plus Root V851 review and unapproval; never a V2 proxy for V3. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK, properties={
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false", "uten.production.readiness-reconcile.enabled=false",
        "uten.inventory.value-work.enabled=false", "uten.workshop-material.auto-close.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only", "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only", "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
class DailyReportV3ReviewedSaveLifecyclePostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ProductionDailyReportService reports;
    @Autowired DocumentUnapprovalService unapproval;
    @Autowired InventoryProductionCostPort costs;
    @Autowired InventoryPositionPort positions;
    @Autowired ProductionMaterialReturnRequestService returns;
    WorkshopPublicSurplusEndToEndTest workshop;
    FullChainEndToEndTest harness;

    @BeforeEach void prepare(){
        assertThat(db.queryForObject("SELECT COUNT(*) FROM flyway_schema_history WHERE success AND version IS NOT NULL",Integer.class)).isEqualTo(com.uten.imp.migration.MigrationRehearsalSupport.CURRENT_MIGRATION_COUNT);
        assertThat(db.queryForObject("SELECT script FROM flyway_schema_history WHERE success AND version='840'",String.class)).isEqualTo("V840__daily_report_material_review_decisions.sql");
        assertThat(db.queryForObject("SELECT script FROM flyway_schema_history WHERE success AND version='851'",String.class)).isEqualTo("V851__document_unapproval_successor_drafts.sql");
        workshop=new WorkshopPublicSurplusEndToEndTest();beans.autowireBean(workshop);workshop.prepare();
        harness=(FullChainEndToEndTest)ReflectionTestUtils.getField(workshop,"fixture");
        assertThat(harness).isNotNull();
    }
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test @Order(1)
    void makerSaveThenReadonlyV3KeepUnapprovalAndNewGenerationConserveExactUseAndCost(){
        Task task=task("v3-reviewed-keep");
        DailyReportDetail original=create(task,"4.1256","4.0001",false);
        Map<String,Object> authors=authors(original.getId());
        UUID originalLine=original.getItems().getFirst().getId();
        UUID reviewer=reviewer(task);harness.loginAs(reviewer);
        var previousMaterial=reports.materialReview(original.getId());
        var amendment=input(task,"6.1256","5.2504",false);
        amendment.setExpectedVersion(original.getRowVersion());
        amendment.getItems().getFirst().setDefectQty(new BigDecimal("1.1256"));
        assertThatThrownBy(()->reports.update(original.getId(),amendment))
                .isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.FORBIDDEN));
        harness.loginAs(task.world().superAdminUserId());
        var saved=reports.update(original.getId(),amendment);
        harness.loginAs(reviewer);
        assertThat(saved.getStatus()).isZero();
        assertThat(saved.getRowVersion()).isGreaterThan(original.getRowVersion());
        // Main reconstructs draft output slices; the original reviewed business source cannot change.
        assertThat(saved.getItems().getFirst().getId()).isNotEqualTo(originalLine);
        var originalSource=original.getItems().getFirst();var savedSource=saved.getItems().getFirst();
        assertThat(savedSource.getPlanItemId()).isEqualTo(originalSource.getPlanItemId());
        assertThat(savedSource.getExecutionSegmentId()).isEqualTo(originalSource.getExecutionSegmentId());
        assertThat(savedSource.getExecutionSegmentSalesAllocationId()).isEqualTo(originalSource.getExecutionSegmentSalesAllocationId());
        assertThat(savedSource.getSalesOrderItemId()).isEqualTo(originalSource.getSalesOrderItemId());
        assertThat(savedSource.getGoodsId()).isEqualTo(originalSource.getGoodsId());
        assertThat(savedSource.getDestination()).isEqualTo(originalSource.getDestination());
        assertThat(savedSource.getDirectTransferDemandId()).isEqualTo(originalSource.getDirectTransferDemandId());
        assertThat(authors(original.getId())).isEqualTo(authors);
        qty("6.1256",saved.getItems().getFirst().getQty());qty("1.1256",saved.getItems().getFirst().getDefectQty());
        qty("5.2504",saved.getMaterialUsages().getFirst().getQtyBase());
        qty("0",finished(task));qty("0",consumed(task));
        qty("0",scalar("SELECT COUNT(*) FROM production_material_settlement_events WHERE daily_report_id=?",original.getId()));
        qty("0",scalar("SELECT COUNT(*) FROM production_daily_report_commands WHERE report_id=? AND command_kind='APPROVE'",original.getId()));
        var fresh=reports.materialReview(saved.getId());
        assertThat(fresh.reportVersion()).isEqualTo(saved.getRowVersion());
        assertThat(fresh.fingerprint()).isNotEqualTo(previousMaterial.fingerprint()).matches("[a-f0-9]{64}");
        assertThat(fresh.rows()).hasSize(1);var row=fresh.rows().getFirst();
        assertThat(row.demandId()).isEqualTo(task.demand());qty("10.1256",row.availableQty());
        qty("5.2504",row.usageQty());qty("4.8752",row.remainingIssuedQty());assertThat(row.canReturn()).isFalse();
        var stale=request(previousMaterial,"KEEP","v3-stale-"+UUID.randomUUID());
        assertThatThrownBy(()->reports.approve(saved.getId(),stale)).isInstanceOf(ApiException.class);
        var missing=request(fresh,"KEEP","v3-missing-"+UUID.randomUUID());missing.setMaterialDecisions(List.of());
        assertThatThrownBy(()->reports.approve(saved.getId(),missing)).isInstanceOf(ApiException.class).hasMessageContaining("全部材料");
        qty("0",finished(task));qty("0",consumed(task));

        var command=request(fresh,"KEEP","v3-keep-"+UUID.randomUUID());
        var approved=reports.approve(saved.getId(),command);assertV3(approved,command,false);
        assertThat(authors(saved.getId())).isEqualTo(authors);
        qty("6.1256",finished(task));qty("5.2504",consumed(task));
        assertStoredV3(saved.getId(),fresh,"KEEP");
        var facts=ledgerFacts();assertV3(reports.approve(saved.getId(),command),command,true);assertThat(ledgerFacts()).isEqualTo(facts);
        var changed=request(fresh,"RETURN",command.getIdempotencyKey());
        assertThatThrownBy(()->reports.approve(saved.getId(),changed)).isInstanceOf(ApiException.class).hasMessageContaining("不同");
        assertThat(ledgerFacts()).isEqualTo(facts);
        drain(task);assertOriginalUseCost(task,saved.getId(),"52.504");

        var eligibility=unapproval.capability("productionDailyReport",saved.getId());
        assertThat(eligibility.eligible()).as("real V3 KEEP before any finished receipt: %s",eligibility.reasons()).isTrue();
        var successor=(DailyReportDetail)unapproval.unapprove("productionDailyReport",saved.getId(),
                new DocumentUnapprovalService.UnapproveRequest("v3-unapprove-"+UUID.randomUUID(),"复核日报真实数量和用料",eligibility.factsSnapshot()));
        assertThat(successor.getId()).isNotEqualTo(saved.getId());assertThat(successor.getStatus()).isZero();
        assertSuccessorAuthors(saved.getId(),successor.getId(),authors);
        assertThat(successor.getItems().getFirst().getId()).isNotEqualTo(originalLine);
        assertThat(successor.getItems().getFirst().getPlanItemId()).isEqualTo(task.planItem());
        qty("6.1256",successor.getItems().getFirst().getQty());qty("5.2504",successor.getMaterialUsages().getFirst().getQtyBase());
        qty("0",finished(task));qty("0",consumed(task));
        facts=ledgerFacts();assertV3(reports.approve(saved.getId(),command),command,true);assertThat(ledgerFacts()).isEqualTo(facts);
        assertThat(reports.detail(saved.getId()).getStatus()).isEqualTo((short)-1);
        var nextReview=reports.materialReview(successor.getId());
        var nextCommand=request(nextReview,"KEEP","v3-successor-"+UUID.randomUUID());
        assertV3(reports.approve(successor.getId(),nextCommand),nextCommand,false);
        facts=ledgerFacts();assertV3(reports.approve(successor.getId(),nextCommand),nextCommand,true);assertThat(ledgerFacts()).isEqualTo(facts);
        var retry=(DailyReportDetail)unapproval.unapprove("productionDailyReport",saved.getId(),
                new DocumentUnapprovalService.UnapproveRequest("v3-new-retry-"+UUID.randomUUID(),"原审核已撤回后的晚重试",eligibility.factsSnapshot()));
        assertThat(retry.getId()).isEqualTo(successor.getId());assertThat(retry.getStatus()).isEqualTo((short)1);
        qty("6.1256",finished(task));qty("5.2504",consumed(task));
        qty("1",scalar("SELECT COUNT(*) FROM document_unapprovals WHERE original_id=?",saved.getId()));
        drain(task);assertOriginalUseCost(task,successor.getId(),"52.504");
        qty("1989.8744",stock(task,task.material()));qty("0",stock(task,task.product()));
    }

    @Test @Order(2)
    void explicitReturnIsExactlyFourOnceAndMustBeResolvedBeforeTheOriginalApprovalCanBeWithdrawn(){
        Task task=task("v3-explicit-return");
        var draft=create(task,"10.1256","6.1256",true);
        UUID reviewer=reviewer(task);harness.loginAs(reviewer);
        var review=reports.materialReview(draft.getId());assertThat(review.rows()).hasSize(1);
        var row=review.rows().getFirst();assertThat(row.canReturn()).as(row.returnBlockedReason()).isTrue();
        qty("10.1256",row.availableQty());qty("6.1256",row.usageQty());qty("4",row.returnableIssuedQty());
        var command=request(review,"RETURN","v3-return-"+UUID.randomUUID());
        assertV3(reports.approve(draft.getId(),command),command,false);assertStoredV3(draft.getId(),review,"RETURN");
        var requests=returns.list(task.plan(),task.segment());assertThat(requests).hasSize(1);
        assertThat(requests.getFirst().status()).isEqualTo("PENDING");assertThat(requests.getFirst().lines()).hasSize(1);
        qty("4",requests.getFirst().lines().getFirst().qty());
        qty("6.1256",consumed(task));qty("10.1256",finished(task));
        qty("1989.8744",stock(task,task.material()));
        var before=ledgerFacts();assertV3(reports.approve(draft.getId(),command),command,true);assertThat(ledgerFacts()).isEqualTo(before);
        assertThat(returns.list(task.plan(),task.segment())).hasSize(1);
        var eligibility=unapproval.capability("productionDailyReport",draft.getId());
        assertThat(eligibility.supported()).isTrue();
        assertThat(eligibility.eligible()).as("pending reviewed return remains an effect of this V3 approval").isFalse();
        assertThat(eligibility.reasons().toString()).containsAnyOf("退料","余料");
        assertThatThrownBy(()->unapproval.unapprove("productionDailyReport",draft.getId(),
                new DocumentUnapprovalService.UnapproveRequest("v3-pending-return-block-"+UUID.randomUUID(),"须先撤回本次余料申请")))
                .isInstanceOf(ApiException.class).hasMessageMatching(".*(退料|余料).*" );
        assertThat(ledgerFacts()).isEqualTo(before);
        var pending=requests.getFirst();
        returns.cancel(task.plan(),pending.documentId(),new ProductionMaterialReturnRequest.Cancel("v3-cancel-return-"+UUID.randomUUID(),"撤回未实收的本次余料申请"));
        var ready=unapproval.capability("productionDailyReport",draft.getId());assertThat(ready.eligible()).as(ready.reasons().toString()).isTrue();
        assertThat(ready.factsSnapshot()).isNotEqualTo(eligibility.factsSnapshot());
        var successor=(DailyReportDetail)unapproval.unapprove("productionDailyReport",draft.getId(),
                new DocumentUnapprovalService.UnapproveRequest("v3-resolved-return-unapprove-"+UUID.randomUUID(),"已撤回原审核产生的待实收余料申请",ready.factsSnapshot()));
        assertThat(successor.getStatus()).isZero();qty("0",consumed(task));qty("0",finished(task));
        assertThat(returns.list(task.plan(),task.segment()).getFirst().status()).isEqualTo("CANCELLED");
        var successorReview=reports.materialReview(successor.getId());
        var successorCommand=request(successorReview,"RETURN","v3-reapproved-return-"+UUID.randomUUID());
        assertV3(reports.approve(successor.getId(),successorCommand),successorCommand,false);
        var repeated=ledgerFacts();assertV3(reports.approve(successor.getId(),successorCommand),successorCommand,true);assertThat(ledgerFacts()).isEqualTo(repeated);
        qty("6.1256",consumed(task));qty("10.1256",finished(task));
        var after=returns.list(task.plan(),task.segment());assertThat(after).hasSize(2);
        assertThat(after.stream().filter(rowValue->rowValue.status().equals("CANCELLED"))).hasSize(1);
        assertThat(after.stream().filter(rowValue->rowValue.status().equals("PENDING"))).hasSize(1);
        qty("4",after.stream().filter(rowValue->rowValue.status().equals("PENDING")).findFirst().orElseThrow().lines().getFirst().qty());
    }

    @Test @Order(3)
    void sourceBalanceChangeWithoutDocumentEditRejectsTheOldV3FingerprintBeforeAnyNewPosting(){
        Task task=task("v3-material-fence");var draft=create(task,"6.1256","5.2504",false);
        var old=reports.materialReview(draft.getId());long version=draft.getRowVersion();
        var other=create(task,"1","1",false);var current=reports.materialReview(other.getId());
        var otherCommand=request(current,"KEEP","v3-other-source-"+UUID.randomUUID());
        reports.approve(other.getId(),otherCommand);
        assertThat(reports.detail(draft.getId()).getRowVersion()).isEqualTo(version);
        var fresh=reports.materialReview(draft.getId());assertThat(fresh.fingerprint()).isNotEqualTo(old.fingerprint());
        qty("9.1256",fresh.rows().getFirst().availableQty());
        var before=ledgerFacts();
        ApiException blocked=catchThrowableOfType(ApiException.class,()->reports.approve(draft.getId(),request(old,"KEEP","v3-stale-material-"+UUID.randomUUID())));
        assertThat(blocked).isNotNull();assertThat(blocked.getCode()).isEqualTo(ErrorCode.DAILY_REPORT_MATERIAL_REVIEW_CONFLICT);
        assertThat(ledgerFacts()).isEqualTo(before);assertThat(reports.detail(draft.getId()).getStatus()).isZero();
        qty("1",finished(task));qty("1",consumed(task));
        qty("0",scalar("SELECT COUNT(*) FROM production_daily_report_commands WHERE report_id=? AND command_kind='APPROVE'",draft.getId()));
    }

    @Test @Order(4)
    void actualFinishedInboundBlocksV3UnapprovalAndPreservesQuantityAndTheOriginalKnownMaterialCost(){
        Task task=task("v3-finished-source");var draft=create(task,"10.1256","10.1256",true);
        var review=reports.materialReview(draft.getId());var command=request(review,"KEEP","v3-finished-"+UUID.randomUUID());
        reports.approve(draft.getId(),command);
        UUID inbound=call(workshop,"finishInbound",task.nativeTask(),draft.getId());
        qty("1",scalar("SELECT status FROM stock_documents WHERE id=?",inbound));
        qty("10.1256",stock(task,task.product()));qty("10.1256",finished(task));qty("10.1256",consumed(task));
        drain(task);var position=costs.position(task.segment());
        qty("101.256",position.actualKnownCostLocal());qty("101.256",position.allocatedToOutputsLocal());qty("0",position.heldWipLocal());
        var before=ledgerFacts();var capability=unapproval.capability("productionDailyReport",draft.getId());
        assertThat(capability.eligible()).isFalse();assertThat(capability.reasons().toString()).containsAnyOf("成品","仓库","入库");
        assertThatThrownBy(()->unapproval.unapprove("productionDailyReport",draft.getId(),
                new DocumentUnapprovalService.UnapproveRequest("v3-inbound-block-"+UUID.randomUUID(),"需先撤回已入库成品")))
                .isInstanceOf(ApiException.class);
        assertThat(ledgerFacts()).isEqualTo(before);qty("10.1256",stock(task,task.product()));
        qty("0",scalar("SELECT COUNT(*) FROM document_unapprovals WHERE original_id=?",draft.getId()));
        assertThat(reports.detail(draft.getId()).getStatus()).isEqualTo((short)1);
    }

    @Test @Order(5)
    void receivedReturnRequiresItsRealWarehouseReversalAndThenTheExactOriginalReportCanUnapprove(){
        Task task=task("v3-return-physical");var draft=create(task,"10.1256","6.1256",true);
        UUID reviewer=reviewer(task);harness.loginAs(reviewer);
        var review=reports.materialReview(draft.getId());
        var command=request(review,"RETURN","v3-physical-return-"+UUID.randomUUID());
        reports.approve(draft.getId(),command);var pending=returns.list(task.plan(),task.segment()).getFirst();
        harness.loginAs(task.world().superAdminUserId());var stock=beans.getBean(StockDocService.class);
        stock.confirmProductionMaterialReturn(pending.documentId(),new ProductionMaterialReturnConfirmRequest(task.world().warehouseId(),"v3-receive-return-"+UUID.randomUUID()));
        assertThat(returns.list(task.plan(),task.segment()).getFirst().status()).isEqualTo("RECEIVED");
        qty("1993.8744",stock(task,task.material()));qty("6.1256",consumed(task));
        drain(task);assertOriginalUseCost(task,draft.getId(),"61.256");
        harness.loginAs(reviewer);var blocked=unapproval.capability("productionDailyReport",draft.getId());
        assertThat(blocked.supported()).isTrue();assertThat(blocked.eligible()).isFalse();
        assertThat(blocked.reasons().toString()).contains("余料","实收");var before=ledgerFacts();
        assertThatThrownBy(()->unapproval.unapprove("productionDailyReport",draft.getId(),
                new DocumentUnapprovalService.UnapproveRequest("v3-received-return-block-"+UUID.randomUUID(),"先撤回仓库真实余料接收")))
                .isInstanceOf(ApiException.class).hasMessageContaining("实收");
        assertThat(ledgerFacts()).isEqualTo(before);qty("1993.8744",stock(task,task.material()));
        harness.loginAs(task.world().superAdminUserId());stock.reverse(pending.documentId());
        assertThat(returns.list(task.plan(),task.segment()).getFirst().status()).isEqualTo("REVERSED");
        qty("1989.8744",stock(task,task.material()));harness.loginAs(reviewer);
        var ready=unapproval.capability("productionDailyReport",draft.getId());
        assertThat(ready.eligible()).as("original warehouse return is really reversed: %s",ready.reasons()).isTrue();
        assertThat(ready.factsSnapshot()).isNotEqualTo(blocked.factsSnapshot());
        var successor=(DailyReportDetail)unapproval.unapprove("productionDailyReport",draft.getId(),
                new DocumentUnapprovalService.UnapproveRequest("v3-warehouse-resolved-unapprove-"+UUID.randomUUID(),"已按原仓库来源完整撤回本次余料",ready.factsSnapshot()));
        assertThat(successor.getStatus()).isZero();qty("0",consumed(task));qty("0",finished(task));
        qty("10.1256",scalar("SELECT SUM(fn_material_issue_available(id,NULL)) FROM production_material_stock_postings WHERE demand_id=? AND posting_type='ISSUE'",task.demand()));
        assertThat(returns.list(task.plan(),task.segment()).getFirst().status()).isEqualTo("REVERSED");
        qty("1",scalar("SELECT COUNT(*) FROM document_unapprovals WHERE original_id=?",draft.getId()));
    }

    @Test @Order(6)
    void legacyV2GeneratedReturnAlsoBlocksGenericRecoveryUntilItsNormalCancellation(){
        Task task=task("v2-return-source");var input=input(task,"10.1256","6.1256",true);
        input.setSurplusReturnRequested(true);var draft=reports.create(input);
        UUID reviewer=reviewer(task);harness.loginAs(reviewer);
        var command=new DailyReportApproveRequest();command.setCommandVersion(2);command.setExpectedVersion(draft.getRowVersion());
        command.setIdempotencyKey("v2-pending-return-"+UUID.randomUUID());
        var approved=reports.approve(draft.getId(),command);assertThat(approved.getApprovalReceipt().commandVersion()).isEqualTo(2);
        var requests=returns.list(task.plan(),task.segment());assertThat(requests).hasSize(1);
        var pending=requests.getFirst();assertThat(pending.status()).isEqualTo("PENDING");qty("4",pending.lines().getFirst().qty());
        qty("6.1256",consumed(task));qty("10.1256",finished(task));assertOriginalUseCost(task,draft.getId(),"61.256");
        var before=ledgerFacts();var capability=unapproval.capability("productionDailyReport",draft.getId());
        assertThat(capability.supported()).isTrue();assertThat(capability.eligible()).isFalse();assertThat(capability.reasons().toString()).contains("余料");
        assertThatThrownBy(()->unapproval.unapprove("productionDailyReport",draft.getId(),
                new DocumentUnapprovalService.UnapproveRequest("v2-return-no-fp-block-"+UUID.randomUUID(),"先取消实际生成的旧版余料申请")))
                .isInstanceOf(ApiException.class).hasMessageContaining("余料");
        assertThat(ledgerFacts()).isEqualTo(before);qty("6.1256",consumed(task));qty("1989.8744",stock(task,task.material()));
        returns.cancel(task.plan(),pending.documentId(),new ProductionMaterialReturnRequest.Cancel("v2-return-cancel-"+UUID.randomUUID(),"撤回旧版审核的未实收余料申请"));
        var ready=unapproval.capability("productionDailyReport",draft.getId());assertThat(ready.eligible()).as(ready.reasons().toString()).isTrue();
        assertThat(ready.factsSnapshot()).isNotEqualTo(capability.factsSnapshot());
        var successor=(DailyReportDetail)unapproval.unapprove("productionDailyReport",draft.getId(),
                new DocumentUnapprovalService.UnapproveRequest("v2-normal-cancel-unapprove-"+UUID.randomUUID(),"原余料申请已按正常流程取消",ready.factsSnapshot()));
        assertThat(successor.getStatus()).isZero();qty("0",consumed(task));qty("0",finished(task));
        qty("6.1256",successor.getMaterialUsages().getFirst().getQtyBase());assertSuccessorAuthors(draft.getId(),successor.getId(),authors(draft.getId()));
        assertThat(returns.list(task.plan(),task.segment()).getFirst().status()).isEqualTo("CANCELLED");
    }

    @Test @Order(7)
    void matchingApprovalActorAndReportTextCannotTurnAnUnrelatedRealSourceReturnIntoThisReportsDependency(){
        Task task=task("v3-return-binding-original");var draft=create(task,"10.1256","6.1256",true);
        UUID reviewer=reviewer(task);harness.loginAs(reviewer);
        reports.approve(draft.getId(),request(reports.materialReview(draft.getId()),"RETURN","v3-binding-original-"+UUID.randomUUID()));
        var originalReturn=returns.list(task.plan(),task.segment()).getFirst();
        returns.cancel(task.plan(),originalReturn.documentId(),new ProductionMaterialReturnRequest.Cancel("v3-binding-cancel-"+UUID.randomUUID(),"取消本日报的未实收余料申请"));
        Task other=task("v3-return-binding-foreign");
        UUID otherMaker=scalarUuid("SELECT maker_id FROM production_plans WHERE id=?",other.plan());
        db.update("INSERT INTO user_data_scopes(user_id,scope,owner_employee_id) VALUES (?,'production_plan',?)",reviewer,otherMaker);
        // Reading a shared plan alone is insufficient: give the fixture the real secondary workshop assignment.
        db.update("INSERT INTO employee_secondary_departments(employee_id,department_id) SELECT employee_id,? FROM users WHERE id=?",other.workshop(),reviewer);
        harness.loginAs(reviewer);var source=returns.sources(other.plan(),other.segment()).getFirst();
        String deceptiveKey="DRRET3-"+draft.getId()+"-"+other.segment()+"-999";
        var separate=returns.submit(other.plan(),new ProductionMaterialReturnRequest.Submit(other.segment(),deceptiveKey,
                "另一真实任务的独立退料申请，不属于原日报审核",List.of(new ProductionMaterialReturnRequest.Item(source.issuePostingId(),BigDecimal.ONE)))).getFirst();
        assertThat(separate.status()).isEqualTo("PENDING");qty("1",separate.lines().getFirst().qty());
        var ready=unapproval.capability("productionDailyReport",draft.getId());
        assertThat(ready.eligible()).as("a text prefix and same actor are insufficient without this report's exact source: %s",ready.reasons()).isTrue();
        var successor=(DailyReportDetail)unapproval.unapprove("productionDailyReport",draft.getId(),
                new DocumentUnapprovalService.UnapproveRequest("v3-real-source-only-unapprove-"+UUID.randomUUID(),"只撤回本日报真实来源的审核效果",ready.factsSnapshot()));
        assertThat(successor.getStatus()).isZero();qty("0",consumed(task));qty("0",finished(task));
        var stillSeparate=returns.list(other.plan(),other.segment()).getFirst();
        assertThat(stillSeparate.documentId()).isEqualTo(separate.documentId());assertThat(stillSeparate.status()).isEqualTo("PENDING");qty("1",stillSeparate.lines().getFirst().qty());
        qty("0",consumed(other));qty("0",finished(other));
        qty("9.1256",scalar("SELECT SUM(fn_material_issue_available(id,NULL)) FROM production_material_stock_postings WHERE demand_id=? AND posting_type='ISSUE'",other.demand()));
    }

    private Task task(String prefix){
        Object value=call(workshop,"createStartedTask",prefix+"-"+UUID.randomUUID(),false,"10.1256");
        FullChainEndToEndTest.World world=call(value,"world");
        List<ReportablePlanLine> sources=call(workshop,"sources",value);
        assertThat(sources).hasSize(1);
        return new Task(value,world,sources.getFirst(),call(value,"plan"),call(value,"planItem"),call(value,"segment"),
                call(value,"demand"),call(value,"workshop"),call(value,"product"),call(value,"material"));
    }
    private DailyReportDetail create(Task task,String quantity,String use,boolean finalReport){return reports.create(input(task,quantity,use,finalReport));}
    private DailyReportSaveRequest input(Task task,String quantity,String use,boolean finalReport){
        DailyReportSaveRequest request=call(workshop,"reportRequest",task.nativeTask(),task.source(),quantity,use);
        request.getItems().getFirst().setIsFinal(finalReport);return request;
    }
    private UUID reviewer(Task task){
        UUID id=harness.createUserWithPerms(task.world(),"v3-review-only-"+UUID.randomUUID(),
                "production_daily_report:view","production_daily_report:approve","production_daily_report:reverse",
                "production_plan:view","production_execution:view","production_material:view","production_material:settle","production_material:reverse");
        UUID maker=scalarUuid("SELECT maker_id FROM production_plans WHERE id=?",task.plan());
        db.update("INSERT INTO user_data_scopes(user_id,scope,owner_employee_id) VALUES (?,'production_plan',?)",id,maker);
        db.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)",task.workshop(),id);
        return id;
    }
    private DailyReportApproveRequest request(DailyReportMaterialReview review,String action,String key){
        var request=new DailyReportApproveRequest();request.setCommandVersion(3);request.setExpectedVersion(review.reportVersion());
        request.setMaterialReviewFingerprint(review.fingerprint());request.setIdempotencyKey(key);
        request.setMaterialDecisions(review.rows().stream().map(row->new DailyReportMaterialDecision(row.demandId(),action)).toList());return request;
    }
    private void assertV3(DailyReportDetail detail,DailyReportApproveRequest command,boolean replay){
        assertThat(detail.getApprovalReceipt()).isNotNull();var receipt=detail.getApprovalReceipt();
        assertThat(receipt.commandVersion()).isEqualTo(3);assertThat(receipt.idempotencyKey()).isEqualTo(command.getIdempotencyKey());
        assertThat(receipt.reviewedVersion()).isEqualTo(command.getExpectedVersion());assertThat(receipt.materialReviewFingerprint()).isEqualTo(command.getMaterialReviewFingerprint());
        assertThat(receipt.replay()).isEqualTo(replay);
    }
    private void assertStoredV3(UUID report,DailyReportMaterialReview review,String action){
        var fact=db.queryForMap("SELECT approval_protocol_version,reviewed_row_version,request_hash,material_review_fingerprint,material_review_snapshot::text snapshot,material_decisions::text decisions FROM production_daily_report_commands WHERE report_id=? AND command_kind='APPROVE'",report);
        assertThat(((Number)fact.get("approval_protocol_version")).intValue()).isEqualTo(3);
        assertThat(((Number)fact.get("reviewed_row_version")).longValue()).isEqualTo(review.reportVersion());
        assertThat(fact.get("request_hash").toString()).matches("[a-f0-9]{64}");
        assertThat(fact.get("material_review_fingerprint")).isEqualTo(review.fingerprint());
        assertThat(fact.get("snapshot").toString()).contains(review.fingerprint(),review.rows().getFirst().demandId().toString());
        assertThat(fact.get("decisions").toString()).contains(action,review.rows().getFirst().demandId().toString());
    }
    private Map<String,Object> authors(UUID report){return db.queryForMap("SELECT maker_id,created_by,created_at FROM production_daily_reports WHERE id=?",report);}
    private void assertSuccessorAuthors(UUID original,UUID successor,Map<String,Object> before){
        assertThat(authors(original)).isEqualTo(before);
        var next=authors(successor);assertThat(next.get("maker_id")).isEqualTo(before.get("maker_id"));
        assertThat(next.get("created_by")).isEqualTo(before.get("created_by"));
        assertThat(((java.sql.Timestamp)next.get("created_at")).toInstant()).isAfterOrEqualTo(((java.sql.Timestamp)before.get("created_at")).toInstant());
        assertThat(unapproval.lineage("productionDailyReport",successor).toString()).contains(original.toString(),successor.toString());
    }
    private BigDecimal consumed(Task t){return scalar("SELECT confirmed_consumed_qty FROM v_production_material_clearance WHERE demand_id=?",t.demand());}
    private BigDecimal finished(Task t){return scalar("SELECT fqty FROM production_plan_items WHERE id=?",t.planItem());}
    private BigDecimal stock(Task t,UUID goods){return scalar("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",t.world().warehouseId(),goods);}
    private Map<String,Long> ledgerFacts(){
        Map<String,Long> out=new TreeMap<>();
        for(String table:List.of("stock_movements","stock_value_events","stock_value_nodes","stock_value_edges","stock_value_postings",
                "production_material_settlement_events","production_material_settlement_postings","production_daily_report_commands","document_unapprovals","production_material_return_requests"))
            out.put(table,db.queryForObject("SELECT COUNT(*) FROM "+table,Long.class));
        return out;
    }
    private void drain(Task task){
        var context=SecurityContextHolder.getContext();SecurityContextHolder.clearContext();
        try {InventoryValueWorkTestSupport.drain(beans.getBean(InventoryValueWorkService.class),db,List.of(task.material(),task.product()));}
        finally {SecurityContextHolder.setContext(context);}
    }
    private void assertOriginalUseCost(Task task,UUID report,String expected){
        UUID root=db.queryForObject("""
                SELECT value.result_node_id FROM production_material_settlement_events event
                JOIN production_material_settlement_postings posting ON posting.event_id=event.id
                JOIN stock_value_events value ON value.source_event_id=posting.id AND value.source_doc_type='PRODUCTION_CONSUMED_VALUE'
                WHERE event.daily_report_id=? AND event.event_type='POST' AND posting.settlement_type='CONSUMED'
                """,UUID.class,report);
        var position=positions.position(root);assertThat(position.owner()).isEqualTo(InventoryPositionPort.Owner.COST_WIP);
        assertThat(position.ownerId()).isEqualTo(task.segment());qty(expected,position.knownValueLocal());qty("0",position.pendingReallocationLocal());
    }
    private BigDecimal scalar(String sql,Object...args){return db.queryForObject(sql,BigDecimal.class,args);}
    private UUID scalarUuid(String sql,Object...args){return db.queryForObject(sql,UUID.class,args);}
    private void qty(String expected,BigDecimal actual){assertThat(actual).isNotNull().isEqualByComparingTo(expected);}
    private static <T>T call(Object target,String method,Object...args){return ReflectionTestUtils.invokeMethod(target,method,args);}
    private record Task(Object nativeTask,FullChainEndToEndTest.World world,ReportablePlanLine source,UUID plan,UUID planItem,UUID segment,UUID demand,UUID workshop,UUID product,UUID material){}
}
