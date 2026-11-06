package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.*;
import com.uten.imp.testsupport.FixtureDatabaseProperties;
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
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.net.*;
import java.net.http.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.time.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

/** Real loopback TCP + JWT/security + current SQL; transport1000 is never a product/material result cap. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.RANDOM_PORT,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.workshop-material.auto-close.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.policy-intelligence.enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=periodic-http-fixture-jwt-0123456789-test-only",
        "uten.crypto.pgp-master-key=periodic-http-fixture-pgp-0123456789-test-only",
        "uten.crypto.hmac-key=periodic-http-fixture-hmac-test-only",
        "uten.bootstrap.admin-login=periodic-http-bootstrap","uten.bootstrap.admin-password=PeriodicBootstrap-1!"})
class PeriodicCompleteSummaryHttpPostgresTest {
    private static final PostgreSQLContainer PG=new PostgreSQLContainer("postgres:16-alpine");
    private static Path directory;
    @DynamicPropertySource static void database(DynamicPropertyRegistry props) throws Exception {
        PG.start();directory=Files.createTempDirectory("uten-periodic-complete-http-");
        FixtureDatabaseProperties.bindSameRole(props,PG::getJdbcUrl,PG::getUsername,PG::getPassword);
        props.add("uten.storage.local-dir",()->directory.toString());
    }
    @LocalServerPort int port;
    @Autowired ObjectMapper json;
    @Autowired JdbcTemplate db;
    @Autowired PasswordEncoder passwords;
    @Autowired AutowireCapableBeanFactory beans;
    private final HttpClient http=HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(15)).build();
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test void thirtyFiveThousandProductsAndAllCatalogTailsCrossRealHttpWithBoundedBatchesAndStableOwner() throws Exception {
        var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        String tag=UUID.randomUUID().toString().substring(0,8);var world=fixture.seedWorld("summary-http-"+tag);
        fixture.loginAs(world.superAdminUserId());
        Object assignment=ReflectionTestUtils.invokeMethod(fixture,"productionAssignment","summary-http-"+tag);
        UUID workshop=ReflectionTestUtils.invokeMethod(assignment,"workshopId");UUID kilogram=UUID.randomUUID();
        db.update("INSERT INTO units(id,legacy_id,code,name,status) VALUES(?,? ,?,'千克','使用')",kilogram,900_000_000+new Random().nextInt(90_000_000),"SUMMARY-KG-"+tag);
        db.update("INSERT INTO unit_measurement_profiles(unit_id,measurement_dimension,mass_unit_code,provenance) VALUES(?,'MASS','KG','MANUAL_GOVERNANCE')",kilogram);
        db.update("""
                INSERT INTO goods(id,code,name,source_type,status,unit_id,price,code_sequence,owning_workshop_department_id,m_weight,m_weight_unit_id)
                SELECT gen_random_uuid(),?||lpad(n::text,5,'0'),'完整产品'||n,'自制','使用',?,100,
                       (SELECT COALESCE(max(code_sequence),0) FROM goods)+n,?,0.012,?
                FROM generate_series(1,35000) n
                ""","SUMMARY-P-"+tag+"-",world.unitId(),workshop,kilogram);
        db.update("""
                INSERT INTO goods(id,code,name,source_type,status,unit_id,price,code_sequence,issue_method,periodic_cost_basis)
                SELECT gen_random_uuid(),?||lpad(n::text,5,'0'),'完整颗粒'||n,'采购','使用',?,10,
                       (SELECT COALESCE(max(code_sequence),0) FROM goods)+n,'PERIODIC','OWN'
                FROM generate_series(1,1001) n
                ""","SUMMARY-M-"+tag+"-",kilogram);
        UUID reader=fixture.createUserWithPerms(world,"summary-http-reader-"+tag,"goods:view","goods:cost:view","workshop_material:view","workshop_material:setup",
                "finance_asset:view","finance_report:view","finance:view:all","finance_post:execute");
        String login=db.queryForObject("SELECT login_account FROM users WHERE id=?",String.class,reader);
        String password="SummaryRead-"+tag+"-1!";
        db.update("UPDATE users SET password_hash=?,must_change_password=false WHERE id=?",passwords.encode(password),reader);
        String token=body(request("POST","/api/auth/login",json.writeValueAsBytes(Map.of("loginAccount",login,"password",password)),null,200)).path("accessToken").asText();
        assertThat(token).isNotBlank();
        String base="/api/master/goods/periodic-bom/preparation/summaries?workshopId="+workshop+"&size=1000";
        long start=System.nanoTime(),firstElapsed=0,bytes=0;String revision=null,data=null,scope=null,asOf=null;int batches=0;var ids=new LinkedHashSet<String>();String tailId=null;
        for(int page=1;page<=35;page++) {
            // Fixed40ms per network round trip is recorded separately; no test timeout/threshold is enlarged.
            Thread.sleep(40);
            String url=base+"&page="+page+(revision==null?"":"&readSnapshotRevision="+revision+"&windowAsOf="+encode(asOf));
            HttpResponse<byte[]> response=request("GET",url,null,token,200);JsonNode value=body(response);bytes+=response.body().length;batches++;
            if(page==1) {firstElapsed=(System.nanoTime()-start)/1_000_000;revision=value.path("readSnapshotRevision").asText();data=value.path("readDataVersion").asText();scope=value.path("readScopeVersion").asText();asOf=value.path("windowAsOf").asText();}
            assertThat(value.path("total").asLong()).isEqualTo(35000);assertThat(value.path("totalPages").asInt()).isEqualTo(35);
            assertThat(value.path("page").asInt()).isEqualTo(page);assertThat(value.path("size").asInt()).isEqualTo(1000);
            assertThat(value.path("readSnapshotRevision").asText()).isEqualTo(revision);assertThat(value.path("readDataVersion").asText()).isEqualTo(data);
            assertThat(value.path("windowAsOf").asText()).isEqualTo(asOf);assertThat(value.path("items").size()).isEqualTo(1000);
            assertThat(response.headers().firstValue("X-Uten-Read-Scope-Version")).contains(scope);
            for(JsonNode row:value.path("items")) {
                assertThat(row.has("rows")||row.has("materials")||row.has("options")).isFalse();
                assertThat(row.path("goodsWeightGramsExact").asText()).isEqualTo("12");
                tailId=row.path("productGoodsId").asText();assertThat(ids.add(tailId)).isTrue();
            }
        }
        long productsElapsed=(System.nanoTime()-start)/1_000_000;
        assertThat(ids).hasSize(35000);assertThat(batches).isEqualTo(35);
        String expectedTail=db.queryForObject("SELECT id::text FROM goods WHERE owning_workshop_department_id=? ORDER BY code DESC,id DESC LIMIT 1",String.class,workshop);
        assertThat(tailId).isEqualTo(expectedTail);
        JsonNode detail=body(request("GET","/api/master/goods/periodic-bom/preparation/products/"+tailId+"?workshopId="+workshop+"&size=1000&readSnapshotRevision="+revision+"&windowAsOf="+encode(asOf),null,token,200));
        assertThat(detail.path("rows").size()).isEqualTo(1);assertThat(detail.path("rows").get(0).path("productGoodsId").asText()).isEqualTo(tailId);
        assertThat(detail.path("materials").isEmpty()).isTrue();assertThat(detail.path("readSnapshotRevision").asText()).isEqualTo(revision);
        String catalog="/api/master/goods/periodic-bom/preparation/material-options?workshopId="+workshop+"&size=1000";
        var catalogIds=new HashSet<String>();String candidateRevision=null;long candidateTotal=0;int candidatePages=1;
        for(int page=1;page<=candidatePages;page++) {
            JsonNode value=body(request("GET",catalog+"&page="+page+(candidateRevision==null?"":"&readSnapshotRevision="+candidateRevision),null,token,200));
            if(page==1){candidateRevision=value.path("readSnapshotRevision").asText();candidateTotal=value.path("total").asLong();candidatePages=value.path("totalPages").asInt();}
            assertThat(value.path("readSnapshotRevision").asText()).isEqualTo(candidateRevision);
            for(JsonNode row:value.path("items"))assertThat(catalogIds.add(row.path("goodsId").asText())).isTrue();
        }
        assertThat(candidateTotal).isGreaterThanOrEqualTo(1001);assertThat(catalogIds).hasSize((int)candidateTotal);
        String materialTail=db.queryForObject("SELECT id::text FROM goods WHERE code=?",String.class,"SUMMARY-M-"+tag+"-01001");assertThat(catalogIds).contains(materialTail);
        for(String route:List.of("/api/finance/asset-opening-groups/summaries","/api/finance/accounting-imports/summaries",
                "/api/finance/chart/imports/summaries","/api/finance/auxiliary-imports/summaries")) {
            var response=request("GET",route+"?scope=active&page=1&size=100",null,token,200);JsonNode value=body(response);
            assertThat(value.path("scope").asText()).isEqualTo("active");assertThat(value.path("page").asInt()).isEqualTo(1);
            assertThat(value.path("size").asInt()).isEqualTo(100);assertThat(value.has("total")&&value.has("totalPages")&&value.path("items").isArray()).isTrue();
            assertThat(value.path("readSnapshotRevision").asText()).hasSize(64);assertThat(value.path("readDataVersion").asText()).hasSize(64);
            assertThat(response.headers().firstValue("X-Uten-Read-Scope-Version")).contains(value.path("readScopeVersion").asText());
        }
        db.update("UPDATE goods SET name=name||'已改' WHERE id=?",UUID.fromString(tailId));
        assertThat(body(request("GET",base+"&page=2&readSnapshotRevision="+revision+"&windowAsOf="+encode(asOf),null,token,409)).path("code").asText()).isEqualTo("SNAPSHOT_CHANGED");
        db.update("DELETE FROM user_permission_overrides WHERE user_id=? AND permission_id=(SELECT id FROM permissions WHERE code='workshop_material:setup')",reader);
        request("GET",base,null,token,401);
        System.out.println("periodic-complete-real-http products=35000 batches="+batches+" bytes="+bytes+" injectedRttMs=40 firstMs="+firstElapsed+" productsMs="+productsElapsed+" scenarioMs="+(System.nanoTime()-start)/1_000_000+" candidates="+candidateTotal+" literalTail=true financeReadRoutes=4");
    }
    private static String encode(String text){return URLEncoder.encode(text,StandardCharsets.UTF_8);}
    private JsonNode body(HttpResponse<byte[]> response) throws Exception {return json.readTree(response.body());}
    private HttpResponse<byte[]> request(String method,String path,byte[] body,String token,int status) throws Exception {
        var request=HttpRequest.newBuilder(URI.create("http://127.0.0.1:"+port+path)).timeout(Duration.ofSeconds(15));
        if(token!=null)request.header("Authorization","Bearer "+token);
        if(body!=null)request.header("Content-Type","application/json");
        request.method(method,body==null?HttpRequest.BodyPublishers.noBody():HttpRequest.BodyPublishers.ofByteArray(body));
        HttpResponse<byte[]> response=http.send(request.build(),HttpResponse.BodyHandlers.ofByteArray());
        assertThat(response.statusCode()).as("%s %s",method,path.replaceAll("readSnapshotRevision=[^&]+","readSnapshotRevision=<opaque>")) .isEqualTo(status);
        return response;
    }
}
