package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.color.ColorService;
import com.uten.imp.features.master.color.dto.ColorQueryFilter;
import com.uten.imp.features.master.color.dto.ColorSaveRequest;
import com.uten.imp.features.master.history.MasterInlineEditService;
import com.uten.imp.features.master.history.MasterRecordHistoryService;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Forward migration plus native service, field-CAS and shared version recovery. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK, properties={
    "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
    "uten.reporting.materialized-view-refresh.enabled=false", "uten.production.readiness-reconcile.enabled=false",
    "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
    "uten.storage.malware-scan.provider=test-only"})
class ColorRemarkRuntimeEndToEndTest {
    private static final PostgreSQLContainer DB=new PostgreSQLContainer("postgres:16-alpine");
    private static final UUID OLD_COLOR=UUID.randomUUID();
    private static long oldVersion;
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        DB.start();
        com.uten.imp.testsupport.TestFlyway.configure().dataSource(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword())
                .locations("classpath:db/migration").target("899").load().migrate();
        var seed=new JdbcTemplate(new DriverManagerDataSource(DB.getJdbcUrl(),DB.getUsername(),DB.getPassword()));
        seed.update("INSERT INTO colors(id,code,name,status) VALUES(?,?,?,'使用')",OLD_COLOR,"OLD-901-"+OLD_COLOR,"pre-column original");
        seed.update("UPDATE colors SET name='pre-column changed' WHERE id=?",OLD_COLOR);
        oldVersion=seed.queryForObject("SELECT max(id) FROM master_record_versions WHERE source_table='colors' AND row_id=?",Long.class,OLD_COLOR);
        registry.add("spring.datasource.url",DB::getJdbcUrl);
        registry.add("spring.datasource.username",DB::getUsername);
        registry.add("spring.datasource.password",DB::getPassword);
        registry.add("uten.bootstrap.admin-login",()->FullChainEndToEndTest.SHARED_ADMIN_LOGIN);
        registry.add("uten.bootstrap.admin-password",()->FullChainEndToEndTest.SHARED_ADMIN_PASSWORD);
        registry.add("uten.jwt.secret",()->FullChainEndToEndTest.SHARED_JWT_SECRET);
        registry.add("uten.crypto.pgp-master-key",()->FullChainEndToEndTest.SHARED_PGP_KEY);
        registry.add("uten.crypto.hmac-key",()->FullChainEndToEndTest.SHARED_HMAC_KEY);
        registry.add("uten.storage.local-dir",()->System.getProperty("java.io.tmpdir")+"/uten-color-901-"+OLD_COLOR);
    }
    @Autowired ColorService colors;
    @Autowired MasterInlineEditService inline;
    @Autowired MasterRecordHistoryService history;
    @Autowired JdbcTemplate db;
    @Autowired ObjectMapper json;
    @BeforeEach void login() {
        UUID actor=db.queryForObject("SELECT id FROM users WHERE login_account=?",UUID.class,FullChainEndToEndTest.SHARED_ADMIN_LOGIN);
        UUID employee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,actor);
        var principal=new AuthUser(actor,employee,"color-remark-runtime",Set.of("color:view","color:create","color:edit","color:export"),false,true,false,false,null,UUID.randomUUID());
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(principal,"",principal.getAuthorities()));
    }
    @AfterEach void clear() {
        SecurityContextHolder.clearContext();RequestContextHolder.resetRequestAttributes();
    }
    @Test void nativeFormsFieldCasSearchAndExportUseTheSameRemarkWithoutErasingOmittedValues() throws Exception {
        String name="color remark "+UUID.randomUUID();
        ColorSaveRequest create=request(name,",\"remark\":\"  first note  \"");
        create.setCode(("C901-"+UUID.randomUUID()).toUpperCase(java.util.Locale.ROOT));
        route("/api/master/colors","POST");
        var created=colors.create(create);UUID id=created.getId();
        assertEquals("first note",created.getRemark());
        route("/api/master/colors/"+id,"PUT");
        colors.update(id,request(name,""));
        assertEquals("first note",colors.detail(id).getRemark());
        route("/api/master/inline-edit/colors/"+id,"PATCH");
        inline.patch("colors",id,Map.of("remark","first note"),Map.of("remark","second note"));
        assertEquals("second note",colors.detail(id).getRemark());
        ApiException stale=assertThrows(ApiException.class,()->inline.patch("colors",id,Map.of("remark","first note"),Map.of("remark","overwrite")));
        assertEquals(ErrorCode.CONFLICT,stale.getCode());
        assertEquals("second note",db.queryForObject("SELECT remark FROM colors WHERE id=?",String.class,id));
        var filter=new ColorQueryFilter(null,Set.of(),created.getCode(),null,null,"second note");
        assertEquals("second note",colors.list(filter,1,20).getItems().getFirst().getRemark());
        assertTrue(colors.dict().stream().anyMatch(item->item.getId().equals(id)&&"second note".equals(item.getRemark())));
        var exported=colors.export(filter,100);
        assertEquals(java.util.List.of("code","name","status","remark"),exported.columns().stream().map(column->column.key()).toList());
        assertEquals("second note",exported.rows().getFirst().get("remark"));
        assertTrue(colors.facets().getRemark().stream().anyMatch(bucket->"second note".equals(bucket.getValue())));
        route("/api/master/colors/"+id,"PUT");
        colors.update(id,request(name,",\"remark\":null"));
        assertNull(colors.detail(id).getRemark());
        colors.update(id,request(name,",\"remark\":\"new note\""));
        colors.update(id,request(name,",\"remark\":\"   \""));
        assertNull(colors.detail(id).getRemark());
    }
    @Test void aVersionRecordedBeforeTheColumnExistedRestoresWithoutErasingTheNewRemark() {
        assertEquals("902",db.queryForObject("SELECT version FROM flyway_schema_history WHERE success ORDER BY installed_rank DESC LIMIT 1",String.class));
        assertFalse(db.queryForObject("SELECT jsonb_exists(before_row, 'remark') FROM master_record_versions WHERE id=?",Boolean.class,oldVersion));
        db.update("UPDATE colors SET name='current name',remark='new column retained' WHERE id=?",OLD_COLOR);
        var selected=history.detail("colors",oldVersion);
        assertTrue(selected.canRestoreBefore(),selected.blockedReason());
        route("/api/master/record-history/"+oldVersion+"/restore","POST");
        history.restore("colors",oldVersion,selected.expectedHead(),true);
        assertEquals("pre-column original",db.queryForObject("SELECT name FROM colors WHERE id=?",String.class,OLD_COLOR));
        assertEquals("new column retained",db.queryForObject("SELECT remark FROM colors WHERE id=?",String.class,OLD_COLOR));
    }
    private ColorSaveRequest request(String name,String remark) throws Exception {
        return json.readValue("{\"name\":\""+name+"\",\"status\":\"使用\""+remark+"}",ColorSaveRequest.class);
    }
    private static void route(String path,String method) {
        RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(new MockHttpServletRequest(method,path)));
    }
}
