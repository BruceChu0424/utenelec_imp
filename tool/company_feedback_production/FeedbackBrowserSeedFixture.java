package com.uten.imp.businesschain;
import java.util.*;import java.nio.file.*;import java.math.*;import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.Test;import org.springframework.test.util.ReflectionTestUtils;
import com.uten.imp.features.production.dailyreport.dto.*;
import static org.junit.jupiter.api.Assertions.*;
class FeedbackBrowserSeedFixture extends FeedbackLegacyMaterialUpgradeFixture {
 @org.springframework.beans.factory.annotation.Autowired org.springframework.core.env.Environment runtimeEnvironment;
 @Test void seed() throws Exception {
  assertTrue(Objects.equals(System.getenv("AUDIT_BOOTSTRAP_LOGIN"),runtimeEnvironment.getProperty("uten.bootstrap.admin-login")),"Seed bootstrap identity differs from the runtime");
  assertTrue(Objects.equals(System.getenv("AUDIT_BOOTSTRAP_PASSWORD"),runtimeEnvironment.getProperty("uten.bootstrap.admin-password")),"Seed bootstrap configuration differs from the runtime");
  assertTrue(Objects.equals(System.getenv("AUDIT_JWT_SECRET"),runtimeEnvironment.getProperty("uten.jwt.secret")),"Seed JWT configuration differs from the runtime");
  assertTrue(Objects.equals(System.getenv("AUDIT_HMAC_KEY"),runtimeEnvironment.getProperty("uten.crypto.hmac-key")),"Seed HMAC configuration differs from the runtime");
  assertTrue(Objects.equals(System.getenv("AUDIT_PGP_MASTER_KEY"),runtimeEnvironment.getProperty("uten.crypto.pgp-master-key")),"Seed PGP configuration differs from the runtime");
  var h=new FeedbackThreeMaterialFixture();beans.autowireBean(h);h.prepare();
  ((AtomicInteger)ReflectionTestUtils.getField(FullChainEndToEndTest.class,"LEGACY_SEQ")).set(db.queryForObject("SELECT COALESCE(MAX(legacy_id),10000)+100 FROM units",Integer.class));
  String tag=UUID.randomUUID().toString().substring(0,7);
  Object partial=ReflectionTestUtils.invokeMethod(h,"createStartedTask","web-partial-"+tag,false,"10000",true,new BigDecimal("0.5"));
  var standard=new WorkshopPublicSurplusEndToEndTest();beans.autowireBean(standard);standard.prepare();
  Object edit=ReflectionTestUtils.invokeMethod(standard,"createStartedTask","web-edit-"+tag,false,"1000",false,new BigDecimal("0.5"));
  Object full=ReflectionTestUtils.invokeMethod(standard,"createStartedTask","web-full-"+tag,false,"1000",false,BigDecimal.ONE);
  var world=(FullChainEndToEndTest.World)ReflectionTestUtils.invokeMethod(partial,"world");
  UUID reporter=h.fixture.createUserWithPerms(world,"web-report-"+tag,
   "production_daily_report:create","production_daily_report:view","production_daily_report:edit","production_daily_report:delete",
   "production_execution:view","production_execution:start","production_report:export","warehouse:view","goods:view","unit:view","color:view");
  UUID approver=h.fixture.createUserWithPerms(world,"web-approve-"+tag,
   "production_daily_report:view","production_daily_report:approve","production_execution:view","production_report:export");
  UUID reporterEmployee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,reporter);
  UUID approverEmployee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,approver);
  UUID mainWorkshop=ReflectionTestUtils.invokeMethod(partial,"workshop");
  db.update("UPDATE employees SET department_id=? WHERE id IN (?,?)",mainWorkshop,reporterEmployee,approverEmployee);
  for(Object task:List.of(edit,full)) {
   UUID workshop=ReflectionTestUtils.invokeMethod(task,"workshop");
   for(UUID employee:List.of(reporterEmployee,approverEmployee))db.update("INSERT INTO employee_secondary_departments(employee_id,department_id) VALUES(?,?) ON CONFLICT DO NOTHING",employee,workshop);
  }
  h.fixture.grantDataScope(approver,"production_plan",reporterEmployee);
  String raw=System.getenv("AUDIT_BROWSER_PASSWORD");assertNotNull(raw);
  var encoder=new org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder(10);
  for(UUID user:List.of(reporter,approver))db.update("UPDATE users SET password_hash=?,must_change_password=false WHERE id=?",encoder.encode(raw),user);
  h.fixture.loginAs(reporter);
  List<ReportablePlanLine> editSources=ReflectionTestUtils.invokeMethod(standard,"sources",edit);
  DailyReportSaveRequest req=ReflectionTestUtils.invokeMethod(standard,"reportRequest",edit,editSources.getFirst(),"300","300");
  UUID draft=reports.create(req).getId();
  Map<String,Object> result=new LinkedHashMap<>();
  for(var entry:Map.of("partial",partial,"edit",edit,"full",full).entrySet()) {
   Object task=entry.getValue();UUID segment=ReflectionTestUtils.invokeMethod(task,"segment");
   List<ReportablePlanLine> sources=ReflectionTestUtils.invokeMethod(task==partial?h:standard,"sources",task);
   result.put(entry.getKey(),Map.of("segmentId",segment,"planId",ReflectionTestUtils.invokeMethod(task,"plan"),
    "workshopId",ReflectionTestUtils.invokeMethod(task,"workshop"),"source",sources.getFirst(),
    "newPage","/production/daily-reports/new?executionSegmentId="+segment+"&from=workshop-tasks"));
  }
  result.put("editDraftId",draft);result.put("editPage","/production/daily-reports/"+draft+"/edit");
  result.put("reporter",db.queryForObject("SELECT login_account FROM users WHERE id=?",String.class,reporter));
  result.put("approver",db.queryForObject("SELECT login_account FROM users WHERE id=?",String.class,approver));
  result.put("reporterUserId",reporter);result.put("approverUserId",approver);
  Files.writeString(store.resolve("browser-production-seed.json"),json.writerWithDefaultPrettyPrinter().writeValueAsString(result));
  System.out.println("BROWSER_SEED real public business operations; ordinary reporter and separate approver; original sources retained; credentials omitted");
 }
}
