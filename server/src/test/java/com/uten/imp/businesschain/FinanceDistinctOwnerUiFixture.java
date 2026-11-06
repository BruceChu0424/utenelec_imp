package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.FinanceMaterialStatementSourcePort.Kind;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.finance.asset.api.AssetWorkbenchRequests;
import com.uten.imp.features.finance.asset.application.FinanceAssetWorkflowService;
import com.uten.imp.features.finance.payables.ProcurementPayableRecognitionService;
import com.uten.imp.features.finance.statement.*;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.crypto.password.PasswordEncoder;

import java.math.BigDecimal;
import java.time.YearMonth;
import java.util.*;

import static com.uten.imp.features.finance.statement.FinanceMaterialStatementContracts.*;
import static com.uten.imp.features.finance.statement.FinanceStatementDocumentContracts.*;
import static org.assertj.core.api.Assertions.assertThat;

/** Anonymous manual-UI preconditions only. Target confirmations/activation/posting are never pre-executed. */
final class FinanceDistinctOwnerUiFixture {
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired PasswordEncoder passwords;
    @Autowired ObjectMapper json;
    @Autowired ProcurementPayableRecognitionService first;
    @Autowired FinanceAuxiliaryService auxiliaries;
    @Autowired FinanceStatementDocumentService documents;
    @Autowired FinanceMaterialStatementService materials;
    @Autowired FinanceAssetWorkflowService assets;
    @Autowired com.uten.imp.features.finance.gl.FinanceChartService chartService;

    /** Shared with the task's normal public-permission API configurator. */
    private Set<String> personaPermissions(String role){
        try(var input=getClass().getResourceAsStream("/finance/finance-ui-persona-permissions.json")){
            if(input==null)throw new IllegalStateException("Missing explicit finance UAT persona contract");
            var contract=json.readTree(input);assertThat(contract.path("version").asInt()).isEqualTo(1);
            var permissions=new LinkedHashSet<String>();contract.path("base").forEach(value->permissions.add(value.asText()));
            var persona=contract.path("roles").path(role);assertThat(persona.isObject()).isTrue();
            for(var family:contract.path("families"))for(var action:persona.path("actions"))permissions.add(family.asText()+":"+action.asText());
            persona.path("additional").forEach(value->permissions.add(value.asText()));
            assertThat(permissions).noneMatch(value->value.contains("*")||value.equals("authorization:manage"));
            assertThat(permissions.contains("finance_receipt:approve")).isEqualTo(role.equals("reviewer"));
            return Collections.unmodifiableSet(permissions);
        }catch(java.io.IOException failure){throw new IllegalStateException("Cannot read the explicit finance UAT persona contract",failure);}
    }
    private FullChainEndToEndTest full;
    private FullChainEndToEndTest.World world;
    private UUID maker,reviewer,base;

