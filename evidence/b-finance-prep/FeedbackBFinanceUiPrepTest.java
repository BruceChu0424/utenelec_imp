package com.uten.imp.businesschain;

import com.uten.imp.features.finance.gl.SystemPostingStyleService;
import com.uten.imp.features.master.paymentstyle.PaymentStyleService;
import com.uten.imp.features.master.paymentstyle.dto.PaymentStyleSaveRequest;
import com.uten.imp.security.AuthUser;
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

/** Adds only new synthetic actor/accounts. Role mappings remain for actual UI. */
@EnabledIfEnvironmentVariable(named="UTEN_B_FINANCE_ALLOW_SEED",matches="true")
@SpringBootTest(properties={"spring.profiles.active=dev","uten.audit.retention.enabled=false",
    "uten.reporting.materialized-view-refresh.enabled=false","uten.production.readiness-reconcile.enabled=false",
    "uten.storage.uploads-enabled=false"})
class FeedbackBFinanceUiPrepTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FeedbackBWebSeedTest.database(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PasswordEncoder passwords;
    @Autowired PaymentStyleService paymentStyles;
    @Autowired SystemPostingStyleService roles;
    @Autowired PlatformTransactionManager transactions;
    private static String required(String key){String value=System.getenv(key);if(value==null||value.isBlank())throw new IllegalStateException("Required fixture option: "+key);return value;}
    private static final List<String> PERMISSIONS=List.of("payment_style:view","payment_style:edit","payment_style:create","finance_post:execute","finance_report:view","finance:view:all");

    @Test void seedOnlyNewFinanceActorAndUnassignedStyles() throws Exception {
        Path output=Path.of(required("UTEN_B_FINANCE_OUTPUT"));
        if(Files.exists(output))throw new IllegalStateException("Preserve previous seed output");
        var json=new tools.jackson.databind.ObjectMapper();
        var source=json.readTree(Files.readString(Path.of(required("UTEN_B_FINANCE_SOURCE_SEED"))));
        UUID maker=json.convertValue(source.path("maker").path("userId"),UUID.class);
        UUID approver=json.convertValue(source.path("approver").path("userId"),UUID.class);
        var harness=new FullChainEndToEndTest();beans.autowireBean(harness);
        Map<String,Object> result;
        try {
            result=new TransactionTemplate(transactions).execute(status->{
                String roleSql="SELECT jsonb_agg(to_jsonb(r) ORDER BY role_key)::text FROM system_posting_style_roles r";
                String beforeRoleBytes=db.queryForObject(roleSql,String.class);
                var oldStyles=db.queryForMap("SELECT COALESCE(jsonb_object_agg(id,to_jsonb(s)),'{}'::jsonb)::text AS rows FROM payment_styles s");
                var oldAccounts=db.queryForObject("SELECT md5(jsonb_object_agg(id,jsonb_build_object('employee',employee_id,'login',login_account,'super',is_super_admin,'status',status,'mustChange',must_change_password,'deleted',is_deleted,'passwordHash',password_hash))::text) FROM users",String.class);
                assertThat(db.queryForList("SELECT code FROM permissions WHERE code IN ('payment_style:view','payment_style:edit','payment_style:create','finance_post:execute','finance_report:view','finance:view:all')",String.class)).containsExactlyInAnyOrderElementsOf(PERMISSIONS);
                UUID department=db.queryForObject("SELECT e.department_id FROM users u JOIN employees e ON e.id=u.employee_id WHERE u.id=?",UUID.class,maker);
                var partialWorld=new FullChainEndToEndTest.World(department,null,null,null,null,null,null,null,null,null,null,null,null,null,0);
                String tag=UUID.randomUUID().toString().substring(0,8);
                UUID actor=harness.createUserWithPerms(partialWorld,"b-finance-ui-"+tag,PERMISSIONS.toArray(String[]::new));
                assertThat(actor).isNotIn(maker,approver);
                assertThat(db.update("UPDATE users SET password_hash=?,must_change_password=FALSE WHERE id=?",passwords.encode(required("UTEN_REMEDIATION_B_ACCOUNT_PASSWORD")),actor)).isEqualTo(1);
                harness.loginAs(actor);var creator=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();
                assertThat(creator.isSuperAdmin()).isFalse();assertThat(creator.isMustChangePassword()).isFalse();assertThat(creator.getPermissions()).containsAll(PERMISSIONS);
                var mapping=new ArrayList<Map<String,Object>>();
                for(var role:roles.list()) {
                    var item=new LinkedHashMap<String,Object>();item.put("roleKey",role.roleKey());item.put("description",role.description());item.put("requiredCategory",role.requiredCategory());item.put("existingStyleId",role.styleId());item.put("existingStyleName",role.styleName());item.put("usableBefore",role.usable());
                    if(role.usable())item.put("action","KEEP_EXISTING_USABLE_MAPPING");
                    else if(role.styleId()!=null)item.put("action","BLOCKED: restore retained historical account; do not replace mapping");
                    else {
                        var request=new PaymentStyleSaveRequest();request.setCategory(role.requiredCategory());request.setStatus("使用");
                        request.setName("B验收合成-"+role.roleKey()+"-"+tag);
                        // The new ordinary actor has the explicit create permission required
                        // by the existing public service. No old identity or role config changes.
                        var style=paymentStyles.create(request);
                        assertThat(style.getCategory()).isEqualTo(role.requiredCategory());
                        item.put("candidateStyleId",style.getId());item.put("candidateStyleCode",style.getCode());item.put("candidateStyleName",style.getName());item.put("candidateCategory",style.getCategory());item.put("action","PREPARED_UNASSIGNED: Root must configure through actual ordinary finance UI");
                    }
                    mapping.add(item);
                }
                harness.loginAs(actor);var auth=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();
                assertThat(auth.isSuperAdmin()).isFalse();assertThat(auth.getPermissions()).containsAll(PERMISSIONS);assertThat(auth.getPermissions()).doesNotContain("purchase_return:approve","subcontract_return:approve");
                for(var role:roles.list())if(!role.usable())assertThat(role.canConfigure()).as("ordinary UI configuration must be available: "+role.roleKey()).isTrue();
                assertThat(db.queryForObject(roleSql,String.class)).as("no role mapping changed by fixture").isEqualTo(beforeRoleBytes);
                assertThat(db.queryForObject("SELECT COALESCE(jsonb_object_agg(id,to_jsonb(s)),'{}'::jsonb)::text FROM payment_styles s WHERE NOT name LIKE ?",String.class,"B验收合成-%-"+tag)).isEqualTo(oldStyles.get("rows"));
                assertThat(db.queryForObject("SELECT md5(jsonb_object_agg(id,jsonb_build_object('employee',employee_id,'login',login_account,'super',is_super_admin,'status',status,'mustChange',must_change_password,'deleted',is_deleted,'passwordHash',password_hash))::text) FROM users WHERE id<>?",String.class,actor)).as("old accounts including password hashes are untouched").isEqualTo(oldAccounts);
                var data=new LinkedHashMap<String,Object>();data.put("status","prep only: new synthetic finance actor and unassigned accounts; no Web configuration, GL generation or return approval executed");data.put("fixtureTag",tag);data.put("database",System.getenv("UTEN_REMEDIATION_B_JDBC_URL"));
                data.put("syntheticFinance",Map.of("userId",actor,"employeeId",auth.getEmployeeId(),"login",auth.getLoginAccount(),"isSuperAdmin",false,"permissions",PERMISSIONS,"passwordSource","private runtime syntheticAccountPassword; no credential in this seed"));
                data.put("roleCandidates",mapping);data.put("roleMappingsUnchanged",true);data.put("oldAccountsUnchanged",true);data.put("oldPaymentStylesUnchanged",true);data.put("publicCreationService","PaymentStyleService.create / POST /api/master/payment-styles; new ordinary syntheticFinance with required payment_style:create");data.put("publicConfigurationService","SystemPostingStyleService.configure / PUT /api/finance/posting-style-roles/{roleKey}; {styleId,expectedUpdatedAt}");
                data.put("configurationUi","/basicinfo/payment-style > 系统科目用途 > 对应用途类别下拉 > 保存用途");data.put("glGenerationUi","NO EXISTING FLUTTER BUTTON/CALLER FOUND; future ordinary public HTTP generation and actual GL report UI must be separate evidence");data.put("glPublicHttp","POST /api/finance/gl/generate?period=YYYY-MM");data.put("glReadUi","/finance/report/gl");return data;
            });
        } finally {SecurityContextHolder.clearContext();}
        Files.createDirectories(output.getParent());Files.writeString(output,json.writerWithDefaultPrettyPrinter().writeValueAsString(result));
        System.out.println("Synthetic finance preparation committed; seed contains no credentials: "+output);
    }
}
