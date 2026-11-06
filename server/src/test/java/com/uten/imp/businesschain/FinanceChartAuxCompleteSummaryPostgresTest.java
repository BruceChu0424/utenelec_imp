package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.finance.FinanceOperationJournal;
import com.uten.imp.features.finance.gl.FinanceChartContracts;
import com.uten.imp.features.finance.gl.FinanceChartService;
import com.uten.imp.features.finance.gl.FinanceTemplateContract;
import com.uten.imp.features.finance.statement.FinanceAuxiliaryImportService;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.io.ByteArrayOutputStream;
import java.net.URI;
import java.net.http.*;
import java.time.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;

import static org.assertj.core.api.Assertions.*;

/** Current SQL/security/JWT/HTTP, literal1001 tails and read-only business facts.
 * Bulk roots are synthetic metadata fixtures inserted with every table guard enabled;
 * they do not claim1001 real workbook imports. Terminal states use real command producers.
 */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.RANDOM_PORT,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.workshop-material.auto-close.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.policy-intelligence.enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@FinanceScopedChain
class FinanceChartAuxCompleteSummaryPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry r){FinanceScopedChainDatabase.register(r,FinanceChartAuxCompleteSummaryPostgresTest.class);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ObjectMapper json;
    @Autowired PasswordEncoder passwords;
    @Autowired FinanceChartService chart;
    @Autowired FinanceAuxiliaryImportService auxiliary;
    @LocalServerPort int port;
    private static final AtomicInteger CODES=new AtomicInteger(860_000_000);
    private final HttpClient http=HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(15)).build();
    private FullChainEndToEndTest fixture;
    private FullChainEndToEndTest.World world;
    private UUID actor,other,denied;
    private String token,otherToken,deniedToken,tag;
    private static final String EXACT="9007199254740993.123456789012345678901234";
    private static final String CHART="/api/finance/chart/imports/summaries";
    private static final String AUX="/api/finance/auxiliary-imports/summaries";

    @BeforeEach void setup() throws Exception {
        tag=UUID.randomUUID().toString().substring(0,8);
        fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        world=fixture.seedWorld("chart-aux-summary-"+tag);
        actor=fixture.createUserWithPerms(world,"summary-owner-"+tag,"finance_report:view","finance:view:all","payment_style:edit");
        other=fixture.createUserWithPerms(world,"summary-other-"+tag,"finance_report:view","finance:view:all","payment_style:edit");
        denied=fixture.createUserWithPerms(world,"summary-no-company-"+tag,"finance_report:view");
        token=login(actor);otherToken=login(other);deniedToken=login(denied);
        fixture.loginAs(actor);
    }
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void chart1001ActiveTailHistoryBothTerminalKindsOwnActorAndReadOnlyFactsCrossRealHttp() throws Exception {
        Set<String> active=seedChart(actor,1001,"own-"+tag),foreign=seedChart(other,2,"other-"+tag);
        var applied=chart.preview("real-applied-"+tag+".xlsx",chartFile());
        assertThat(applied.issues()).isEmpty();
        assertThat(chart.apply(new FinanceChartContracts.Apply(applied.importId())).status()).isEqualTo("APPLIED");
        var cancelled=chart.preview("real-cancelled-"+tag+".xlsx",chartFile());
        assertThat(cancelled.issues()).isEmpty();
        JsonNode body=json.valueToTree(new FinanceChartContracts.Apply(cancelled.importId()));
        assertThat(chart.cancelImportApply(cancelled.importId(),new FinanceOperationJournal.Cancellation(
                cancelled.importId(),actor,"CHART_IMPORT_APPLY","POST","/finance/chart/import-apply",body)))
                .containsEntry("outcome","CANCELLED_UNWRITTEN");
        Set<String> history=Set.of(applied.importId().toString(),cancelled.importId().toString());
        var before=fingerprints();
        readAll(CHART,"active",token,active,"finance_chart_imports");
        readAll(CHART,"history",token,history,"finance_chart_imports");
        var all=new HashSet<>(active);all.addAll(history);
        readAll(CHART,"all",token,all,"finance_chart_imports");
        readAll(CHART,"all",otherToken,foreign,"finance_chart_imports");
        assertThat(request(CHART+"?scope=active&page=1&size=1000",deniedToken,403).path("code").asText()).isEqualTo("FORBIDDEN");
        assertThat(fingerprints()).isEqualTo(before);
        // A committed real cancellation between batches changes data without
        // a guessed count/old token; the old page2 is rejected, not published.
        JsonNode first=request(CHART+"?scope=active&page=1&size=1000",token,200);
        UUID selected=UUID.fromString(active.iterator().next());
        chart.cancelImportApply(selected,new FinanceOperationJournal.Cancellation(selected,actor,
                "CHART_IMPORT_APPLY","POST","/finance/chart/import-apply",json.valueToTree(new FinanceChartContracts.Apply(selected))));
        var afterWrite=fingerprints();
        assertThat(request(CHART+"?scope=active&page=2&size=1000&readSnapshotRevision="+first.path("readSnapshotRevision").asText(),token,409).path("code").asText()).isEqualTo("SNAPSHOT_CHANGED");
        assertThat(fingerprints()).isEqualTo(afterWrite);
    }

    @Test void auxiliary1001TailAllRetainsBothKindsLiteralSourceAndAppliedHistoryWithoutReadWrites() throws Exception {
        Set<String> active=seedAux(actor,1001,"000-own-"+tag),foreign=seedAux(other,2,"000-other-"+tag);
        UUID chartSource=UUID.randomUUID();
        db.update("INSERT INTO finance_chart_imports(id,actor_id,source_name,sha256,storage_provider,storage_key,storage_size,preview) VALUES(?,?,'summary-real-chart.xlsx',?,'TEST',?,1,'{}')",chartSource,actor,"c".repeat(64),"summary-real-chart-"+tag);
        db.update("INSERT INTO finance_chart_codes(code,name,currency_name,currency_id,sort_order,source_row,source_import_id,updated_by) VALUES('112201','匿名原科目','',?,1,1,?,?) ON CONFLICT(code) DO UPDATE SET currency_id=EXCLUDED.currency_id,currency_name='',row_version=finance_chart_codes.row_version+1",world.currencyId(),chartSource,actor);
        var real=auxiliary.preview(true,"000-real-applied-"+tag,world.currencyId(),LocalDate.of(2026,9,1),LocalDate.of(2026,9,30),"real-applied.xlsx",auxiliaryFile());
        assertThat(real.issues()).isEmpty();
        assertThat(auxiliary.applyDirectory(real.importId()).status()).isEqualTo("DIRECTORY_DRAFTS_APPLIED");
        Set<String> history=Set.of(real.importId().toString());
        var before=fingerprints();
        readAll(AUX,"active",token,active,"finance_statement_source_reviews");
        readAll(AUX,"history",token,history,"finance_statement_source_reviews");
        var all=new HashSet<>(active);all.addAll(history);
        var rows=readAll(AUX,"all",token,all,"finance_statement_source_reviews");
        assertThat(rows.stream().map(row->row.path("kind").asText()).collect(java.util.stream.Collectors.toSet()))
                .containsExactlyInAnyOrder("AUXILIARY_RECEIVABLE","AUXILIARY_PAYABLE");
        assertThat(rows.stream().map(row->row.path("sourceSystem").asText())).allMatch(source->source.startsWith("000-"));
        readAll(AUX,"all",otherToken,foreign,"finance_statement_source_reviews");
        assertThat(request(AUX+"?scope=all&page=1&size=1000",deniedToken,403).path("code").asText()).isEqualTo("FORBIDDEN");
        assertThat(fingerprints()).isEqualTo(before);
        JsonNode first=request(AUX+"?scope=active&page=1&size=1000",token,200);
        // Actual immutable intake of a new original commits a domain marker.
        auxiliary.preview(true,"000-new-original-"+tag,world.currencyId(),LocalDate.of(2026,9,1),LocalDate.of(2026,9,30),"real-new.xlsx",auxiliaryFile());
        var afterWrite=fingerprints();
        assertThat(request(AUX+"?scope=active&page=2&size=1000&readSnapshotRevision="+first.path("readSnapshotRevision").asText(),token,409).path("code").asText()).isEqualTo("SNAPSHOT_CHANGED");
        assertThat(fingerprints()).isEqualTo(afterWrite);
    }

    private Set<String> seedChart(UUID owner,int count,String prefix) {
        assertThat(db.update("""
                INSERT INTO finance_chart_imports(id,actor_id,source_name,sha256,storage_provider,storage_key,storage_size,preview,created_at)
                SELECT gen_random_uuid(),?,?||'-'||lpad(n::text,4,'0')||'.xlsx',encode(digest(?||n::text,'sha256'),'hex'),
                    'TEST',?||n::text,1,jsonb_build_object('opaqueOriginalExact',?::text),
                    TIMESTAMPTZ '2026-01-01 00:00:00+00'+n*interval '1 second'
                FROM generate_series(1,?) n
                """,owner,prefix,prefix,prefix,EXACT,count)).isEqualTo(count);
        return new LinkedHashSet<>(db.queryForList("SELECT id::text FROM finance_chart_imports WHERE actor_id=? ORDER BY created_at DESC,id DESC",String.class,owner));
    }
    private Set<String> seedAux(UUID owner,int count,String prefix) {
        assertThat(db.update("""
                INSERT INTO finance_statement_source_reviews(id,actor_id,kind,source_system,currency_id,date_from,date_to,
                    source_name,sha256,storage_provider,storage_key,storage_size,preview,created_at)
                SELECT gen_random_uuid(),?,CASE WHEN n%2=0 THEN 'AUXILIARY_PAYABLE' ELSE 'AUXILIARY_RECEIVABLE' END,
                    ?||'-'||lpad(n::text,4,'0'),?,DATE '2026-09-01',DATE '2026-09-30',?||'-'||lpad(n::text,4,'0')||'.xlsx',
                    encode(digest(?||n::text,'sha256'),'hex'),'TEST',?||n::text,1,jsonb_build_object('opaqueOriginalExact',?::text),
                    TIMESTAMPTZ '2026-01-01 00:00:00+00'+n*interval '1 second'
                FROM generate_series(1,?) n
                """,owner,prefix,world.currencyId(),prefix,prefix,prefix,EXACT,count)).isEqualTo(count);
        return new LinkedHashSet<>(db.queryForList("SELECT id::text FROM finance_statement_source_reviews WHERE actor_id=? ORDER BY created_at DESC,id DESC",String.class,owner));
    }

    private List<JsonNode> readAll(String route,String selected,String bearer,Set<String> expected,String table) throws Exception {
        var ids=new LinkedHashSet<String>();var rows=new ArrayList<JsonNode>();
        String revision=null,data=null,authority=null;int pages=Math.max(1,(expected.size()+999)/1000);
        String placeholders=String.join(",",Collections.nCopies(expected.size(),"?"));
        Object[] keys=expected.stream().map(UUID::fromString).toArray();
        var originals=db.queryForList("SELECT id::text,source_name"+(table.equals("finance_statement_source_reviews")?",kind,source_system,date_from::text,date_to::text":"")
                +" FROM "+table+" WHERE id IN ("+placeholders+") ORDER BY created_at DESC,id DESC",keys);
        List<String> ordered=originals.stream().map(row->(String)row.get("id")).toList();
        var byId=new HashMap<String,Map<String,Object>>();originals.forEach(row->byId.put((String)row.get("id"),row));
        // The independently seeded IDs determine membership; source metadata
        // comes from retained originals, never inferred from rendered labels.
        for(int page=1;page<=pages;page++) {
            String url=route+"?scope="+selected+"&page="+page+"&size=1000"+(revision==null?"":"&readSnapshotRevision="+revision);
            JsonNode value=request(url,bearer,200);
            if(page==1){revision=value.path("readSnapshotRevision").asText();data=value.path("readDataVersion").asText();authority=value.path("readScopeVersion").asText();}
            assertThat(value.path("scope").asText()).isEqualTo(selected);assertThat(value.path("total").asInt()).isEqualTo(expected.size());
            assertThat(value.path("totalPages").asInt()).isEqualTo((expected.size()+999)/1000);
            assertThat(value.path("page").asInt()).isEqualTo(page);assertThat(value.path("size").asInt()).isEqualTo(1000);
            assertThat(value.path("readSnapshotRevision").asText()).hasSize(64).isEqualTo(revision);
            assertThat(value.path("readDataVersion").asText()).hasSize(64).isEqualTo(data);
            assertThat(value.path("readScopeVersion").asText()).isNotBlank().isEqualTo(authority);
            assertThat(value.toString()).doesNotContain("opaqueOriginalExact",EXACT,"storageKey","storageProvider","preview","requestBody");
            for(JsonNode row:value.path("items")) {
                String id=row.path("importId").asText();assertThat(ids.add(id)).isTrue();assertThat(expected).contains(id);rows.add(row);
                var original=Objects.requireNonNull(byId.get(id));
                assertThat(row.path("sourceName").asText()).isEqualTo(original.get("source_name"));
                if(table.equals("finance_statement_source_reviews")) {
                    assertThat(row.path("kind").asText()).isEqualTo(original.get("kind"));assertThat(row.path("sourceSystem").asText()).isEqualTo(original.get("source_system"));
                    assertThat(row.path("dateFrom").asText()).isEqualTo(original.get("date_from"));assertThat(row.path("dateTo").asText()).isEqualTo(original.get("date_to"));
                }
            }
        }
        assertThat(ids).containsExactlyElementsOf(ordered);assertThat(ids).containsExactlyInAnyOrderElementsOf(expected);
        if(expected.size()==1001)assertThat(rows.getLast().path("importId").asText()).isEqualTo(ordered.getLast());
        return rows;
    }
    private Map<String,String> fingerprints() {
        var result=new TreeMap<String,String>();
        for(String table:List.of("finance_chart_imports","finance_statement_source_reviews","finance_chart_codes","finance_chart_manual_operations","finance_auxiliary_items","finance_account_auxiliary_bindings","gl_entries","audit_log"))
            result.put(table,db.queryForObject("SELECT md5(coalesce(jsonb_agg(to_jsonb(source) ORDER BY to_jsonb(source)::text),'[]'::jsonb)::text) FROM "+table+" source"
                    +(table.equals("audit_log")?" WHERE target_type IN ('finance_chart_imports','finance_statement_source_reviews','finance_chart_codes','finance_chart_manual_operations','finance_auxiliary_items','finance_account_auxiliary_bindings','gl_entries')":""),String.class));
        return result;
    }
    private String login(UUID user) throws Exception {
        String password="SummaryRead-"+tag+"-1!",account=db.queryForObject("SELECT login_account FROM users WHERE id=?",String.class,user);
        db.update("UPDATE users SET password_hash=?,must_change_password=false WHERE id=?",passwords.encode(password),user);
        JsonNode response=request("POST","/api/auth/login",json.writeValueAsBytes(Map.of("loginAccount",account,"password",password)),null,200);
        String result=response.path("accessToken").asText();assertThat(result).isNotBlank();return result;
    }
    private JsonNode request(String path,String bearer,int expected) throws Exception {return request("GET",path,null,bearer,expected);}
    private JsonNode request(String method,String path,byte[] payload,String bearer,int expected) throws Exception {
        var builder=HttpRequest.newBuilder(URI.create("http://127.0.0.1:"+port+path)).timeout(Duration.ofSeconds(15));
        if(bearer!=null){
            builder.header("Authorization","Bearer "+bearer);
        }
        if(payload!=null){
            builder.header("Content-Type","application/json");
        }

        builder.method(method,payload==null?HttpRequest.BodyPublishers.noBody():HttpRequest.BodyPublishers.ofByteArray(payload));
        var response=http.send(builder.build(),HttpResponse.BodyHandlers.ofByteArray());
        assertThat(response.statusCode()).as("%s %s",method,path.replaceAll("readSnapshotRevision=[^&]+","readSnapshotRevision=<opaque>")) .isEqualTo(expected);
        JsonNode body=json.readTree(response.body());
        if(expected==200&&path.contains("/summaries")){
            assertThat(response.headers().firstValue("X-Uten-Read-Scope-Version")).contains(body.path("readScopeVersion").asText());
        }

        return body;
    }
    private byte[] chartFile() throws Exception {
        try(var book=new XSSFWorkbook();var output=new ByteArrayOutputStream()) {
            var sheet=book.createSheet("匿名科目");var header=sheet.createRow(0);
            header.createCell(0).setCellValue("科目编码");header.createCell(1).setCellValue("科目名称");header.createCell(2).setCellValue("外币名称");
            var row=sheet.createRow(1);String code=Integer.toString(CODES.incrementAndGet());row.createCell(0).setCellValue(code);row.createCell(1).setCellValue("匿名原科目-"+code);
            String total=null;for(var group:FinanceTemplateContract.template("chartCodes").path("classifications"))if(group.path("id").asText().equals("ASSET"))total=group.path("totalLabel").asText();
            sheet.createRow(2).createCell(0).setCellValue(Objects.requireNonNull(total));book.write(output);return output.toByteArray();
        }
    }
    private byte[] auxiliaryFile() throws Exception {
        try(var book=new XSSFWorkbook();var output=new ByteArrayOutputStream()) {
            var sheet=book.createSheet("匿名明细");var header=sheet.createRow(2);
            for(int col=0;col<14;col++)header.createCell(col).setCellValue(FinanceTemplateContract.header("receivableAuxiliaryDetail",col));
            var row=sheet.createRow(3);row.createCell(0).setCellValue("112201");row.createCell(1).setCellValue("匿名原科目");row.createCell(2).setCellValue("00099");row.createCell(3).setCellValue("匿名原客户");row.createCell(4).setCellValue("借");
            for(int col=5;col<=11;col++)row.createCell(col).setCellValue(col==5||col==7||col==10?"10.123456789012345678901":"0");
            row.createCell(12).setCellValue("借");row.createCell(13).setCellValue("10.123456789012345678901");book.write(output);return output.toByteArray();
        }
    }
}