    Map<String,Object> seed(){
        full=new FullChainEndToEndTest();beans.autowireBean(full);
        world=full.seedWorld("finance-distinct-owners");full.loginAs(world.superAdminUserId());full.seedChartOfAccounts();
        base=db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND status='使用' AND NOT is_deleted ORDER BY id LIMIT 1",UUID.class);
        db.update("UPDATE currencies SET name='匿名界面原币',exchange_rate=7 WHERE id=?",world.currencyId());
        db.update("UPDATE suppliers SET name='匿名原件供应商 UAT' WHERE id=?",world.supplierId());
        db.update("UPDATE clients SET name='匿名材料对象 UAT' WHERE id=?",world.clientId());
        var accounts=new LinkedHashMap<String,Object>();
        var ordinaryEmployees=new HashSet<UUID>();
        for(String surface:List.of("web","windows"))for(String role:List.of("maker","reviewer","poster")){
            String tag="finance-owner-"+surface+"-"+role;
            Set<String> permissions=personaPermissions(role);
            UUID actor=full.createUserWithPerms(world,tag,permissions.toArray(String[]::new));
            full.grantDataScope(actor,"finance",world.employeeId());
            db.update("UPDATE users SET password_hash=?,must_change_password=false WHERE id=?",passwords.encode("FinanceUiSynthetic-2026!"),actor);
            UUID employee=db.queryForObject("SELECT employee_id FROM users WHERE id=? AND NOT is_super_admin AND status='active' AND NOT must_change_password",UUID.class,actor);
            assertThat(employee).isNotNull();assertThat(ordinaryEmployees.add(employee)).isTrue();
            var effective=beans.getBean(com.uten.imp.features.auth.PermissionResolver.class).grantedPermsOf(actor);
            assertThat(effective).containsAll(permissions);
            for(String family:List.of("finance_receipt","finance_payment","finance_expense","finance_other_income","finance_bank_transfer")){
                assertThat(effective.contains(family+":create")).isEqualTo(role.equals("maker"));
                assertThat(effective.contains(family+":edit")).isEqualTo(role.equals("maker"));
                assertThat(effective.contains(family+":approve")).isEqualTo(role.equals("reviewer"));
                assertThat(effective.contains(family+":reverse")).isEqualTo(role.equals("poster"));
            }
            accounts.put(surface+"-"+role,Map.of("id",actor,"employeeId",employee,"login","USR-"+tag,"moneyRole",role,
                    "explicitPermissions",permissions.stream().sorted().toList()));
            if(surface.equals("web")&&role.equals("maker"))maker=actor;
            if(surface.equals("web")&&role.equals("reviewer"))reviewer=actor;
        }
        assertThat(ordinaryEmployees).hasSize(6);
        full.loginAs(world.superAdminUserId());
        preparePayableAccount("2202","AP_CONTROL","LIABILITY");
        var nativeFixture=new SupplierPrepaymentPostgresTest();beans.autowireBean(nativeFixture);
        var policy=first.policy();
        if(Boolean.TRUE.equals(policy.get("enabled")))first.configure(new ProcurementPayableRecognitionService.PolicyInput(((Number)policy.get("revision")).longValue(),false,null,"匿名UAT先建立合法原账载前置，目标原件尚未确认"));
        UUID oldLedger=nativeFixture.receipt(full,world,world.currencyId());
        preparePayableAccount("299901","PROCUREMENT_GRNI_PENDING","LIABILITY");
        preparePayableAccount("122199","PROCUREMENT_RETURN_PENDING_ASSET","ASSET");
        policy=first.policy();first.configure(new ProcurementPayableRecognitionService.PolicyInput(((Number)policy.get("revision")).longValue(),true,BusinessTime.today(),"匿名UAT新来源须由真实客户端确认后首次立应付"));
        UUID pendingReceipt=nativeFixture.receipt(full,world,world.currencyId(),true);
        var candidate=db.queryForMap("SELECT id,status,ledger_id FROM finance_procurement_payable_candidates WHERE source_id=?",pendingReceipt);
        assertThat(candidate.get("status")).isEqualTo("PENDING");assertThat(candidate.get("ledger_id")).isNull();
        UUID pendingLine=db.queryForObject("SELECT id FROM purchase_receipt_items WHERE receipt_id=? AND NOT is_deleted",UUID.class,pendingReceipt);
        var payableRef=auxiliaries.resolveNative("2202","SUPPLIER",world.supplierId(),base);
        prepareStatementProfiles(payableRef.auxiliaryId());
        var material=prepareMaterialContext();
        var asset=prepareAssetDraft(false);
        var deferred=prepareAssetDraft(true);
        assertThat(db.queryForObject("SELECT count(*) FROM finance_statement_document_reviews WHERE party_id=? AND currency_id=?",Integer.class,world.supplierId(),world.currencyId())).isZero();
        assertThat(db.queryForObject("SELECT count(*) FROM finance_material_evidence WHERE context_id=? AND kind IN('UNIT','WEIGHT')",Integer.class,material)).isZero();
        assertThat(db.queryForObject("SELECT lifecycle_status FROM fixed_assets WHERE id=?",String.class,asset)).isEqualTo("DRAFT");
        assertThat(db.queryForObject("SELECT lifecycle_status FROM deferred_expenses WHERE id=?",String.class,deferred)).isEqualTo("DRAFT");
        assertThat(db.queryForObject("SELECT count(*) FROM finance_asset_posting_runs",Integer.class)).isZero();
        var result=new LinkedHashMap<String,Object>();
        result.put("scope","ANONYMOUS_REAL_SERVICE_PRECONDITIONS_NOT_TARGET_UI_ACCEPTANCE");
        result.put("businessDay",BusinessTime.today().toString());result.put("period",YearMonth.from(BusinessTime.today()).toString());
        result.put("ordinaryAccounts",accounts);
        result.put("statement",Map.of("supplierId",world.supplierId(),"currencyId",world.currencyId(),"originalLedgerId",oldLedger,
            "pendingReceiptId",pendingReceipt,"pendingCandidateId",candidate.get("id"),"targetState","NO_ORIGINAL_REVIEW_AND_NO_FIRST_AP_RECOGNITION",
            "route","/finance/report/recon","templateKey","supplierStatement"));
        result.put("material",Map.of("contextId",material,"sourceLineId",pendingLine,"sourceKind","PURCHASE_RECEIPT_LINE",
            "sourceGoodsId",world.goodsA(),"sourceUnitId",world.unitId(),"targetState","APPROVED_CONTEXT_AND_PARTY_GOODS_ONLY_NO_UNIT_OR_WEIGHT",
            "route","/finance/report/recon","templateKey","otherReceivableStatement"));
        result.put("assets",Map.of("fixedId",asset,"deferredId",deferred,"targetState","TWO_DRAFTS_NO_APPROVAL_ACTIVATION_OR_POSTING",
            "route","/finance/assets","expectedFiniteMonthlyAmount","10","uiOrder","submit -> other reviewer approve -> nonmaker activate -> preview -> submit -> other reviewer approve -> nonmaker post"));
        full.loginAs(world.superAdminUserId());return result;
    }

