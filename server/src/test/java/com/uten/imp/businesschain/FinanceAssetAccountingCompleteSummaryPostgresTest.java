package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.*;
import com.uten.imp.features.finance.asset.api.*;
import com.uten.imp.features.finance.asset.application.*;
import com.uten.imp.features.finance.gl.*;
import com.uten.imp.features.finance.report.FinanceTemplateSourceReader;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.*;
import java.net.*;
import java.net.http.*;
import java.nio.charset.StandardCharsets;
import java.time.*;
import java.math.BigDecimal;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Current TCP/JWT/service/PG summary contracts. Bulk rows exercise metadata reads,
 * not1001 independent import approvals; actual lifecycle samples use production commands.
 * Every PostgreSQL guard stays enabled. Source bodies must never become list payloads. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.RANDOM_PORT,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.workshop-material.auto-close.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.policy-intelligence.enabled=false",
        "uten.finance.asset.posted-workflows-enabled=true","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@FinanceScopedChain @TestMethodOrder(MethodOrderer.OrderAnnotation.class)
class FinanceAssetAccountingCompleteSummaryPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry r){FinanceScopedChainDatabase.register(r,FinanceAssetAccountingCompleteSummaryPostgresTest.class);}
    @Autowired JdbcTemplate db;
    @Autowired ObjectMapper json;
    @Autowired PasswordEncoder passwords;
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired FinanceAccountingImportService imports;
    @Autowired FinanceChartService chart;
    @Autowired FinanceAssetWorkflowService workflow;
    @Autowired FinanceAssetOpeningGroupService groups;
    @LocalServerPort int port;
    private final HttpClient http=HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(15)).build();
    private FullChainEndToEndTest fixture;
    private FullChainEndToEndTest.World world;
    private UUID actor,other,denied;
    private String tag,token,otherToken,deniedToken;
    private static final String ACCOUNTING="/api/finance/accounting-imports/summaries";
    private static final String ASSETS="/api/finance/asset-opening-groups/summaries";
    @BeforeEach void setup() throws Exception {
        tag=UUID.randomUUID().toString().substring(0,8);fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        world=fixture.seedWorld("asset-accounting-summary-"+tag);
        String[] permissions={"finance_report:view","finance:view:all","finance_post:execute","payment_style:edit","payment_style:create","finance_asset:view","finance_asset:edit","finance_asset:approve"};
        actor=fixture.createUserWithPerms(world,"summary-a-"+tag,permissions);other=fixture.createUserWithPerms(world,"summary-b-"+tag,permissions);
        denied=fixture.createUserWithPerms(world,"summary-denied-"+tag,"goods:view");
        token=login(actor);otherToken=login(other);deniedToken=login(denied);fixture.loginAs(actor);
    }
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test @Order(1) void accounting1001OwnPreviewTailLegacyTerminalHistoryAndModernRejectWithdrawStayDistinct() throws Exception {
        assertThat(db.queryForObject("SELECT string_agg(pg_get_constraintdef(oid),' ') FROM pg_constraint WHERE conrelid='finance_accounting_import_batches'::regclass AND contype='c'",String.class)).contains("REJECTED","CANCELLED","PREVIEW","SUBMITTED","POSTED");
        prepareChart();
        var base=imports.preview("BALANCE","metadata-base-"+tag,"balance.xls",FinanceAccountingContinuationPostgresTest.balance());
        Set<String> own=seedAccounting(actor,base.importId(),1000,"own-"+tag,"PREVIEW");
        Set<String> foreign=seedAccounting(other,base.importId(),2,"foreign-"+tag,"PREVIEW");
        // These are permitted historical statuses, not the result of the modern reject/withdraw commands.
        Set<String> legacy=new LinkedHashSet<>();legacy.addAll(seedAccounting(actor,base.importId(),1,"legacy-rejected-"+tag,"REJECTED"));
        legacy.addAll(seedAccounting(other,base.importId(),1,"legacy-cancelled-"+tag,"CANCELLED"));
        var initial=fingerprints();
        var active=new LinkedHashSet<>(own);active.add(base.importId().toString());
        // Literal1001 authorized active roots include the real intake and1000 copied read-metadata fixtures.
        var allOwn=readAll(ACCOUNTING,"active",token,active,"finance_accounting_import_batches");
        assertThat(allOwn).noneMatch(row->foreign.contains(row.path("id").asText()));
        readAll(ACCOUNTING,"active",otherToken,foreign,"finance_accounting_import_batches");
        readAll(ACCOUNTING,"history",token,legacy,"finance_accounting_import_batches");
        var all=new LinkedHashSet<>(active);all.addAll(legacy);readAll(ACCOUNTING,"all",token,all,"finance_accounting_import_batches");
        request(ACCOUNTING+"?scope=all&page=1&size=1000",deniedToken,403);
        request("/api/finance/accounting-imports/"+foreign.iterator().next(),token,403);
        for(String id:legacy)assertThat(request("/api/finance/accounting-imports/"+id,token,200).path("status").asText()).isIn("REJECTED","CANCELLED");
        assertThat(fingerprints()).isEqualTo(initial);
        var modern=preparedPair("modern-reject-"+tag);var submitted=imports.submit(modern.voucher().importId(),modern.request());
        fixture.loginAs(other);imports.reject(modern.voucher().importId(),new FinanceAccountingContracts.Review(submitted.version(),"另一人拒绝，保留可修订预览"));
        fixture.loginAs(actor);var reset=imports.get(modern.voucher().importId());assertThat(reset.status()).isEqualTo("PREVIEW");
        var resetBalance=imports.get(modern.balance().importId());var again=imports.submit(reset.importId(),requestFor(reset,resetBalance));
        imports.withdraw(reset.importId(),new FinanceAccountingContracts.Review(again.version(),"原提交人撤回仍在待办理"));
        assertThat(imports.get(reset.importId()).status()).isEqualTo("PREVIEW");
        var posted=preparedPair("real-posted-"+tag);var postSubmitted=imports.submit(posted.voucher().importId(),posted.request());
        fixture.loginAs(other);imports.approve(posted.voucher().importId(),new FinanceAccountingContracts.Review(postSubmitted.version(),"另一人按完整原件核对后入账"));fixture.loginAs(actor);
        var expectedActive=new LinkedHashSet<>(active);expectedActive.add(modern.voucher().importId().toString());expectedActive.add(modern.balance().importId().toString());
        var expectedHistory=new LinkedHashSet<>(legacy);expectedHistory.add(posted.voucher().importId().toString());expectedHistory.add(posted.balance().importId().toString());
        var before=fingerprints();
        readAll(ACCOUNTING,"active",token,expectedActive,"finance_accounting_import_batches");readAll(ACCOUNTING,"history",token,expectedHistory,"finance_accounting_import_batches");
        assertThat(fingerprints()).isEqualTo(before);
        JsonNode first=request(ACCOUNTING+"?scope=active&page=1&size=1000",token,200);
        imports.preview("BALANCE","new-source-"+tag,"new.xls",FinanceAccountingContinuationPostgresTest.balance());var after=fingerprints();
        request(ACCOUNTING+"?scope=active&page=2&size=1000&readSnapshotRevision="+first.path("readSnapshotRevision").asText(),token,409);assertThat(fingerprints()).isEqualTo(after);
    }

    @Test @Order(2) void asset1001LiteralPendingTailAndRealApproveRevokeMoveOnlyScopeWithoutReadWrites() throws Exception {
        UUID real=createRealAssetGroup();
        Set<String> active=seedAssetGroups(real,1000);active.add(real.toString());
        var before=fingerprints();
        readAll(ASSETS,"active",token,active,"finance_asset_opening_groups");
        readAll(ASSETS,"active",otherToken,active,"finance_asset_opening_groups");
        readAll(ASSETS,"history",token,Set.of(),"finance_asset_opening_groups");request(ASSETS+"?scope=all&page=1&size=1000",deniedToken,403);
        assertThat(fingerprints()).isEqualTo(before);
        var originalBody=db.queryForObject("SELECT (to_jsonb(g)-ARRAY['status','row_version','approved_by','approved_at','revoke_actor_id','revoke_reason','revoke_approved_by','revoked_at'])::text FROM finance_asset_opening_groups g WHERE id=?",String.class,real);
        fixture.loginAs(other);groups.approve(real,new AssetOpeningGroupContracts.Action(0,"真实另一人复核后进入历史"));
        active.remove(real.toString());var expectedHistory=Set.of(real.toString());var afterApprove=fingerprints();
        readAll(ASSETS,"active",token,active,"finance_asset_opening_groups");readAll(ASSETS,"history",token,expectedHistory,"finance_asset_opening_groups");assertThat(fingerprints()).isEqualTo(afterApprove);
        fixture.loginAs(actor);groups.requestRevoke(real,new AssetOpeningGroupContracts.Action(1,"历史中的真实原组申请撤销回待办"));
        active.add(real.toString());var beforeRevokeRead=fingerprints();readAll(ASSETS,"active",token,active,"finance_asset_opening_groups");readAll(ASSETS,"history",token,Set.of(),"finance_asset_opening_groups");assertThat(fingerprints()).isEqualTo(beforeRevokeRead);
        fixture.loginAs(other);groups.approveRevoke(real,new AssetOpeningGroupContracts.Action(2,"另一人完成撤销，保全部来源进入历史"));
        active.remove(real.toString());var afterRevoke=fingerprints();readAll(ASSETS,"active",token,active,"finance_asset_opening_groups");readAll(ASSETS,"history",token,expectedHistory,"finance_asset_opening_groups");assertThat(fingerprints()).isEqualTo(afterRevoke);
        assertThat(db.queryForObject("SELECT (to_jsonb(g)-ARRAY['status','row_version','approved_by','approved_at','revoke_actor_id','revoke_reason','revoke_approved_by','revoked_at'])::text FROM finance_asset_opening_groups g WHERE id=?",String.class,real)).isEqualTo(originalBody);
    }

    private void prepareChart() {
        var categories=Map.of("1001","ACCOUNT","3001","EQUITY","5001","INCOME","3103","EQUITY","560301","EXPENSE");
        var names=Map.of("1001","库存现金","3001","实收资本","5001","主营业务收入","3103","本年利润","560301","匿名损益明细");
        for(String code:List.of("1001","3001","5001","3103","560301"))chart.createAccount(new FinanceChartContracts.CreateAccount(UUID.randomUUID(),code,names.get(code),"",categories.get(code),"复用会计接续原始夹具"));
        for(var account:chart.list()) {
            String bs=switch(account.code()){case "1001"->"BS_1";case "3001"->"BS_48";case "3103"->"BS_51";default->null;};
            String pl=switch(account.code()){case "5001"->"PL_1";case "560301"->"PL_FINANCE";default->null;};
            chart.map(account.code(),new FinanceChartContracts.Mapping(account.version(),account.targets().stream().map(t->t.id()).toList(),bs,pl));
        }
    }
    private record Pair(FinanceAccountingContracts.Preview voucher,FinanceAccountingContracts.Preview balance,FinanceAccountingContracts.Submit request) { }
    private Pair preparedPair(String system) throws Exception {
        var balance=imports.preview("BALANCE",system,"balance.xls",FinanceAccountingContinuationPostgresTest.balance());
        var vouchers=imports.preview("VOUCHERS",system,"vouchers.xls",FinanceAccountingContinuationPostgresTest.journals());
        assertThat(balance.source().issues()).isEmpty();assertThat(vouchers.source().issues()).isEmpty();
        return new Pair(vouchers,balance,requestFor(vouchers,balance));
    }
    private FinanceAccountingContracts.Submit requestFor(FinanceAccountingContracts.Preview vouchers,FinanceAccountingContracts.Preview balance) {
        var selected=chart.list().stream().map(a->new FinanceAccountingContracts.AccountSelection(a.code(),a.targets().getFirst().id(),a.version(),a.currencyId())).toList();
        var purposes=new LinkedHashMap<String,String>();vouchers.source().vouchers().forEach(v->purposes.put(v.key(),v.closingCandidate()?"PNL_CLOSE":"OPERATING"));
        return new FinanceAccountingContracts.Submit(vouchers.version(),balance.importId(),balance.version(),selected,purposes,Map.of(),List.of(),Set.of("560301"),false,true,"复用原完整凭证/余额及明确零余额例外");
    }
    private Set<String> seedAccounting(UUID owner,UUID base,int count,String prefix,String status) {
        db.update("""
                INSERT INTO finance_accounting_import_batches(id,actor_id,source_name,storage_provider,storage_key,storage_version,storage_size,sha256,source_system,preview,status,kind,created_at)
                SELECT gen_random_uuid(),?,?||n::text,b.storage_provider,b.storage_key,b.storage_version,b.storage_size,b.sha256,?||n::text,b.preview,?,b.kind,
                    TIMESTAMPTZ '2026-01-01 00:00:00+00'+n*interval '1 second'
                FROM finance_accounting_import_batches b CROSS JOIN generate_series(1,?) n WHERE b.id=?
                """,owner,prefix,prefix,status,count,base);
        return new LinkedHashSet<>(db.queryForList("SELECT id::text FROM finance_accounting_import_batches WHERE source_system LIKE ? ORDER BY created_at DESC,id DESC",String.class,prefix+"%"));
    }
    private UUID createRealAssetGroup() throws Exception {
        UUID cost=style("ACCOUNT"),accumulated=style("ACCOUNT"),expense=style("EXPENSE"),clearing=style("ACCOUNT"),category=UUID.randomUUID();
        db.update("INSERT INTO finance_asset_categories(id,object_type,code,name,cost_style_id,accumulated_style_id,expense_style_id,clearing_style_id,default_method,default_months,default_salvage_rate,effective_from,status) VALUES(?,'FIXED_ASSET',?,'摘要原组类别',?,?,?,?,'STRAIGHT_LINE',12,.05,CURRENT_DATE,'ACTIVE')",category,"SUMMARY-CAT-"+tag,cost,accumulated,expense,clearing);
        var asOf=YearMonth.now().minusMonths(1).atEndOfMonth();var benefit=YearMonth.from(asOf).minusMonths(5).atDay(1);String name="摘要真实资产-"+tag;
        var draft=workflow.createFixed(new AssetWorkbenchRequests.FixedAssetDraft(null,name,category,world.departmentId(),world.employeeId(),"一楼",null,null,null,new BigDecimal("1000"),new BigDecimal(".05"),12,YearMonth.from(benefit).plusMonths(1).toString(),benefit,benefit,benefit,"MANUAL",null,"SUMMARY-ASSET-"+tag,"HEADER",benefit,null,null));
        List<FinanceTemplateSourceReader.Cell> cells=new ArrayList<>();cells.add(new FinanceTemplateSourceReader.Cell(6,name,"TEXT",null));cells.add(new FinanceTemplateSourceReader.Cell(9,"1000","NUMBER","1000"));cells.add(new FinanceTemplateSourceReader.Cell(11,"79.1666666666667","NUMBER","79.1666666666667"));cells.add(new FinanceTemplateSourceReader.Cell(36,"475","NUMBER","475"));cells.add(new FinanceTemplateSourceReader.Cell(12+12-asOf.getMonthValue(),"475","NUMBER","475"));cells.add(new FinanceTemplateSourceReader.Cell(8,benefit.toString(),"DATE",null));
        UUID source=UUID.randomUUID();String hash=com.uten.imp.common.storage.ImmutableDocumentStore.digest(source.toString().getBytes(StandardCharsets.UTF_8));
        var preview=new FinanceTemplateSourceReader.Preview(source,"depreciation",YearMonth.from(asOf).toString(),"source.xlsx",hash,"匿名原资产表",List.of(),List.of(new FinanceTemplateSourceReader.Row(3,cells)),List.of(),true);
        db.update("INSERT INTO finance_template_sources(id,actor_id,template_key,period,source_name,sha256,storage_provider,storage_key,storage_size,preview) VALUES(?,?,'depreciation',?,'source.xlsx',?,'TEST','asset-summary-source',1,?::jsonb)",source,actor,YearMonth.from(asOf).toString(),hash,json.writeValueAsString(preview));
        UUID voucher=UUID.randomUUID(),costEntry=UUID.randomUUID(),creditEntry=UUID.randomUUID();
        db.update("INSERT INTO gl_vouchers(id,voucher_no,period,voucher_date,source,source_type,status) VALUES(?,?,?,?,'MANUAL','MANUAL',1)",voucher,"SUMMARY-GROUP-"+tag,YearMonth.from(asOf).toString(),asOf);
        db.update("INSERT INTO gl_entries(id,voucher_id,line_no,style_id,direction,amount,entry_date,period) VALUES(?,?,1,?,1,1000,?,?),(?,?,2,?,-1,475,?,?),(gen_random_uuid(),?,3,?,-1,525,?,?)",costEntry,voucher,cost,asOf,YearMonth.from(asOf).toString(),creditEntry,voucher,accumulated,asOf,YearMonth.from(asOf).toString(),voucher,clearing,asOf,YearMonth.from(asOf).toString());
        UUID id=UUID.randomUUID();
        // This fixture explicitly adopts its original source monthly amount79.1666666666667.
        // The choice is local to this command; no product default or frozen source value changes.
        var explicitSourceChoice=com.uten.imp.common.finance.BusinessPrecisionContext.use(Map.of(
                "money.cumulative-share",new com.uten.imp.common.finance.BusinessPrecisionContext.Choice(13,"HALF_UP")));
        try(explicitSourceChoice) {
            groups.create(new AssetOpeningGroupContracts.Create(id,source,voucher,asOf,List.of(costEntry,creditEntry),List.of(new AssetOpeningGroupContracts.Member("FIXED_ASSET",draft.id(),3,6,draft.version())),"复用既有真实组接续夹具，不新记GL"));
        }
        return id;
    }
    private UUID style(String category) {UUID id=UUID.randomUUID();db.update("INSERT INTO payment_styles(id,code,name,category,status) VALUES(?,?,?,?,'使用')",id,"SUMMARY-STYLE-"+id,"摘要夹具科目-"+id,category);return id;}
    private Set<String> seedAssetGroups(UUID actual,int count) {
        db.update("""
                INSERT INTO finance_asset_opening_groups(id,actor_id,source_import_id,source_voucher_id,as_of,fingerprint,status,source_entry_snapshot,member_snapshot,reason,created_at)
                SELECT gen_random_uuid(),actor_id,source_import_id,source_voucher_id,as_of,encode(digest(?||n::text,'sha256'),'hex'),'SUBMITTED',source_entry_snapshot,member_snapshot,?||n::text,
                    TIMESTAMPTZ '2026-01-01 00:00:00+00'+n*interval '1 second'
                FROM finance_asset_opening_groups CROSS JOIN generate_series(1,?) n WHERE id=?
                ""","summary-meta-"+tag,"summary-meta-"+tag,count,actual);
        return new LinkedHashSet<>(db.queryForList("SELECT id::text FROM finance_asset_opening_groups WHERE reason LIKE ? ORDER BY created_at DESC,id DESC",String.class,"summary-meta-"+tag+"%"));
    }
    private List<JsonNode> readAll(String route,String scope,String bearer,Set<String> expected,String table) throws Exception {
        List<String> ordered=expected.isEmpty()?List.of():db.queryForList("SELECT id::text FROM "+table+" WHERE id IN ("+String.join(",",Collections.nCopies(expected.size(),"?"))+") ORDER BY created_at DESC,id DESC",String.class,expected.stream().map(UUID::fromString).toArray());
        var byId=new HashMap<String,Map<String,Object>>();
        if(!expected.isEmpty()){
            for(var row:db.queryForList("SELECT id::text,status,row_version,actor_id"+(table.equals("finance_asset_opening_groups")?",as_of::text,source_voucher_id,reason":",kind,source_name,source_system,submitted_by")+" FROM "+table+" WHERE id IN ("+String.join(",",Collections.nCopies(expected.size(),"?"))+")",expected.stream().map(UUID::fromString).toArray())){
            byId.put(row.get("id").toString(),row);
        }
        
        }
        
        var ids=new LinkedHashSet<String>();var rows=new ArrayList<JsonNode>();String revision=null,data=null,authority=null;
        int pages=Math.max(1,(expected.size()+999)/1000);
        for(int page=1;page<=pages;page++) {
            JsonNode value=request(route+"?scope="+scope+"&page="+page+"&size=1000"+(revision==null?"":"&readSnapshotRevision="+revision),bearer,200);
            if(page==1){revision=value.path("readSnapshotRevision").asText();data=value.path("readDataVersion").asText();authority=value.path("readScopeVersion").asText();}
            assertThat(value.path("total").asInt()).isEqualTo(expected.size());assertThat(value.path("totalPages").asInt()).isEqualTo((expected.size()+999)/1000);assertThat(value.path("scope").asText()).isEqualTo(scope);
            assertThat(value.path("readSnapshotRevision").asText()).hasSize(64).isEqualTo(revision);assertThat(value.path("readDataVersion").asText()).hasSize(64).isEqualTo(data);assertThat(value.path("readScopeVersion").asText()).isEqualTo(authority);
            assertThat(value.toString()).doesNotContain("storage_key","storageKey","storageProvider","preview","source_entry_snapshot","member_snapshot","reviewed_input");
            for(JsonNode row:value.path("items")) {
                String id=row.path("id").asText();assertThat(ids.add(id)).isTrue();assertThat(expected).contains(id);rows.add(row);
                var original=Objects.requireNonNull(byId.get(id));assertThat(row.path("status").asText()).isEqualTo(original.get("status"));
                assertThat(row.path("version").asLong()).isEqualTo(((Number)original.get("row_version")).longValue());
                if(table.equals("finance_asset_opening_groups")) {
                    assertThat(row.path("as_of").asText()).isEqualTo(original.get("as_of"));
                    assertThat(row.path("source_voucher_id").asText()).isEqualTo(Objects.toString(original.get("source_voucher_id"),""));
                    assertThat(row.path("reason").asText()).isEqualTo(original.get("reason"));
                } else {
                    assertThat(row.path("actorId").asText()).isEqualTo(original.get("actor_id").toString());
                    assertThat(row.path("kind").asText()).isEqualTo(original.get("kind"));assertThat(row.path("sourceName").asText()).isEqualTo(original.get("source_name"));
                    assertThat(row.path("sourceSystem").asText()).isEqualTo(original.get("source_system"));
                    if(original.get("submitted_by")==null){
                        assertThat(row.get("submittedBy").isNull()).isTrue();
                    }
                    
                    else {
                        assertThat(row.path("submittedBy").asText()).isEqualTo(original.get("submitted_by").toString());
                    }
                    
                }
            }
        }
        assertThat(ids).containsExactlyElementsOf(ordered);assertThat(ids).containsExactlyInAnyOrderElementsOf(expected);if(expected.size()>=1001){
            assertThat(rows.getLast().path("id").asText()).isEqualTo(ordered.getLast());
        }
        return rows;
    }
    private Map<String,String> fingerprints() {
        var result=new TreeMap<String,String>();for(String table:List.of("finance_accounting_import_batches","finance_accounting_review_operations","finance_asset_opening_groups","finance_asset_opening_members","finance_asset_opening_entry_claims","finance_template_sources","fixed_assets","gl_entries","gl_vouchers")){
            result.put(table,db.queryForObject("SELECT md5(coalesce(jsonb_agg(to_jsonb(x) ORDER BY to_jsonb(x)::text),'[]'::jsonb)::text) FROM "+table+" x",String.class));
        }
        return result;
    }
    private String login(UUID id) throws Exception {String password="SummaryRead-"+tag+"-1!",account=db.queryForObject("SELECT login_account FROM users WHERE id=?",String.class,id);db.update("UPDATE users SET password_hash=?,must_change_password=false WHERE id=?",passwords.encode(password),id);return request("POST","/api/auth/login",json.writeValueAsBytes(Map.of("loginAccount",account,"password",password)),null,200).path("accessToken").asText();}
    private JsonNode request(String path,String bearer,int status) throws Exception{return request("GET",path,null,bearer,status);}
    private JsonNode request(String method,String path,byte[] body,String bearer,int status) throws Exception {
        var builder=HttpRequest.newBuilder(URI.create("http://127.0.0.1:"+port+path)).timeout(Duration.ofSeconds(15));if(bearer!=null){
            builder.header("Authorization","Bearer "+bearer);
        }
        if(body!=null){
            builder.header("Content-Type","application/json");
        }
        builder.method(method,body==null?HttpRequest.BodyPublishers.noBody():HttpRequest.BodyPublishers.ofByteArray(body));var response=http.send(builder.build(),HttpResponse.BodyHandlers.ofByteArray());assertThat(response.statusCode()).as("%s %s",method,path.replaceAll("readSnapshotRevision=[^&]+","readSnapshotRevision=<opaque>")) .isEqualTo(status);JsonNode value=json.readTree(response.body());if(status==200&&path.contains("/summaries")){
            assertThat(response.headers().firstValue("X-Uten-Read-Scope-Version")).contains(value.path("readScopeVersion").asText());
        }
        return value;
    }
}
