package com.uten.imp.businesschain;

import java.nio.file.*;import java.util.*;import java.math.*;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.util.ReflectionTestUtils;
import com.uten.imp.testsupport.FixtureDatabaseProperties;
import com.uten.imp.features.production.dailyreport.*;
import com.uten.imp.features.production.dailyreport.dto.*;
import com.uten.imp.support.DailyReportApproveRequests;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.allocation.ProductionMaterialReturnRequestService;
import com.uten.imp.features.stock.allocation.dto.ProductionMaterialReturnRequest;
import com.fasterxml.jackson.databind.ObjectMapper;
import static org.junit.jupiter.api.Assertions.*;

@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
"spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
"uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only","uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class FeedbackLegacyMaterialUpgradeFixture {
 @DynamicPropertySource static void database(DynamicPropertyRegistry registry){
   String port=System.getenv("AUDIT_KIT_PG_PORT");assertTrue(port.matches("[1-9][0-9]+"));
   FixtureDatabaseProperties.bindSameRole(registry,()->System.getenv().getOrDefault("AUDIT_KIT_JDBC","jdbc:postgresql://127.0.0.1:"+port+"/"+System.getenv().getOrDefault("AUDIT_KIT_DATABASE","audit_kit")),()->System.getenv().getOrDefault("AUDIT_KIT_USERNAME","postgres"),()->System.getenv().getOrDefault("AUDIT_KIT_PASSWORD","fixture-only"));
   if(System.getenv("AUDIT_KIT_TARGET")!=null) registry.add("spring.flyway.target",()->System.getenv("AUDIT_KIT_TARGET"));
   if(System.getenv("AUDIT_BOOTSTRAP_LOGIN")!=null) registry.add("uten.bootstrap.admin-login",()->System.getenv("AUDIT_BOOTSTRAP_LOGIN"));
   if(System.getenv("AUDIT_BOOTSTRAP_PASSWORD")!=null) registry.add("uten.bootstrap.admin-password",()->System.getenv("AUDIT_BOOTSTRAP_PASSWORD"));
   if(System.getenv("AUDIT_JWT_SECRET")!=null) registry.add("uten.jwt.secret",()->System.getenv("AUDIT_JWT_SECRET"));
   if(System.getenv("AUDIT_HMAC_KEY")!=null) registry.add("uten.crypto.hmac-key",()->System.getenv("AUDIT_HMAC_KEY"));
   if(System.getenv("AUDIT_PGP_MASTER_KEY")!=null) registry.add("uten.crypto.pgp-master-key",()->System.getenv("AUDIT_PGP_MASTER_KEY"));
   registry.add("uten.storage.local-dir",()->System.getProperty("java.io.tmpdir")+"/attachments");
 }
 @Autowired AutowireCapableBeanFactory beans; @Autowired JdbcTemplate db; @Autowired ProductionDailyReportService reports;
 Path store=Path.of(System.getenv("AUDIT_LEGACY_DIR")); ObjectMapper json=new ObjectMapper().findAndRegisterModules();
 @Test void old() throws Exception {
   assertEquals("1128",db.queryForObject("select version from flyway_schema_history order by installed_rank desc limit 1",String.class));
   var h=new ProductionQuantityAdversarialEndToEndTest();beans.autowireBean(h);h.prepare();
   Object c=ReflectionTestUtils.invokeMethod(h,"create","audity"+UUID.randomUUID().toString().substring(0,8),false,"20");
   UUID segment=ReflectionTestUtils.invokeMethod(c,"segment"),plan=ReflectionTestUtils.invokeMethod(c,"plan");
   UUID material=ReflectionTestUtils.invokeMethod(c,"material"),leaf=ReflectionTestUtils.invokeMethod(c,"leaf");
   FullChainEndToEndTest.World w=ReflectionTestUtils.invokeMethod(c,"world");
   ReflectionTestUtils.invokeMethod(h,"confirm",c,"CONTINUOUS");
   ReflectionTestUtils.invokeMethod(h,"receive",c,material,leaf,"10");ReflectionTestUtils.invokeMethod(h,"issueDraws",c);ReflectionTestUtils.invokeMethod(h,"start",c);
   var returns=beans.getBean(ProductionMaterialReturnRequestService.class);
   UUID worker=ReflectionTestUtils.invokeMethod(c,"workerUser"); h.fixture.loginAs(worker);
   var source=returns.sources(plan,segment).getFirst();
   var ret=returns.submit(plan,new ProductionMaterialReturnRequest.Submit(segment,"audit-return-"+UUID.randomUUID(),"早期真实退料",List.of(new ProductionMaterialReturnRequest.Item(source.issuePostingId(),new BigDecimal("9"))))).getFirst();
   h.fixture.loginAs(w.superAdminUserId());beans.getBean(StockDocService.class).approve(ret.documentId());
   System.out.println("AUDIT_OLD_BEFORE "+db.queryForMap("select planned_qty,fn_execution_material_output_capacity(id,true) as capacity from production_execution_segments where id=?",segment));
   DailyReportSaveRequest fin=ReflectionTestUtils.invokeMethod(h,"report",c,"10",true,"0.5");fin.getItems().getFirst().setOverLimitReason("如实登记旧版实产");
   UUID closed=reports.approve(reports.create(fin).getId(),DailyReportApproveRequests.freshKey()).getId();
   System.out.println("AUDIT_OLD_AFTER old_final_approved="+closed+" "+db.queryForMap("select status,planned_qty,fn_execution_material_output_capacity(id,true) as capacity from production_execution_segments where id=?",segment));
   DailyReportSaveRequest extra=ReflectionTestUtils.invokeMethod(h,"report",c,"3",false,"0.5");extra.getItems().getFirst().setOverLimitReason("实报复核剩余可用物料");
   Files.writeString(store.resolve("old-final-id.txt"),closed.toString());
   extra.getMaterialLines().getFirst().setQtyBase(new BigDecimal("0.15"));
   for(String kind:List.of("edit","approve")) {
     DailyReportSaveRequest oldDraft=json.readValue(json.writeValueAsString(extra),DailyReportSaveRequest.class);
     oldDraft.setIdempotencyKey("old-draft-"+kind+"-"+UUID.randomUUID());
     UUID draft=reports.create(oldDraft).getId();
     Files.writeString(store.resolve("old-"+kind+"-draft.txt"),draft.toString());
     System.out.println("OLD_DRAFT "+kind+" "+draft+" quantity=3 status=0");
   }
   Files.writeString(store.resolve("post-upgrade-input.json"),json.writeValueAsString(extra));Files.writeString(store.resolve("legacy-segment.txt"),segment.toString());Files.writeString(store.resolve("legacy-actor.txt"),w.superAdminUserId().toString());
   oldThreeMaterialCases();
 }
 @Test void oldThreeOnly() throws Exception {
   assertEquals("1128",db.queryForObject("SELECT version FROM flyway_schema_history ORDER BY installed_rank DESC LIMIT 1",String.class));
   oldThreeMaterialCases();
 }
 private void oldThreeMaterialCases() throws Exception {
   Object h=Class.forName("com.uten.imp.businesschain.FeedbackThreeMaterialFixture").getDeclaredConstructor().newInstance();
   beans.autowireBean(h);ReflectionTestUtils.invokeMethod(h,"prepare");
   FullChainEndToEndTest fixture=(FullChainEndToEndTest)ReflectionTestUtils.getField(h,"fixture");
   ((java.util.concurrent.atomic.AtomicInteger)ReflectionTestUtils.getField(FullChainEndToEndTest.class,"LEGACY_SEQ")).set(db.queryForObject("SELECT COALESCE(MAX(legacy_id),10000)+100 FROM units",Integer.class));
   for(String mode:List.of("create","edit","approve")) {
     Object task=ReflectionTestUtils.invokeMethod(h,"createStartedTask","old-three-"+mode+UUID.randomUUID().toString().substring(0,7),false,"10000",true,new BigDecimal("0.5"));
     UUID segment=ReflectionTestUtils.invokeMethod(task,"segment"),workshop=ReflectionTestUtils.invokeMethod(task,"workshop");
     FullChainEndToEndTest.World world=ReflectionTestUtils.invokeMethod(task,"world");
     UUID reporter=fixture.createUserWithPerms(world,"three-reporter"+UUID.randomUUID(),"production_daily_report:view","production_daily_report:create","production_daily_report:edit","production_execution:view");
     UUID approver=fixture.createUserWithPerms(world,"three-approver"+UUID.randomUUID(),"production_daily_report:view","production_daily_report:approve","production_execution:view");
     for(UUID actor:List.of(reporter,approver))db.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)",workshop,actor);
     fixture.loginAs(reporter);
     List<ReportablePlanLine> sources=ReflectionTestUtils.invokeMethod(h,"sources",task);
     DailyReportSaveRequest request=ReflectionTestUtils.invokeMethod(h,"reportRequest",task,sources.getFirst(),"6000","5000");
     request.getItems().getFirst().setOverLimitReason("旧版真实草稿六千，原因不能扩大物料配套额度");
     List<UUID> demands=db.queryForList("SELECT id FROM production_material_demands WHERE execution_segment_id=? AND NOT is_deleted ORDER BY id",UUID.class,segment);
     assertEquals(3,demands.size());List<DailyReportMaterialUsageLine> usages=new ArrayList<>();
     for(UUID demand:demands) {
       assertEquals(0,new BigDecimal("5000").compareTo(db.queryForObject("SELECT fn_execution_material_net_issued_qty(?)",BigDecimal.class,demand)));
       var usage=new DailyReportMaterialUsageLine();usage.setDemandId(demand);usage.setQtyBase(new BigDecimal("5000"));usages.add(usage);
     }
     request.setMaterialLines(usages);
     Map<String,Object> record=new LinkedHashMap<>();record.put("segment",segment);record.put("reporter",reporter);record.put("approver",approver);record.put("request",request);
     if(!mode.equals("create"))record.put("draft",reports.create(request).getId());
     Files.writeString(store.resolve("three-legacy-"+mode+".json"),json.writerWithDefaultPrettyPrinter().writeValueAsString(record));
     System.out.println("OLD_THREE mode="+mode+" plan=10000 issued=5000/5000/5000 ordinary=true savedOutput="+(mode.equals("create")?"none":"6000")+" actual=5000/5000/5000");
   }
 }
 @Test void stage1129() throws Exception {
   assertEquals("1129",db.queryForObject("select version from flyway_schema_history order by installed_rank desc limit 1",String.class));
   System.out.println("STAGED_EXISTING_V1129 no fact changes requested");
 }
 @Test void current() throws Exception {
   assertTrue(Boolean.TRUE.equals(db.queryForObject("select success from flyway_schema_history where version='1130'",Boolean.class)));
   assertTrue(Boolean.TRUE.equals(db.queryForObject("select success from flyway_schema_history where version='1131'",Boolean.class)));
   System.out.println("CANDIDATE_MIGRATION latest="+db.queryForObject("select version from flyway_schema_history order by installed_rank desc limit 1",String.class)+" V1130_applied=true V1131_applied=true");
   UUID segment=UUID.fromString(Files.readString(store.resolve("legacy-segment.txt"))), actor=UUID.fromString(Files.readString(store.resolve("legacy-actor.txt")));
   var h=new FullChainEndToEndTest();beans.autowireBean(h);h.loginAs(actor);
   var state=db.queryForMap("select status,planned_qty,material_snapshot_product_qty,fn_execution_material_output_capacity(id,true) as capacity,fn_execution_partial_material_report_room(id,null) as room,fn_execution_full_kit_checkpoint_valid(id) as valid_proof,(select count(*) from production_material_full_kit_proofs p where p.execution_segment_id=s.id) as proofs from production_execution_segments s where id=?",segment);
   System.out.println("CANDIDATE_STATE "+state);
   assertEquals(0,new BigDecimal("1").compareTo((BigDecimal)state.get("capacity")));
   assertEquals(0,BigDecimal.ZERO.compareTo((BigDecimal)state.get("room")));
   assertEquals(false,state.get("valid_proof"));assertEquals(0L,state.get("proofs"));
   String before=facts(segment);
   var extra=json.readValue(Files.readString(store.resolve("post-upgrade-input.json")),DailyReportSaveRequest.class);
   String mode=System.getenv().getOrDefault("AUDIT_KIT_OPERATION","create");
   var failure=assertThrows(com.uten.imp.common.web.ApiException.class,()->{
     if(mode.equals("edit")) {
       UUID draft=UUID.fromString(Files.readString(store.resolve("old-edit-draft.txt")));
       extra.setExpectedVersion(reports.detail(draft).getRowVersion());
       reports.update(draft,extra);
     } else if(mode.equals("approve")) {
       UUID draft=UUID.fromString(Files.readString(store.resolve("old-approve-draft.txt")));
       reports.approve(draft,DailyReportApproveRequests.freshKey());
     } else reports.create(extra);
   });
   assertTrue(failure.getMessage().contains("物料配套"),failure.getMessage());
   assertEquals(before,facts(segment),"rejection must preserve accepted ledger and both old drafts");
   assertEquals(0,new BigDecimal("10").compareTo(db.queryForObject("select sum(item.qty) from production_daily_report_items item join production_daily_reports report on report.id=item.report_id where item.execution_segment_id=? and report.status=1 and not item.is_deleted and not report.is_deleted",BigDecimal.class,segment)));
   System.out.println("UPGRADE_REJECTION operation="+mode+" room=0 extra=3 rejected="+failure.getMessage()+" accepted_output=10 all_existing_facts_unchanged=true");
 }
 @Test void currentThree() throws Exception {
   assertTrue(Boolean.TRUE.equals(db.queryForObject("SELECT success FROM flyway_schema_history WHERE version='1131'",Boolean.class)));
   String mode=System.getenv("AUDIT_THREE_OPERATION");assertTrue(List.of("create","edit","approve").contains(mode));
   var record=json.readTree(Files.readString(store.resolve("three-legacy-"+mode+".json")));
   UUID segment=UUID.fromString(record.get("segment").asText()),reporter=UUID.fromString(record.get("reporter").asText());
   var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);fixture.loginAs(reporter);
   assertFalse(((com.uten.imp.security.AuthUser)org.springframework.security.core.context.SecurityContextHolder.getContext().getAuthentication().getPrincipal()).isSuperAdmin());
   assertEquals(0,new BigDecimal("5000").compareTo(db.queryForObject("SELECT fn_execution_material_output_capacity(?,TRUE)",BigDecimal.class,segment)));
   UUID draft=record.has("draft")?UUID.fromString(record.get("draft").asText()):null;
   var request=json.treeToValue(record.get("request"),DailyReportSaveRequest.class);
   if(!mode.equals("approve")) {
     if(draft!=null)request.setExpectedVersion(reports.detail(draft).getRowVersion());
     var sources=beans.getBean(ReportablePlanLineQueryService.class).list(1,100,null,null,List.of(segment),draft,draft==null?null:request.getExpectedVersion()).getItems();
     assertEquals(1,sources.size());assertEquals(0,new BigDecimal("5000").compareTo(sources.getFirst().materialReportQty()));
     request.getMaterialLines().get(1).setQtyBase(new BigDecimal("6000"));request.getMaterialLines().get(2).setQtyBase(new BigDecimal("6000"));
   } else fixture.loginAs(UUID.fromString(record.get("approver").asText()));
   String before=facts(segment);
   var failure=assertThrows(com.uten.imp.common.web.ApiException.class,()->{
     if(mode.equals("edit"))reports.update(draft,request);
     else if(mode.equals("approve"))reports.approve(draft,DailyReportApproveRequests.freshKey());
     else reports.create(request);
   });
   assertTrue(failure.getMessage().contains("物料配套"),failure.getMessage());
   assertEquals(before,facts(segment));
   assertEquals(0,new BigDecimal("6000").compareTo(request.getItems().getFirst().getQty()));
   if(!mode.equals("approve"))assertEquals(List.of(new BigDecimal("5000"),new BigDecimal("6000"),new BigDecimal("6000")),request.getMaterialLines().stream().map(DailyReportMaterialUsageLine::getQtyBase).toList());
   assertEquals(0,new BigDecimal("0").compareTo(db.queryForObject("SELECT COALESCE(SUM(item.qty),0) FROM production_daily_report_items item JOIN production_daily_reports report ON report.id=item.report_id WHERE item.execution_segment_id=? AND report.status=1",BigDecimal.class,segment)));
   System.out.println("THREE_REJECTION mode="+mode+" ordinary=true plan=10000 issued=5000/5000/5000 output=6000 reason=true submittedActual="+(mode.equals("approve")?"old 5000/5000/5000":"5000/6000/6000")+" rejected="+failure.getMessage()+" facts_unchanged=true approved_output=0");
 }
 private String facts(UUID segment) {
   return db.queryForObject("select jsonb_build_object('segment',to_jsonb(s),'demands',(select jsonb_agg(to_jsonb(d) order by d.id) from production_material_demands d where d.execution_segment_id=s.id),'posting',(select jsonb_agg(to_jsonb(p) order by p.id) from production_material_stock_postings p join production_material_demands d on d.id=p.demand_id where d.execution_segment_id=s.id),'reports',(select jsonb_agg(to_jsonb(r) order by r.id) from production_daily_reports r where exists(select 1 from production_daily_report_items i where i.report_id=r.id and i.execution_segment_id=s.id)),'usages',(select jsonb_agg(to_jsonb(u) order by u.report_id,u.demand_id) from production_daily_report_material_usages u where u.material_execution_segment_id=s.id),'items',(select jsonb_agg(to_jsonb(i) order by i.id) from production_daily_report_items i where i.execution_segment_id=s.id))::text from production_execution_segments s where s.id=?",String.class,segment);
 }
}