    private void preparePayableAccount(String code,String role,String classification){
        UUID style=db.queryForObject("SELECT system_posting_style_id(?)",UUID.class,role);
        if(style==null){style=style(classification.equals("ASSET")?"ACCOUNT":"LIABILITY","匿名来源用途 "+role);db.update("UPDATE system_posting_style_roles SET style_id=? WHERE role_key=?",style,role);}
        chart(code,style,classification);
        var rule=auxiliaries.readRule(code);auxiliaries.saveRule(code,new FinanceAuxiliaryContracts.RuleInput(rule.version(),true,List.of("SUPPLIER"),"匿名UAT实际供应商辅助前置"));
        auxiliaries.save(new FinanceAuxiliaryContracts.Save(null,null,"匿名界面原件账套","UAT-SUP-"+world.supplierId(),"匿名原件供应商 UAT","SUPPLIER",world.supplierId(),"只按实际UUID配置匿名来源",code));
    }
    private void prepareStatementProfiles(UUID auxiliary){
        for(String kind:List.of("OWN","COUNTERPART","CONTEXT")){
            full.loginAs(maker);
            var organization=kind.equals("CONTEXT")?null:new Organization("匿名"+kind+"资料 UAT","匿名地址","UAT-PHONE","UAT-FAX","匿名户名","匿名银行","SYNTHETIC-NOT-A-BANK-ACCOUNT","匿名收货人","UAT-PHONE","仅匿名资料，不含原附件账号");
            var settings=kind.equals("CONTEXT")?new Settings(new BalanceSelection("2202",auxiliary,base,world.currencyId(),true,-1),List.of(),"匿名八列原件完整核对"):null;
            UUID id=(UUID)documents.saveProfile(new ProfileSave(UUID.randomUUID(),-1,kind,kind.equals("CONTEXT")?"supplierStatement":"ALL",kind.equals("OWN")?null:"SUPPLIER",kind.equals("OWN")?null:world.supplierId(),world.currencyId(),organization,settings,"匿名组织/页尾基础资料预置，不预批原件")).get("id");
            full.loginAs(reviewer);documents.decideProfile(id,new Decision(true,"另一真实匿名用户核对基础资料"));
        }
        full.loginAs(world.superAdminUserId());
    }
    private UUID prepareMaterialContext(){
        UUID style=style("ACCOUNT","匿名材料往来 UAT");chart("1221",style,"ASSET");
        long version=db.queryForObject("SELECT row_version FROM finance_chart_codes WHERE code='1221'",Long.class);
        chartService.map("1221",new com.uten.imp.features.finance.gl.FinanceChartContracts.Mapping(
            version,List.of(style),"BS_8",null,"ASSET",base));
        assertThat(db.queryForObject("SELECT count(*) FROM finance_chart_code_styles map JOIN finance_report_line_bindings binding ON binding.style_id=map.style_id WHERE map.code='1221' AND map.style_id=? AND binding.binding_kind='STYLE' AND binding.line_key='BS_8'",Integer.class,style)).isEqualTo(1);
        var auxiliary=auxiliaries.save(new FinanceAuxiliaryContracts.Save(null,null,"匿名材料UAT账套","UAT-MAT-"+world.clientId(),"匿名材料对象 UAT","CUSTOMER",world.clientId(),"真实财务对象UUID前置","1221"));
        full.loginAs(maker);
        var saved=materials.saveContext(new ContextInput(UUID.randomUUID(),null,null,auxiliary.id(),base,AmountBasis.LOCAL,null,world.goodsB(),null,BusinessTime.today(),"匿名实际KG维护前置，目标单位换算未保存","1221",1,Set.of(Kind.PURCHASE_RECEIPT_LINE),"匿名铜料产品 UAT","匿名规格",world.unitId(),"PCS",null,null,1));
        UUID context=UUID.fromString(saved.get("contextId").toString()),evidence=UUID.fromString(saved.get("evidenceId").toString());
        approveMaterial(context,evidence);
        materialBasis(context,EvidenceKind.GOODS,new SourceGoods(context,Kind.PURCHASE_RECEIPT_LINE,world.goodsA(),null,FlowRole.INBOUND,"匿名实际已入库原料归属前置",true,"匿名铜料 UAT","匿名规格"));
        materialBasis(context,EvidenceKind.NATIVE_PARTY,new NativePartyLink(UUID.randomUUID(),context,0,"SUPPLIER",world.supplierId(),Kind.PURCHASE_RECEIPT_LINE,"匿名供应商UUID归属前置",true));
        full.loginAs(world.superAdminUserId());return context;
    }
    private void materialBasis(UUID context,EvidenceKind kind,Object input){
        full.loginAs(maker);var saved=materials.saveDraft(new Draft(UUID.randomUUID(),null,-1,context,contextVersion(context),null,kind,json.valueToTree(input)));
        approveMaterial(context,UUID.fromString(saved.get("evidenceId").toString()));
    }
    private long contextVersion(UUID context){return ((Number)materials.get(context).get("row_version")).longValue();}
    private Action materialAction(UUID context,UUID evidence){return new Action(UUID.randomUUID(),((Number)materials.evidence(evidence).get("version")).longValue(),contextVersion(context),"匿名基础归属预审，实际KG证据留真实客户端");}
    private void approveMaterial(UUID context,UUID evidence){
        full.loginAs(maker);materials.submit(evidence,materialAction(context,evidence));
        full.loginAs(reviewer);materials.decide(evidence,"approve",materialAction(context,evidence));full.loginAs(maker);
    }
    private UUID prepareAssetDraft(boolean deferred){
        UUID cost=style("ACCOUNT","匿名"+(deferred?"待摊成本":"固定资产原值")+" UAT"),accumulated=deferred?null:style("ACCOUNT","匿名累计折旧 UAT"),expense=style("EXPENSE","匿名"+(deferred?"摊销":"折旧")+"费用 UAT"),clearing=style("ACCOUNT","匿名"+(deferred?"待摊":"固定资产")+"待结算 UAT"),category=UUID.randomUUID();
        db.update("INSERT INTO finance_asset_categories(id,object_type,code,name,cost_style_id,accumulated_style_id,expense_style_id,clearing_style_id,default_method,default_months,default_salvage_rate,effective_from,status) VALUES(?,?,?,?,?,?,?,?,'STRAIGHT_LINE',12,0,?,'ACTIVE')",category,deferred?"DEFERRED_EXPENSE":"FIXED_ASSET","UAT-OWNER-"+category,deferred?"匿名待摊 UAT":"匿名固定资产 UAT",cost,accumulated,expense,clearing,BusinessTime.today().withDayOfMonth(1).minusDays(1));
        UUID employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,maker);
        var month=YearMonth.from(BusinessTime.today());var acquisition=month.atDay(1).minusDays(1);
        full.loginAs(maker);
        if(deferred)return assets.createDeferred(new AssetWorkbenchRequests.DeferredExpenseDraft(null,"匿名待摊一期计提 UAT",category,world.departmentId(),employee,"匿名UAT位置","UAT",new BigDecimal("120"),12,month.toString(),month.atDay(1),month.plusMonths(11).atEndOfMonth(),"MANUAL",null,"UAT-DEFERRED-OWNER","HEADER",month.atDay(1),"仅DRAFT，审批及计提留真实客户端",null)).id();
        return assets.createFixed(new AssetWorkbenchRequests.FixedAssetDraft(null,"匿名固定资产一期计提 UAT",category,world.departmentId(),employee,"匿名UAT位置","UAT-SERIAL",null,"UAT",new BigDecimal("120"),BigDecimal.ZERO,12,month.toString(),acquisition,acquisition,acquisition,"MANUAL",null,"UAT-FIXED-OWNER","HEADER",acquisition,"仅DRAFT，审批及计提留真实客户端",null)).id();
    }
    private UUID style(String category,String name){UUID id=UUID.randomUUID();db.update("INSERT INTO payment_styles(id,code,name,category,level,status) VALUES(?,?,?,?,0,'使用')",id,"UAT-OWNER-"+id,name,category);return id;}
    private void chart(String code,UUID style,String classification){
        db.update("INSERT INTO finance_chart_codes(code,name,currency_name,currency_id,classification,source_kind,source_reference,sort_order,source_row,updated_by) VALUES(?,?,'',?,?,'MANUAL','匿名实际UAT前置',1,1,?) ON CONFLICT(code) DO UPDATE SET currency_id=excluded.currency_id",code,"匿名财务代码 "+code,base,classification,world.superAdminUserId());
        db.update("INSERT INTO finance_chart_code_styles(code,style_id,created_by) VALUES(?,?,?) ON CONFLICT(style_id) DO NOTHING",code,style,world.superAdminUserId());
    }
}
