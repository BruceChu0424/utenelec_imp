package com.uten.imp.features.master.goods.costing;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;
import java.nio.charset.StandardCharsets;
import java.time.LocalDate;
import java.util.*;
import java.util.function.Supplier;
import static com.uten.imp.features.master.goods.costing.GoodsCostContracts.*;
import static com.uten.imp.features.master.goods.costing.GoodsCostImportContracts.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class GoodsCostImportRemappingPostgresTest {
    static final PostgreSQLContainer<?> POSTGRES=new PostgreSQLContainer<>("postgres:16-alpine");
    static DriverManagerDataSource dataSource;static JdbcTemplate sql;
    final ObjectMapper json=new ObjectMapper().findAndRegisterModules();
    final UUID goods=UUID.randomUUID(),actor=UUID.randomUUID();
    final String path=UUID.randomUUID().toString();
    TransactionTemplate transaction;
    GoodsCostImportService service;
    GoodsCostSheetService sheets;
    Calculation calculation;
    @BeforeAll static void database() throws Exception {
        POSTGRES.start();dataSource=new DriverManagerDataSource(POSTGRES.getJdbcUrl(),POSTGRES.getUsername(),POSTGRES.getPassword());sql=new JdbcTemplate(dataSource);
        // Exact migrated column/default/key shapes; this remains a query/transaction projection,
        // without claiming to exercise unrelated goods lifecycle checks or business foreign keys.
        com.uten.imp.support.MigratedProjectionSchema.createCurrentTables(sql, "goods");
        sql.execute("""
                CREATE VIEW v_sales_quote_template_storage_references AS SELECT NULL::text storage_provider,NULL::text storage_key,NULL::text storage_version WHERE false;
                CREATE FUNCTION fn_audit_track_table(text,text,text,boolean) RETURNS void LANGUAGE plpgsql AS $$ BEGIN RETURN; END $$;
                CREATE FUNCTION business_data_reset() RETURNS void LANGUAGE plpgsql AS $$ BEGIN PERFORM * FROM (VALUES ('stock_movements', 'CLEAR')) rows; END $$;
                """);
        try(var stream=GoodsCostImportRemappingPostgresTest.class.getResourceAsStream("/db/migration/V755__goods_cost_import_evidence.sql")) {
            sql.execute(new String(Objects.requireNonNull(stream).readAllBytes(),StandardCharsets.UTF_8));
        }
    }
    @AfterAll static void stop(){POSTGRES.stop();}
    @AfterEach void clearSecurity(){SecurityContextHolder.clearContext();}
    @BeforeEach void setup() {
        sql.execute("TRUNCATE goods_cost_import_mappings,goods_cost_imports,goods CASCADE");sql.update("INSERT INTO goods(id) VALUES(?)",goods);
        var principal=new AuthUser(actor,actor,"cost-import-test",Set.of("goods:view","goods:cost:view","goods:cost:edit"),false,true,false);
        SecurityContextHolder.getContext().setAuthentication(UsernamePasswordAuthenticationToken.authenticated(principal,null,principal.getAuthorities()));
        var current=mock(SecurityContextCurrentUser.class);when(current.id()).thenReturn(Optional.of(actor));
        var references=mock(MasterReferenceValidationPort.class);
        sheets=mock(GoodsCostSheetService.class);calculation=mock(Calculation.class);CostLine line=mock(CostLine.class);
        when(line.path()).thenReturn(path);when(line.included()).thenReturn(true);when(line.unitName()).thenReturn("个");
        when(calculation.lines()).thenReturn(List.of(line));when(sheets.preview(any())).thenReturn(calculation);
        service=new GoodsCostImportService(new NamedParameterJdbcTemplate(dataSource),json,mock(ImmutableDocumentStore.class),current,references,
                new CostImportEvidenceGuard(sql,references),sheets,mock(TxSessionVars.class));
        transaction=new TransactionTemplate(new DataSourceTransactionManager(dataSource));
        transaction.setIsolationLevel(org.springframework.transaction.TransactionDefinition.ISOLATION_REPEATABLE_READ);
    }
    @Test void feeToSkipAndFeeToMaterialRemoveOnlyThePreviousImportFee() throws Exception {
        UUID file=file("first.xlsx");DraftInput input=input(List.of(),List.of(manualFee()));
        Applied first=apply(file,input,mapping("FEE"));assertThat(first.input().fees()).hasSize(2);
        Applied skipped=apply(file,first.input(),mapping("SKIP"));assertThat(skipped.input().fees()).containsExactly(manualFee());
        Applied material=apply(file,first.input(),mapping("MATERIAL"));
        assertThat(material.input().fees()).containsExactly(manualFee());
        assertThat(material.input().lineOverrides()).hasSize(1).first().extracting(LineOverride::unitPrice).isEqualTo("3");
        UUID receipt=UUID.fromString(material.input().extraFields().get("importMappingId"));
        assertThat(sql.queryForObject("SELECT base_input->'fees' FROM goods_cost_import_mappings WHERE id=?",String.class,receipt)).doesNotContain("IMPORT_REVIEWED");
    }
    @Test void materialToSkipRestoresPreexistingManualPriceAndKeepsUnrelatedQuantityEdit() throws Exception {
        UUID file=file("material.xlsx");LineOverride original=override("2","9","原手工价");
        Applied first=apply(file,input(List.of(original),List.of(manualFee())),mapping("MATERIAL"));
        LineOverride imported=first.input().lineOverrides().getFirst();
        LineOverride edited=new LineOverride(imported.path(),"7",imported.route(),imported.unitPrice(),imported.priceUnitRate(),
                imported.priceExchangeRateToLocal(),imported.taxRate(),imported.taxMode(),imported.priceSourceItemId(),imported.priceSourceType(),imported.reason(),imported.priceSourceVersion());
        DraftInput current=withRows(first.input(),List.of(edited),first.input().fees());
        Applied restored=apply(file,current,mapping("SKIP"));
        assertThat(restored.input().lineOverrides()).hasSize(1);
        assertThat(restored.input().lineOverrides().getFirst().unitPrice()).isEqualTo("9");
        assertThat(restored.input().lineOverrides().getFirst().adoptedQty()).isEqualTo("7");
        assertThat(restored.input().lineOverrides().getFirst().reason()).isEqualTo("原手工价");
    }
    @Test void repeatedApplyAndChangingFileDoNotAccumulateImportedFees() throws Exception {
        UUID a=file("a.xlsx"),b=file("b.xlsx");Applied first=apply(a,input(List.of(),List.of(manualFee())),mapping("FEE"));
        Applied repeated=apply(a,first.input(),mapping("FEE"));assertThat(repeated.input().fees()).hasSize(2);
        assertThat(repeated.input().fees()).isEqualTo(first.input().fees());
        Applied changed=apply(b,repeated.input(),mapping("FEE"));assertThat(changed.input().fees()).hasSize(2);
        assertThat(changed.input().fees().stream().filter(f->"IMPORT_REVIEWED".equals(f.source())).findFirst().orElseThrow().reason()).startsWith("b.xlsx");
        assertThat(changed.input().extraFields().get("importId")).isEqualTo(b.toString());
    }
    @Test void changedOwnedPriceConflictsWithoutRemovingManualEditsOrInsertingAReceipt() throws Exception {
        UUID file=file("protected.xlsx");Applied first=apply(file,input(List.of(),List.of()),mapping("MATERIAL"));
        LineOverride value=first.input().lineOverrides().getFirst();
        LineOverride edited=new LineOverride(value.path(),value.adoptedQty(),value.route(),"4",value.priceUnitRate(),value.priceExchangeRateToLocal(),
                value.taxRate(),value.taxMode(),value.priceSourceItemId(),value.priceSourceType(),value.reason(),value.priceSourceVersion());
        assertThatThrownBy(()->apply(file,withRows(first.input(),List.of(edited),List.of()),mapping("SKIP"))).hasMessageContaining("手工修改");
        assertThat(sql.queryForObject("SELECT count(*) FROM goods_cost_import_mappings",Integer.class)).isEqualTo(1);
        assertThat(first.input().lineOverrides().getFirst().unitPrice()).isEqualTo("3");
    }
    @Test void oldReceiptCustomerScopeIsRecheckedBeforeRestoringItsValues() throws Exception {
        UUID file=file("scope.xlsx"),privateClient=UUID.randomUUID();DraftInput source=input(List.of(override(null,"99","客户原价")),List.of());
        source=new DraftInput(source.goodsId(),privateClient,source.name(),source.batchQty(),source.currencyId(),source.exchangeRateToLocal(),source.effectiveDate(),
                source.usageStrategy(),source.priceStrategy(),source.templateId(),source.lineOverrides(),source.fees(),source.priceColumns(),source.priceCells(),source.extraFields(),source.notes());
        Applied first=apply(file,source,mapping("MATERIAL"));
        DraftInput now=new DraftInput(first.input().goodsId(),null,first.input().name(),first.input().batchQty(),null,"1",first.input().effectiveDate(),
                first.input().usageStrategy(),first.input().priceStrategy(),null,first.input().lineOverrides(),first.input().fees(),List.of(),List.of(),first.input().extraFields(),null);
        doAnswer(call->{DraftInput in=call.getArgument(0);if(privateClient.equals(in.clientId()))throw new ApiException(ErrorCode.FORBIDDEN,"历史客户范围已回收");return null;})
                .when(sheets).requireInputScope(any());
        assertThatThrownBy(()->apply(file,now,mapping("SKIP"))).hasMessageContaining("历史客户范围已回收");
        assertThat(sql.queryForObject("SELECT count(*) FROM goods_cost_import_mappings",Integer.class)).isEqualTo(1);
    }
    @Test void failureAfterReceiptInsertRollsBackTheEntireApply() throws Exception {
        UUID file=file("rollback.xlsx");when(sheets.preview(any())).thenReturn(calculation).thenThrow(new ApiException(ErrorCode.VALIDATION_FAILED,"计算失败"));
        assertThatThrownBy(()->apply(file,input(List.of(),List.of()),mapping("FEE"))).hasMessageContaining("计算失败");
        assertThat(sql.queryForObject("SELECT count(*) FROM goods_cost_import_mappings",Integer.class)).isZero();
    }
    private Applied apply(UUID file,DraftInput input,Mapping mapping){return tx(()->service.apply(new Apply(file,"block",input,List.of(mapping))));}
    private <T> T tx(Supplier<T> work){return transaction.execute(status->work.get());}
    private UUID file(String name)throws Exception {
        UUID id=UUID.randomUUID();String hash=ImmutableDocumentStore.digest(name.getBytes(StandardCharsets.UTF_8));
        Preview preview=new Preview(id,name,hash,List.of(new Block("block","产品","Sheet1",
                List.of(new ImportRow("Sheet1!2",2,"组件","M1","个","1","3","3",null,false,true)))),List.of());
        sql.update("INSERT INTO goods_cost_imports(id,goods_id,actor_id,source_name,storage_provider,storage_key,storage_size,storage_sha256,preview) VALUES(?,?,?,?,'local',?,10,?,?::jsonb)",
                id,goods,actor,name,id.toString(),hash,json.writeValueAsString(preview));return id;
    }
    private Mapping mapping(String kind){return new Mapping("Sheet1!2",kind,"MATERIAL".equals(kind)?path:null,null,null,null,null,"已明确跳过",true);}
    private FeeInput manualFee(){return new FeeInput("manual","手工费用","FIXED_BATCH","OTHER",null,"2",null,List.of(),"MANUAL","保留");}
    private LineOverride override(String quantity,String price,String reason){return new LineOverride(path,quantity,"BUY",price,"1","1",null,"AS_RECORDED",null,"MANUAL",reason);}
    private DraftInput input(List<LineOverride> overrides,List<FeeInput> fees){return new DraftInput(goods,null,"成本","10",null,"1",LocalDate.of(2026,9,29),
            "ACTUAL_FIRST","MANUAL",null,overrides,fees,List.of(),List.of(),Map.of("note","手工扩展"),null);}
    private DraftInput withRows(DraftInput in,List<LineOverride> overrides,List<FeeInput> fees){return new DraftInput(in.goodsId(),in.clientId(),in.name(),in.batchQty(),in.currencyId(),in.exchangeRateToLocal(),in.effectiveDate(),
            in.usageStrategy(),in.priceStrategy(),in.templateId(),overrides,fees,in.priceColumns(),in.priceCells(),in.extraFields(),in.notes());}
}
