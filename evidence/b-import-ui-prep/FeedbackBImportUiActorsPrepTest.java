package com.uten.imp.businesschain;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import java.nio.file.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
@EnabledIfEnvironmentVariable(named="UTEN_B_IMPORT_ALLOW_SEED",matches="true")
@SpringBootTest(properties={"spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false","uten.storage.uploads-enabled=false"})
class FeedbackBImportUiActorsPrepTest {
 @DynamicPropertySource static void database(DynamicPropertyRegistry r){FeedbackBWebSeedTest.database(r);}
 @Autowired JdbcTemplate db;@Autowired AutowireCapableBeanFactory beans;@Autowired PasswordEncoder passwords;@Autowired PlatformTransactionManager transactions;
 static final List<String> MASTER=List.of("goods:view","goods:import","goods:bom:create","goods:bom:delete","goods:cost:view","goods:cost:edit");
 static final List<String> FINANCE=List.of("finance_report:view","finance:view:all","payment_style:edit","finance_post:execute");
 static String required(String k){String v=System.getenv(k);if(v==null||v.isBlank())throw new IllegalStateException("Missing fixture option: "+k);return v;}
 String fingerprint(String table,String where,Object...args){return db.queryForObject("SELECT md5(COALESCE(jsonb_object_agg(id,to_jsonb(t))::text,'')) FROM "+table+" t "+where,String.class,args);}
 @Test void seedOnlyNewImportActorsAndBomPrerequisites()throws Exception {
  Path out=Path.of(required("UTEN_B_IMPORT_OUTPUT"));if(Files.exists(out))throw new IllegalStateException("Preserve prior fixture output");
  var harness=new FullChainEndToEndTest();beans.autowireBean(harness);Map<String,Object> result;
  try {result=new TransactionTemplate(transactions).execute(status->{
   UUID existingFinance=UUID.fromString("0b887a85-239a-4118-8d3f-246b166a7189");
   String oldRoles=db.queryForObject("SELECT jsonb_agg(to_jsonb(r) ORDER BY role_key)::text FROM system_posting_style_roles r",String.class);
   String oldUsers=fingerprint("users",""),oldGoods=fingerprint("goods","");
   var protectedTables=List.of("goods_bom_items","goods_cost_imports","goods_cost_import_mappings","finance_chart_imports","finance_chart_codes","finance_expense_note_imports","finance_operating_report_notes","finance_statement_source_reviews","finance_auxiliary_items","finance_accounting_import_batches","gl_entries");
   var before=new LinkedHashMap<String,Long>();for(String t:protectedTables)before.put(t,db.queryForObject("SELECT count(*) FROM "+t,Long.class));
   UUID department=db.queryForObject("SELECT e.department_id FROM users u JOIN employees e ON e.id=u.employee_id WHERE u.id=? AND NOT u.is_super_admin AND NOT u.must_change_password",UUID.class,existingFinance);
   var world=new FullChainEndToEndTest.World(department,null,null,null,null,null,null,null,null,null,null,null,null,null,0);
   String tag=UUID.randomUUID().toString().substring(0,8);var accounts=new LinkedHashMap<String,Object>();var newUsers=new ArrayList<UUID>();
   for(var entry:Map.of("masterImport",MASTER,"financeImport",FINANCE).entrySet()) {
    UUID user=harness.createUserWithPerms(world,"b-"+entry.getKey()+"-"+tag,entry.getValue().toArray(String[]::new));newUsers.add(user);
    assertThat(db.update("UPDATE users SET password_hash=?,must_change_password=FALSE WHERE id=?",passwords.encode(required("UTEN_REMEDIATION_B_ACCOUNT_PASSWORD")),user)).isEqualTo(1);
    harness.loginAs(user);var actor=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();assertThat(actor.isSuperAdmin()).isFalse();assertThat(actor.isMustChangePassword()).isFalse();assertThat(actor.getPermissions()).containsAll(entry.getValue());
    accounts.put(entry.getKey(),Map.of("userId",user,"employeeId",actor.getEmployeeId(),"login",actor.getLoginAccount(),"permissions",entry.getValue(),"isSuperAdmin",false));
   }
   UUID master=(UUID)((Map<?,?>)accounts.get("masterImport")).get("userId");harness.loginAs(master);beans.getBean(TxSessionVars.class).bind();
   assertThat(db.queryForObject("SELECT count(*) FROM goods WHERE code='K01'",Integer.class)).as("Do not replace a pre-existing K01").isZero();
   var unit=db.queryForMap("SELECT id,legacy_id FROM units WHERE name='个' AND status='使用' AND NOT is_deleted AND legacy_id IS NOT NULL ORDER BY code LIMIT 1");UUID unitId=(UUID)unit.get("id");int legacy=((Number)unit.get("legacy_id")).intValue();
   UUID parent=UUID.randomUUID(),component=UUID.randomUUID();harness.insertGoods(parent,"BIMP-P-"+tag,"B导入验收独立父件-"+tag,"自制",unitId,legacy);harness.insertGoods(component,"K01","B导入验收K01组件-"+tag,"采购",unitId,legacy);
   UUID owner=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,master);assertThat(db.update("UPDATE goods SET owner_employee_id=? WHERE id IN (?,?)",owner,parent,component)).isEqualTo(2);
   assertThat(db.queryForObject("SELECT jsonb_agg(to_jsonb(r) ORDER BY role_key)::text FROM system_posting_style_roles r",String.class)).isEqualTo(oldRoles);
   assertThat(fingerprint("users","WHERE id NOT IN (?,?)",newUsers.get(0),newUsers.get(1))).isEqualTo(oldUsers);
   assertThat(fingerprint("goods","WHERE id NOT IN (?,?)",parent,component)).isEqualTo(oldGoods);
   for(String t:protectedTables)assertThat(db.queryForObject("SELECT count(*) FROM "+t,Long.class)).as(t+" remains untouched").isEqualTo(before.get(t));
   return Map.<String,Object>of("status","prep only: two ordinary identities and two new BOM prerequisites; zero import/approval/GL/mapping calls","fixtureTag",tag,"accounts",accounts,"passwordSource","Root private syntheticAccountPassword; no credential in seed","reusableFinanceUserId",existingFinance,"bomPrerequisites",Map.of("parentId",parent,"parentCode","BIMP-P-"+tag,"componentId",component,"componentCode","K01","unitId",unitId,"bomRowsCreated",0),"oldUsersUnchanged",true,"oldGoodsUnchanged",true,"roleMappingsUnchanged",true,"protectedCounts",before);
  });}finally{SecurityContextHolder.clearContext();}
  Files.createDirectories(out.getParent());Files.writeString(out,new tools.jackson.databind.ObjectMapper().writerWithDefaultPrettyPrinter().writeValueAsString(result));System.out.println("New synthetic import actors/BOM prerequisites committed; no import executed: "+out);
 }
}
