package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.plan.ProductionPlanService;
import com.uten.imp.features.production.plan.dto.*;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.dto.*;
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

/** Reviewer-only amendments use real domain locks/guards and retain the original author on migrated PG. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(properties={"spring.profiles.active=dev","uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
        "uten.inventory.value-work.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ProductionDraftReviewedSaveEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ProductionPlanService plans;
    @Autowired ProductionDailyReportService reports;
    @Autowired com.uten.imp.common.platformcolumns.PlatformColumnService fields;
    FullChainEndToEndTest harness;
    @BeforeEach void prepare(){harness=new FullChainEndToEndTest();beans.autowireBean(harness);}
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test void planReviewerWithoutEditAmendsOriginalLineThenApprovesAndCannotReplayStaleOrChangeSource(){
        var world=harness.seedWorld("plan-review-"+UUID.randomUUID());harness.loginAs(world.superAdminUserId());
        var draft=plans.create(manual(world,"10"));
        var before=db.queryForMap("SELECT maker_id,created_by,created_at FROM production_plans WHERE id=?",draft.getId());
        UUID sourceItem=draft.getItems().getFirst().getId();
        UUID reviewer=reviewer(world,"production_plan",draft.getMakerId(),null);
        harness.loginAs(reviewer);
        var seen=plans.review(draft.getId());
        var replacement=planEdit(seen.detail(),"8.1256");
        assertThatThrownBy(()->plans.update(draft.getId(),replacement)).isInstanceOf(ApiException.class);
        var spoof=planEdit(seen.detail(),"8.1256");spoof.getItems().getFirst().setGoodsId(world.goodsD());
        assertThatThrownBy(()->plans.updateReviewed(draft.getId(),spoof,seen.snapshot(),true)).isInstanceOf(ApiException.class);
        assertThat(qty("SELECT qty FROM production_plan_items WHERE id=?",sourceItem)).isEqualByComparingTo("10");
        var approved=plans.updateReviewed(draft.getId(),replacement,seen.snapshot(),true);
        assertThat(approved.getStatus()).isEqualTo((short)1);
        assertThat(approved.getItems().getFirst().getId()).isEqualTo(sourceItem);
        assertThat(approved.getItems().getFirst().getQty()).isEqualByComparingTo("8.1256");
        assertThat(db.queryForMap("SELECT maker_id,created_by,created_at FROM production_plans WHERE id=?",draft.getId())).isEqualTo(before);
        assertThat(approved.getApproverId()).isEqualTo(db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,reviewer));
        assertThatThrownBy(()->plans.updateReviewed(draft.getId(),replacement,seen.snapshot(),true)).isInstanceOf(ApiException.class);
        assertThat(qty("SELECT qty FROM production_plan_items WHERE id=?",sourceItem)).isEqualByComparingTo("8.1256");
    }

    @Test void planSnapshotRejectsOwnerEditAndAnApprovalPermissionCannotDiscoverAHiddenOwnersDraft(){
        var world=harness.seedWorld("plan-review-stale-"+UUID.randomUUID());harness.loginAs(world.superAdminUserId());
        var draft=plans.create(manual(world,"10"));
        assertThat(plans.review(draft.getId()).quantityEditable()).isTrue();
        UUID reviewer=reviewer(world,"production_plan",draft.getMakerId(),null);harness.loginAs(reviewer);
        var seen=plans.review(draft.getId());var reviewed=planEdit(seen.detail(),"8");
        harness.loginAs(world.superAdminUserId());plans.update(draft.getId(),planEdit(seen.detail(),"11"));harness.loginAs(reviewer);
        assertThatThrownBy(()->plans.updateReviewed(draft.getId(),reviewed,seen.snapshot(),true)).isInstanceOf(ApiException.class).hasMessageContaining("已变化");
        assertThat(qty("SELECT SUM(qty) FROM production_plan_items WHERE plan_id=?",draft.getId())).isEqualByComparingTo("11");
        UUID hidden=harness.createUserWithPerms(world,"plan-hidden-"+UUID.randomUUID(),"production_plan:view","production_plan:approve");harness.loginAs(hidden);
        assertThatThrownBy(()->plans.review(draft.getId())).isInstanceOf(ApiException.class).hasMessageContaining("审核范围");
    }

    @Test void dailyReviewerChangesActualOutputDefectsAndUseInOneTransactionAndRetryDoesNotPostTwice(){
        var fixture=new WorkshopPublicSurplusEndToEndTest();beans.autowireBean(fixture);fixture.prepare();
        Object task=call(fixture,"createStartedTask","daily-review-"+UUID.randomUUID(),true,"10");
        FullChainEndToEndTest.World world=call(task,"world");
        List<ReportablePlanLine> sources=call(fixture,"sources",task);
        var source=sources.stream().filter(line->line.orderItemId()!=null).findFirst().orElseThrow();
        DailyReportSaveRequest input=call(fixture,"reportRequest",task,source,"4","4");input.getItems().getFirst().setDefectQty(BigDecimal.ONE);
        input.setWarehouseId(world.warehouseId());input.setSupplierId(world.supplierId());input.setSourceDocNo("原报工来源-"+UUID.randomUUID());
        var draft=reports.create(input);
        var before=db.queryForMap("SELECT maker_id,created_by,created_at,warehouse_id,supplier_id,source_doc_no,worker_id FROM production_daily_reports WHERE id=?",draft.getId());
        UUID workshop=call(task,"workshop");UUID reviewer=reviewer(world,"production_daily_report",draft.getMakerId(),workshop);harness.loginAs(reviewer);
        var seen=reports.review(draft.getId());
        DailyReportSaveRequest replacement=call(fixture,"reportRequest",task,source,"6","6");
        replacement.setExpectedVersion(seen.detail().getRowVersion());
        replacement.getItems().getFirst().setReviewSourceItemId(seen.detail().getOutputBatches().getFirst().sourceItemId());
        replacement.getItems().getFirst().setDefectQty(new BigDecimal("2"));
        assertThatThrownBy(()->reports.update(draft.getId(),replacement)).isInstanceOf(ApiException.class);
        var approved=reports.updateReviewed(draft.getId(),replacement,seen.snapshot(),true);
        assertThat(approved.getStatus()).isEqualTo((short)1);
        UUID planItem=call(task,"planItem");UUID demand=call(task,"demand");
        assertThat(qty("SELECT fqty FROM production_plan_items WHERE id=?",planItem)).isEqualByComparingTo("6");
        assertThat(qty("SELECT SUM(qty) FROM production_daily_report_items WHERE report_id=?",draft.getId())).isEqualByComparingTo("6");
        assertThat(qty("SELECT SUM(defect_qty) FROM production_daily_report_items WHERE report_id=?",draft.getId())).isEqualByComparingTo("2");
        assertThat(qty("SELECT qty_base FROM production_daily_report_material_usages WHERE report_id=? AND demand_id=?",draft.getId(),demand)).isEqualByComparingTo("6");
        assertThat(db.queryForMap("SELECT maker_id,created_by,created_at,warehouse_id,supplier_id,source_doc_no,worker_id FROM production_daily_reports WHERE id=?",draft.getId())).isEqualTo(before);
        var replay=reports.updateReviewed(draft.getId(),replacement,seen.snapshot(),true);
        assertThat(replay.getApprovalReceipt().replay()).isTrue();
        assertThat(qty("SELECT fqty FROM production_plan_items WHERE id=?",planItem)).isEqualByComparingTo("6");
        assertThat(qty("SELECT COUNT(*) FROM production_daily_report_commands WHERE report_id=? AND command_kind='APPROVE'",draft.getId())).isEqualByComparingTo("1");
    }

    @Test void reorderedPlanReviewKeepsExtensionOriginalsAndChangesBoundToTheirExactExistingLineIds(){
        var world=harness.seedWorld("plan-review-fields-"+UUID.randomUUID());harness.loginAs(world.superAdminUserId());
        var request=manual(world,"10");var other=manual(world,"5").getItems().getFirst();other.setGoodsId(world.goodsD());
        request.setItems(List.of(request.getItems().getFirst(),other));var draft=plans.create(request);
        var column=fields.create("production_plan_item",new com.uten.imp.common.platformcolumns.PlatformColumnContracts.CreateDefinition("复核说明-"+UUID.randomUUID(),"TEXT",false,null));
        for(var item:draft.getItems()) fields.write("production_plan_item",item.getId(),new com.uten.imp.common.platformcolumns.PlatformColumnContracts.Write(0,
                List.of(new com.uten.imp.common.platformcolumns.PlatformColumnContracts.CellInput(column.id(),"原行-"+item.getId()))));
        UUID reviewer=reviewer(world,"production_plan",draft.getMakerId(),null);harness.loginAs(reviewer);
        var seen=plans.review(draft.getId());var edited=new PlanSaveRequest();edited.setBillDate(draft.getBillDate());
        var lines=new ArrayList<PlanItemLine>();
        for(var before:seen.detail().getItems().reversed()){
            var line=new PlanItemLine();line.setSourceItemId(before.getId());line.setGoodsId(before.getGoodsId());line.setUnitId(before.getUnitId());line.setUnitRate(before.getUnitRate());line.setQty(before.getQty());
            line.setPlatformFields(new com.uten.imp.common.platformcolumns.PlatformColumnLineInput.Fields(before.getId(),1,
                    List.of(new com.uten.imp.common.platformcolumns.PlatformColumnContracts.CellInput(column.id(),"更正行-"+before.getId()))));lines.add(line);
        }
        edited.setItems(lines);var saved=plans.updateReviewed(draft.getId(),edited,seen.snapshot(),false);
        assertThat(saved.getItems()).extracting(PlanItemDto::getId).containsExactlyElementsOf(draft.getItems().stream().map(PlanItemDto::getId).toList());
        var stored=fields.read("production_plan_item",new com.uten.imp.common.platformcolumns.PlatformColumnContracts.BatchRead(
                draft.getItems().stream().map(PlanItemDto::getId).toList(),List.of(column.id())));
        for(var row:stored){assertThat(row.version()).isEqualTo(2);assertThat(row.cells().getFirst().value()).isEqualTo("更正行-"+row.recordId());}
        assertThat(qty("SELECT COUNT(*) FROM platform_record_field_versions WHERE scope='production_plan_item' AND record_id IN (?,?)",
                draft.getItems().get(0).getId(),draft.getItems().get(1).getId())).isEqualByComparingTo("4");
    }

    private UUID reviewer(FullChainEndToEndTest.World world,String family,UUID owner,UUID workshop){
        String[] permissions=family.equals("production_plan") ? new String[]{family+":view",family+":approve"} : new String[]{family+":view",family+":approve","production_plan:view"};
        UUID user=harness.createUserWithPerms(world,"review-only-"+UUID.randomUUID(),permissions);
        db.update("INSERT INTO user_data_scopes(user_id,scope,owner_employee_id) VALUES (?,'production_plan',?)",user,owner);
        if(workshop!=null)db.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)",workshop,user);
        return user;
    }
    private PlanSaveRequest manual(FullChainEndToEndTest.World world,String quantity){
        var request=new PlanSaveRequest();request.setBillDate(BusinessTime.today());
        var line=new PlanItemLine();line.setGoodsId(world.goodsC());line.setUnitId(world.unitId());line.setUnitRate(BigDecimal.ONE);line.setQty(new BigDecimal(quantity));request.setItems(List.of(line));return request;
    }
    private PlanSaveRequest planEdit(PlanDetail detail,String quantity){
        var request=new PlanSaveRequest();request.setBillDate(detail.getBillDate());request.setDepartmentId(detail.getDepartmentId());request.setSellerId(detail.getSellerId());request.setWorkerId(detail.getWorkerId());request.setDeliveryDate(detail.getDeliveryDate());request.setRemark("审核核对数量");
        var before=detail.getItems().getFirst();var line=new PlanItemLine();line.setSourceItemId(before.getId());line.setGoodsId(before.getGoodsId());line.setColorId(before.getColorId());line.setUnitId(before.getUnitId());line.setUnitRate(before.getUnitRate());line.setSalesOrderItemId(before.getSalesOrderItemId());line.setQty(new BigDecimal(quantity));line.setRemark("保留原来源");request.setItems(List.of(line));return request;
    }
    private BigDecimal qty(String sql,Object...args){return db.queryForObject(sql,BigDecimal.class,args);}
    private static <T>T call(Object target,String method,Object...args){return ReflectionTestUtils.invokeMethod(target,method,args);}
}
