package com.uten.imp.features.master.goods.costing;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.client.ClientAccessPolicy;
import com.uten.imp.features.master.goods.GoodsCostMasker;
import com.uten.imp.features.master.lifecycle.MasterObjectAccess;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;
import java.nio.charset.StandardCharsets;
import java.time.LocalDate;
import java.util.*;
import java.util.function.Supplier;
import static com.uten.imp.features.master.goods.costing.GoodsCostContracts.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Actual V753 DDL and command/query SQL, isolated from business databases and other build outputs. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class GoodsCostSheetsPostgresTest {
    static final PostgreSQLContainer<?> POSTGRES=new PostgreSQLContainer<>("postgres:16-alpine");
    static DriverManagerDataSource dataSource;
    static JdbcTemplate sql;
    NamedParameterJdbcTemplate db;
    TransactionTemplate transaction;
    GoodsCostSheetService service;
    GoodsCostSourceReader sources;
    MasterReferenceValidationPort references;
    SecurityContextCurrentUser current;
    GoodsCostMasker masker;
    final UUID actor=UUID.randomUUID(),root=UUID.randomUUID(),material=UUID.randomUUID(),unit=UUID.randomUUID(),edge=UUID.randomUUID();
    @BeforeAll static void migrate() throws Exception {
        POSTGRES.start();dataSource=new DriverManagerDataSource(POSTGRES.getJdbcUrl(),POSTGRES.getUsername(),POSTGRES.getPassword());sql=new JdbcTemplate(dataSource);
        // Read column/default/key shapes from real migrations. This isolated source-query fixture
        // deliberately omits unrelated master-data lifecycle triggers and foreign keys.
        com.uten.imp.support.MigratedProjectionSchema.createCurrentTables(sql, "units", "colors", "currencies",
                "goods", "clients", "goods_bom_items", "purchase_orders", "purchase_order_items",
                "subcontract_orders", "subcontract_order_items", "permissions", "department_permissions",
                "user_permission_overrides");
        sql.execute("""
                CREATE VIEW v_goods_bom_item_usage AS SELECT id bom_item_id,NULL::numeric actual_qty,qty effective_qty,'NO_DATA'::text actual_status,
                    0::bigint sample_count,0::numeric exposure_output_qty,0::numeric net_qty,false system_learned FROM goods_bom_items;
                INSERT INTO permissions(code) VALUES('goods:cost:view');
                INSERT INTO department_permissions(department_id,permission_id) SELECT gen_random_uuid(),id FROM permissions;
                INSERT INTO user_permission_overrides(user_id,permission_id,effect,authority_source,source_actor_user_id)
                    SELECT gen_random_uuid(),id,'revoke','SUPER_ADMIN',NULL FROM permissions;
                CREATE FUNCTION fn_audit_track_table(text,text,text,boolean) RETURNS void LANGUAGE plpgsql AS $$ BEGIN RETURN; END $$;
                CREATE FUNCTION business_data_reset() RETURNS void LANGUAGE plpgsql AS $$
                BEGIN PERFORM * FROM (VALUES ('stock_movements', 'CLEAR')) records; END $$;
                """);
        try(var stream=GoodsCostSheetsPostgresTest.class.getResourceAsStream("/db/migration/V753__goods_cost_sheets.sql")) {
            assertThat(stream).isNotNull();sql.execute(new String(stream.readAllBytes(),StandardCharsets.UTF_8));
        }
    }
    @AfterAll static void stop(){POSTGRES.stop();}
    @BeforeEach void setup() {
        sql.execute("TRUNCATE goods_cost_commands,goods_cost_sheets,goods_cost_snapshots,goods_cost_templates,goods,clients,goods_bom_items,units,purchase_orders,purchase_order_items,subcontract_orders,subcontract_order_items CASCADE");
        sql.update("INSERT INTO units(id,name) VALUES(?,?)",unit,"个");
        sql.update("INSERT INTO goods(id,code,name,unit_id,source_type,version) VALUES(?,?,?,?,?,1),(?,?,?,?,?,1)",root,"P1","成品",unit,"自制",material,"M1","材料",unit,"采购");
        sql.update("INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty) VALUES(?,?,?,?)",edge,root,material,new java.math.BigDecimal("2"));
        db=new NamedParameterJdbcTemplate(dataSource);transaction=new TransactionTemplate(new DataSourceTransactionManager(dataSource));
        references=mock(MasterReferenceValidationPort.class);current=mock(SecurityContextCurrentUser.class);masker=mock(GoodsCostMasker.class);
        when(current.requireId()).thenReturn(actor);when(masker.canView()).thenReturn(true);permissions(Set.of("goods:view","goods:cost:view","goods:cost:edit","goods:cost:confirm","goods:cost:export"));
        var access=mock(MasterObjectAccess.class);when(access.readableLabelOwner(anyString())).thenReturn(owner->true);
        var clients=mock(ClientAccessPolicy.class);when(clients.canRead(any(UUID.class),nullable(UUID.class),any())).thenReturn(true);
        var json=new GoodsCostJson(new ObjectMapper().findAndRegisterModules());sources=new GoodsCostSourceReader(db,references,access);
        var imports=mock(CostImportEvidenceGuard.class);when(imports.validate(any(),any())).thenAnswer(call->call.getArgument(1));
        service=new GoodsCostSheetService(db,new GoodsCostCalculator(sources,references,json),json,masker,references,clients,current,mock(TxSessionVars.class),imports);
    }
    @Test void draftSaveIdempotencyCasAndConfirmedSnapshotAreIndependentOfMasterData() {
        SaveRequest create=new SaveRequest(null,"create-command-0001",input("0.00007"));
        Sheet first=tx(()->service.create(create));Sheet replay=tx(()->service.create(create));
        assertThat(replay.id()).isEqualTo(first.id());assertThat(sql.queryForObject("SELECT count(*) FROM goods_cost_sheets",Integer.class)).isEqualTo(1);
        assertThatThrownBy(()->tx(()->service.create(new SaveRequest(null,create.idempotencyKey(),input("99"))))).hasMessageContaining("请求号");
        Sheet saved=tx(()->service.save(first.id(),new SaveRequest(1L,"save-command-0001",input("0.00009"))));
        assertThat(saved.version()).isEqualTo(2);
        assertThatThrownBy(()->tx(()->service.save(first.id(),new SaveRequest(1L,"stale-command-0001",input("5"))))).hasMessageContaining("已被修改");
        Sheet confirmed=tx(()->service.confirm(first.id(),new Command(2,"confirm-command-0001")));
        Snapshot frozen=service.exportSnapshot(first.id(),confirmed.confirmedSnapshotId());
        assertThat(frozen.calculation().totals().knownTotal()).isEqualTo("0.0018");
        assertThat(sql.queryForObject("SELECT version FROM goods WHERE id=?",Long.class,root)).isEqualTo(1);
        assertThat(sql.queryForObject("SELECT qty FROM goods_bom_items WHERE id=?",java.math.BigDecimal.class,edge)).isEqualByComparingTo("2");
        assertThatThrownBy(()->tx(()->service.save(first.id(),new SaveRequest(3L,"bad-save-command",input("9"))))).hasMessageContaining("不可修改");
        assertThatThrownBy(()->sql.update("UPDATE goods_cost_snapshots SET payload='{}' WHERE id=?",frozen.id())).hasMessageContaining("immutable");
        assertThatThrownBy(()->sql.update("UPDATE goods_cost_sheets SET name='changed' WHERE id=?",first.id())).hasMessageContaining("immutable");
        Sheet copied=tx(()->service.copy(first.id(),new CopyCommand(3,"copy-command-0001","新的成本")));
        assertThat(copied.status()).isEqualTo("DRAFT");assertThat(copied.id()).isNotEqualTo(first.id());
    }
    @Test void approvedPriceIgnoresDraftAndPreservesPerLineUnitRate() {
        UUID approved=UUID.randomUUID(),draft=UUID.randomUUID(),approvedLine=UUID.randomUUID(),bag=UUID.randomUUID(),currency=UUID.randomUUID(),supplier=UUID.randomUUID();
        sql.update("INSERT INTO units(id,name) VALUES(?,?)",bag,"袋");
        sql.update("INSERT INTO currencies(id,name) VALUES(?,?)",currency,"人民币");
        sql.update("INSERT INTO purchase_orders(id,bill_no,bill_date,exchange_rate,tax_rate,status,supplier_id,currency_id) VALUES(?,?,?::date,1,13,1,?,?),(?,?,?::date,1,13,0,?,?)",
                approved,"PO-OK","2026-09-28",supplier,currency,draft,"PO-DRAFT","2026-09-29",supplier,currency);
        sql.update("INSERT INTO purchase_order_items(id,order_id,goods_id,unit_id,unit_rate,price,amount_original,qty) VALUES(?,?,?,?,25,400,400,1),(?,?,?,?,20,999,999,1)",
                approvedLine,approved,material,bag,UUID.randomUUID(),draft,material,bag);
        PriceEvidence result=sources.approved(sources.goods(material),false,LocalDate.of(2026,9,29),null);
        assertThat(result.sourceItemId()).isEqualTo(approvedLine);assertThat(result.unitRate()).isEqualTo("25");assertThat(result.originalUnitPrice()).isEqualTo("400");
        assertThat(result.approvalState()).isEqualTo("APPROVED");
        sql.update("UPDATE purchase_order_items SET amount_original=410,extra_columns='[{\"operation\":\"ADD\",\"value\":\"10\"}]'::jsonb WHERE id=?",approvedLine);
        PriceEvidence adjusted=sources.approved(sources.goods(material),false,LocalDate.of(2026,9,29),null);
        assertThat(adjusted.approvalState()).isEqualTo("APPROVED_WITH_COMPONENTS");
        assertThat(adjusted.originalUnitPrice()).isEqualTo("400");
        assertThat(adjusted.sourceVersion()).isNotEqualTo(result.sourceVersion());
        sql.update("UPDATE purchase_order_items SET unit_rate=20 WHERE id=?",approvedLine);
        assertThat(sources.approved(sources.goods(material),false,LocalDate.of(2026,9,29),null).unitRate()).isEqualTo("20");
        sql.update("UPDATE purchase_order_items SET unit_id=? WHERE id=?",unit,approvedLine);
        assertThat(sources.approved(sources.goods(material),false,LocalDate.of(2026,9,29),null)).isNull();
    }
    @Test void sourceChangesRequireExplicitResaveBeforeConfirmation() {
        Sheet first=tx(()->service.create(new SaveRequest(null,"create-stale-source",input("1"))));
        sql.update("UPDATE goods_bom_items SET qty=3,updated_at=now() WHERE id=?",edge);
        assertThatThrownBy(()->tx(()->service.confirm(first.id(),new Command(1,"confirm-stale-source")))).hasMessageContaining("来源或模板已变化");
    }
    @Test void exportRechecksCostAndEverySourceGoodsPermission() {
        Sheet sheet=tx(()->service.create(new SaveRequest(null,"create-access-test",input("1"))));
        Snapshot snapshot=tx(()->service.snapshot(sheet.id(),new Command(1,"snapshot-access-test")));
        permissions(Set.of("goods:view","goods:cost:view"));
        assertThatThrownBy(()->service.exportSnapshot(sheet.id(),snapshot.id())).isInstanceOf(ApiException.class).hasMessageContaining("权限");
        permissions(Set.of("goods:view","goods:cost:view","goods:cost:export"));
        doThrow(new ApiException(ErrorCode.FORBIDDEN,"物料范围已回收")).when(references).requireVisibleGoods(material);
        assertThatThrownBy(()->service.exportSnapshot(sheet.id(),snapshot.id())).hasMessageContaining("范围已回收");
    }
    @Test void permissionMigrationNeverPromotesLegacyViewersToEditorsConfirmersOrTemplateMaintainers() {
        assertThat(sql.queryForObject("SELECT count(*) FROM department_permissions",Integer.class)).isEqualTo(1);
        assertThat(sql.queryForObject("SELECT count(*) FROM user_permission_overrides WHERE effect='revoke'",Integer.class)).isEqualTo(1);
        assertThat(sql.queryForObject("SELECT count(*) FROM permissions WHERE code LIKE 'goods:cost:%'",Integer.class)).isEqualTo(5);
    }
    @Test void concurrentIdenticalCommandsReturnOneReceiptAndOneSheet() throws Exception {
        SaveRequest request=new SaveRequest(null,"concurrent-create-command",input("1"));
        try(var executor=java.util.concurrent.Executors.newFixedThreadPool(2)) {
            var start=new java.util.concurrent.CountDownLatch(1);
            var a=executor.submit(()->{start.await();return tx(()->service.create(request));});
            var b=executor.submit(()->{start.await();return tx(()->service.create(request));});
            start.countDown();
            Sheet first=a.get(30,java.util.concurrent.TimeUnit.SECONDS),second=b.get(30,java.util.concurrent.TimeUnit.SECONDS);
            assertThat(first.id()).isEqualTo(second.id());
            assertThat(sql.queryForObject("SELECT count(*) FROM goods_cost_sheets",Integer.class)).isEqualTo(1);
        }
    }
    @Test void customerProductTemplateWinsAndExplicitOverrideAndExclusionRemainStable() {
        permissions(Set.of("goods:view","goods:cost:view","goods:cost:edit","goods:cost:template"));
        UUID client=UUID.randomUUID();sql.update("INSERT INTO clients(id,name,owner_employee_id) VALUES(?,'测试客户',?)",client,actor);
        for(int level=0;level<3;level++) {
            String rate=List.of("8","10","12").get(level);
            TemplateInput template=new TemplateInput("费用规则"+level,level>0?root:null,level>1?client:null,
                    LocalDate.of(2026,1,1),null,null,null,
                    List.of(new FeeInput("manage","管理分摊","PERCENT","MANAGEMENT",null,rate,null,List.of("MATERIAL"),"MANUAL","已确认")),List.of(),null);
            int ordinal=level;tx(()->service.saveTemplate(null,new TemplateSave(null,"template-command-"+ordinal,template)));
        }
        DraftInput raw=input("1");
        DraftInput customer=new DraftInput(raw.goodsId(),client,raw.name(),raw.batchQty(),null,"1",raw.effectiveDate(),raw.usageStrategy(),raw.priceStrategy(),null,
                raw.lineOverrides(),List.of(),List.of(),List.of(),Map.of(),null);
        Sheet sheet=tx(()->service.create(new SaveRequest(null,"template-cost-command",customer)));
        assertThat(sheet.calculation().totals().knownTotal()).isEqualTo("22.4");
        assertThat(sheet.input().fees().getFirst().source()).startsWith("TEMPLATE:");
        DraftInput excluded=new DraftInput(customer.goodsId(),client,customer.name(),customer.batchQty(),null,"1",customer.effectiveDate(),customer.usageStrategy(),customer.priceStrategy(),null,
                customer.lineOverrides(),List.of(),List.of(),List.of(),Map.of("costExcludedFeeKeys","[\"manage\"]"),null);
        assertThat(service.preview(excluded).totals().knownTotal()).isEqualTo("20");
        DraftInput manual=new DraftInput(customer.goodsId(),client,customer.name(),customer.batchQty(),null,"1",customer.effectiveDate(),customer.usageStrategy(),customer.priceStrategy(),null,
                customer.lineOverrides(),List.of(new FeeInput("manage","本单管理分摊","PERCENT","MANAGEMENT",null,"5",null,List.of("MATERIAL"),"MANUAL","本单约定")),
                List.of(),List.of(),Map.of(),null);
        assertThat(service.preview(manual).totals().knownTotal()).isEqualTo("21");
        permissions(Set.of("goods:view","goods:cost:view","goods:cost:edit"));
        assertThatThrownBy(()->tx(()->service.saveTemplate(null,new TemplateSave(null,"no-template-permission",new TemplateInput("不允许",root,null,null,null,null,null,List.of(),List.of(),null)))))
                .hasMessageContaining("权限");
    }
    @Test void firstPreviewResolvesAutomaticColumnsAndRefreshKeepsExplicitManualDefinitions() {
        templatePermissions();PriceColumn original=column("喷油","PER_QUANTITY");
        Template template=tx(()->service.saveTemplate(null,new TemplateSave(null,"auto-column-template",columnTemplate(List.of(original)))));
        Map<String,Object> payload=service.previewPayload(input("1"));
        assertThat(payload).containsKeys("lines","totals","contentDigest","resolvedInput");
        DraftInput first=resolved(payload);assertThat(first.priceColumns()).containsExactly(original);
        assertThat(first.extraFields().get("costAutoPriceColumnKeys")).isEqualTo("[\"spray\"]");
        assertThat(first.extraFields().get("costTemplateVersions")).contains(template.id().toString()).contains(":1");
        PriceColumn updated=column("喷涂加工","PER_UNIT");
        tx(()->service.saveTemplate(template.id(),new TemplateSave(1L,"auto-column-update",columnTemplate(List.of(updated)))));
        DraftInput refreshed=resolved(service.previewPayload(first));assertThat(refreshed.priceColumns()).containsExactly(updated);
        assertThat(refreshed.extraFields().get("costAutoPriceColumnKeys")).contains("spray");
        assertThat(refreshed.extraFields().get("costTemplateVersions")).contains(":2");
        PriceColumn own=column("本单开机","FIXED_BATCH");
        Map<String,String> extra=new HashMap<>(first.extraFields());extra.put("costAutoPriceColumnKeys","[]");
        DraftInput manual=withColumns(first,List.of(own),List.of(),extra);
        DraftInput kept=resolved(service.previewPayload(manual));assertThat(kept.priceColumns()).containsExactly(own);
        assertThat(kept.extraFields().get("costAutoPriceColumnKeys")).isEqualTo("[]");
    }
    @Test void populatedAutomaticColumnSurvivesTemplateTypeChangeAndDeletionAndConfirmedVersionStaysFrozen() {
        templatePermissions();PriceColumn original=column("喷油","PER_QUANTITY");
        Template template=tx(()->service.saveTemplate(null,new TemplateSave(null,"protected-column-template",columnTemplate(List.of(original)))));
        DraftInput first=resolved(service.previewPayload(input("1")));
        DraftInput filled=withColumns(first,first.priceColumns(),List.of(new PriceCell(edge.toString(),"spray","3",null,"已确认单价")),first.extraFields());
        tx(()->service.saveTemplate(template.id(),new TemplateSave(1L,"protected-column-type",columnTemplate(List.of(column("百分比加工","PERCENT"))))));
        Map<String,Object> changedPayload=service.previewPayload(filled);DraftInput preserved=resolved(changedPayload);
        assertThat(preserved.priceColumns()).containsExactly(original);
        assertThat(preserved.extraFields().get("costAutoPriceColumnKeys")).isEqualTo("[]");
        assertThat(service.preview(preserved).totals().knownTotal()).isEqualTo("80");
        tx(()->service.saveTemplate(template.id(),new TemplateSave(2L,"protected-column-delete",columnTemplate(List.of()))));
        DraftInput afterDeletion=resolved(service.previewPayload(filled));
        assertThat(afterDeletion.priceColumns()).containsExactly(original);assertThat(afterDeletion.priceCells()).isEqualTo(filled.priceCells());
        assertThat(service.preview(afterDeletion).totals().knownTotal()).isEqualTo("80");
        Sheet sheet=tx(()->service.create(new SaveRequest(null,"protected-column-save",afterDeletion)));
        Sheet confirmed=tx(()->service.confirm(sheet.id(),new Command(1,"protected-column-confirm")));
        tx(()->service.saveTemplate(template.id(),new TemplateSave(3L,"protected-column-later",columnTemplate(List.of(column("后续费率","PERCENT"))))));
        Snapshot snapshot=service.readSnapshot(confirmed.confirmedSnapshotId());
        assertThat(snapshot.input().priceColumns()).containsExactly(original);assertThat(snapshot.calculation().totals().knownTotal()).isEqualTo("80");
        assertThat(snapshot.input().extraFields().get("costTemplateVersions")).contains(":3").doesNotContain(":4");
    }
    @Test void explicitEmptyPriceCellIsPendingWorkAndCannotDisappearWhenTemplateRemovesItsColumn() {
        templatePermissions();PriceColumn original=column("喷油","PER_QUANTITY");
        Template template=tx(()->service.saveTemplate(null,new TemplateSave(null,"empty-column-template",columnTemplate(List.of(original)))));
        DraftInput first=resolved(service.previewPayload(input("1")));
        DraftInput pending=withColumns(first,first.priceColumns(),List.of(new PriceCell(edge.toString(),"spray",null,null,"待核单价")),first.extraFields());
        tx(()->service.saveTemplate(template.id(),new TemplateSave(1L,"empty-column-delete",columnTemplate(List.of()))));
        DraftInput kept=resolved(service.previewPayload(pending));
        assertThat(kept.priceColumns()).containsExactly(original);assertThat(kept.priceCells()).isEqualTo(pending.priceCells());
        assertThat(service.preview(kept).totals().valueState()).isEqualTo("INCOMPLETE");
        DraftInput notApplicable=resolved(service.previewPayload(first));
        assertThat(notApplicable.priceColumns()).isEmpty();assertThat(notApplicable.priceCells()).isEmpty();
    }
    @Test void foreignMissingRateCannotBecomeOneAndActualBaseUuidRejectsOtherRates() {
        UUID foreign=UUID.randomUUID(),base=UUID.randomUUID();
        sql.update("INSERT INTO currencies(id,name,is_base_currency) VALUES(?,'外币',false),(?,'本币',true)",foreign,base);
        DraftInput ordinary=input("1");
        DraftInput missing=withCurrency(ordinary,foreign,null);
        assertThatThrownBy(()->service.previewPayload(missing)).hasMessageContaining("缺少汇率");
        assertThatThrownBy(()->tx(()->service.create(new SaveRequest(null,"foreign-missing-rate",missing)))).hasMessageContaining("缺少汇率");
        assertThat(sql.queryForObject("SELECT count(*) FROM goods_cost_sheets",Integer.class)).isZero();
        assertThatThrownBy(()->service.previewPayload(withCurrency(ordinary,base,"2"))).hasMessageContaining("必须为1");
        assertThat(resolved(service.previewPayload(withCurrency(ordinary,base,null))).exchangeRateToLocal()).isEqualTo("1");
        DraftInput precise=withCurrency(input("14.246913578246913578"),foreign,"7.123456789123456789");
        Sheet sheet=tx(()->service.create(new SaveRequest(null,"foreign-precise-rate",precise)));
        assertThat(sheet.input().exchangeRateToLocal()).isEqualTo("7.123456789123456789");
        assertThat(sheet.calculation().totals().knownTotal()).isEqualTo("40");
        assertThat(sheet.calculation().totals().unitCost()).isEqualTo("4");
    }
    @Test void monetaryTemplateValuesRetainOriginalCurrencyAndAreNotConvertedTwice() {
        templatePermissions();UUID usd=UUID.randomUUID();sql.update("INSERT INTO currencies(id,name,is_base_currency) VALUES(?,'美元',false)",usd);
        List<FeeInput> definitions=List.of(new FeeInput("setup","开机","FIXED_BATCH","PROCESS",null,"10",null,List.of(),"MANUAL",null),
                new FeeInput("cycle","周期","PER_CYCLE","PROCESS",null,"2","3",List.of(),"MANUAL",null),
                new FeeInput("manage","管理率","PERCENT","MANAGEMENT",null,"12",null,List.of("MATERIAL"),"MANUAL",null));
        TemplateInput template=new TemplateInput("美元费用",root,null,null,null,null,null,definitions,List.of(),null,usd,"7");
        tx(()->service.saveTemplate(null,new TemplateSave(null,"usd-template-save",template)));
        DraftInput cny=resolved(service.previewPayload(input("1")));
        assertThat(feeValue(cny,"setup")).isEqualTo("70");assertThat(feeValue(cny,"cycle")).isEqualTo("14");
        assertThat(feeValue(cny,"manage")).isEqualTo("12");
        assertThat(cny.fees().stream().filter(f->f.key().equals("cycle")).findFirst().orElseThrow().quantity()).isEqualTo("3");
        assertThat(cny.extraFields().get("costTemplateSourceValues")).contains(usd.toString()).contains("originalFee").contains("\"value\":\"10\"");
        assertThat(service.preview(cny).sourceRevisions()).containsKey("templates:fee-source-values");
        DraftInput inUsd=resolved(service.previewPayload(withCurrency(cny,usd,"7")));
        assertThat(feeValue(inUsd,"setup")).isEqualTo("10");assertThat(feeValue(inUsd,"cycle")).isEqualTo("2");
        assertThat(feeValue(resolved(service.previewPayload(inUsd)),"setup")).isEqualTo("10");
        assertThatThrownBy(()->tx(()->service.saveTemplate(null,new TemplateSave(null,"missing-template-fx",
                new TemplateInput("缺汇率",root,null,null,null,null,null,List.of(),List.of(),null,usd,null))))).hasMessageContaining("缺少汇率");
    }
    @Test void explicitCurrencyConversionPreservesQuantitiesPercentagesAndOriginalInputsAndDoesNotSave() {
        templatePermissions();UUID usd=UUID.randomUUID();sql.update("INSERT INTO currencies(id,name,is_base_currency) VALUES(?,'美元',false)",usd);
        tx(()->service.saveTemplate(null,new TemplateSave(null,"convert-usd-template",new TemplateInput("美元固定费",root,null,null,null,null,null,
                List.of(new FeeInput("templateSetup","模板费","FIXED_BATCH","PROCESS",null,"5",null,List.of(),"MANUAL",null)),List.of(),null,usd,"7"))));
        DraftInput basic=input("1");
        DraftInput source=new DraftInput(root,null,basic.name(),"10",null,"1",basic.effectiveDate(),"ACTUAL_FIRST","MANUAL",null,
                List.of(new LineOverride(edge.toString(),"2.5",null,"70","5","1",null,"AS_RECORDED",null,"MANUAL","原单位报价")),
                List.of(new FeeInput("fixed","本单固定费","FIXED_BATCH","OTHER",null,"35",null,List.of(),"MANUAL",null),
                        new FeeInput("percent","本单百分比","PERCENT","MANAGEMENT",null,"20","7",List.of("MATERIAL"),"MANUAL",null)),
                List.of(new PriceColumn("paint","喷油","PER_QUANTITY","PROCESS",List.of()),new PriceColumn("rate","比例费用","PERCENT","MANAGEMENT",List.of("MATERIAL"))),
                List.of(new PriceCell(edge.toString(),"paint","7","2","明确费用"),new PriceCell(edge.toString(),"rate","10","99","比例")),Map.of(),null);
        assertThat(service.preview(source).totals().knownTotal()).isEqualTo("539");
        ConvertedCurrency converted=service.convertCurrency(new ConvertCurrencyRequest(source,usd,"7"));
        DraftInput target=converted.input();
        assertThat(target.currencyId()).isEqualTo(usd);assertThat(target.exchangeRateToLocal()).isEqualTo("7");assertThat(target.batchQty()).isEqualTo("10");
        LineOverride line=target.lineOverrides().getFirst();assertThat(line.adoptedQty()).isEqualTo("2.5");assertThat(line.unitPrice()).isEqualTo("2");
        assertThat(line.priceUnitRate()).isEqualTo("1");assertThat(line.priceExchangeRateToLocal()).isEqualTo("7");assertThat(line.taxMode()).isEqualTo("AS_RECORDED");
        assertThat(line.reason()).contains("原单位报价").contains("币种换算");
        assertThat(feeValue(target,"fixed")).isEqualTo("5");assertThat(feeValue(target,"percent")).isEqualTo("20");
        assertThat(feeValue(target,"templateSetup")).isEqualTo("5");
        assertThat(target.fees().stream().filter(f->f.key().equals("percent")).findFirst().orElseThrow().quantity()).isEqualTo("7");
        assertThat(target.priceCells().getFirst().value()).isEqualTo("1");assertThat(target.priceCells().getFirst().quantity()).isEqualTo("2");
        assertThat(target.priceCells().get(1).value()).isEqualTo("10");assertThat(target.priceCells().get(1).quantity()).isEqualTo("99");
        assertThat(converted.calculation().totals().knownTotal()).isEqualTo("77");assertThat(target.extraFields().get("costCurrencyConversion")).contains("sourceCalculationDigest").contains("afterUnitPrice");
        ConvertedCurrency repeated=service.convertCurrency(new ConvertCurrencyRequest(target,usd,"7"));
        assertThat(repeated.input()).isEqualTo(target);assertThat(repeated.calculation().totals().knownTotal()).isEqualTo("77");
        assertThat(source.lineOverrides().getFirst().unitPrice()).isEqualTo("70");assertThat(source.priceCells().getFirst().value()).isEqualTo("7");
        assertThat(sql.queryForObject("SELECT count(*) FROM goods_cost_sheets",Integer.class)).isZero();
        assertThatThrownBy(()->service.convertCurrency(new ConvertCurrencyRequest(withCurrency(source,null,null),usd,"7"))).hasMessageContaining("源汇率和目标汇率");
        assertThatThrownBy(()->service.convertCurrency(new ConvertCurrencyRequest(source,usd,null))).hasMessageContaining("源汇率和目标汇率");
    }
    @Test void repeatingCurrencyDivisionUsesTheSharedBudgetProjectionWithoutDoubleConversion() {
        UUID foreign=UUID.randomUUID();sql.update("INSERT INTO currencies(id,name,is_base_currency) VALUES(?,'外币',false)",foreign);
        DraftInput basic=input("0");DraftInput source=new DraftInput(basic.goodsId(),null,basic.name(),basic.batchQty(),null,"1",basic.effectiveDate(),
                basic.usageStrategy(),basic.priceStrategy(),null,basic.lineOverrides(),List.of(new FeeInput("one","固定费","FIXED_BATCH","OTHER",null,"1",null,List.of(),"MANUAL",null)),
                List.of(),List.of(),Map.of(),null);
        ConvertedCurrency first=service.convertCurrency(new ConvertCurrencyRequest(source,foreign,"3"));
        assertThat(feeValue(first.input(),"one")).isEqualTo("0.333333333333333333333333");
        assertThat(feeValue(service.convertCurrency(new ConvertCurrencyRequest(first.input(),foreign,"3")).input(),"one"))
                .isEqualTo("0.333333333333333333333333");
    }
    @Test void missingCycleOutputCanSaveADraftButCannotConfirmUntilOutputIsFilled() {
        DraftInput basic=input("1");
        DraftInput incomplete=new DraftInput(basic.goodsId(),null,basic.name(),"26",null,"1",basic.effectiveDate(),basic.usageStrategy(),basic.priceStrategy(),null,
                basic.lineOverrides(),List.of(new FeeInput("cycle","开机周期","PER_CYCLE","PROCESS",null,"10",null,List.of(),"MANUAL",null)),
                List.of(),List.of(),Map.of(),null);
        Sheet draft=tx(()->service.create(new SaveRequest(null,"cycle-incomplete-draft",incomplete)));
        assertThat(draft.status()).isEqualTo("DRAFT");assertThat(draft.calculation().fees().getFirst().amount()).isNull();
        assertThatThrownBy(()->tx(()->service.confirm(draft.id(),new Command(1,"cycle-incomplete-confirm")))).hasMessageContaining("缺参数");
        DraftInput ready=new DraftInput(incomplete.goodsId(),null,incomplete.name(),incomplete.batchQty(),null,"1",incomplete.effectiveDate(),incomplete.usageStrategy(),incomplete.priceStrategy(),null,
                incomplete.lineOverrides(),List.of(new FeeInput("cycle","开机周期","PER_CYCLE","PROCESS",null,"10","25",List.of(),"MANUAL",null)),
                List.of(),List.of(),Map.of(),null);
        Sheet saved=tx(()->service.save(draft.id(),new SaveRequest(1L,"cycle-filled-save",ready)));
        assertThat(saved.calculation().fees().getFirst().amount()).isEqualTo("20");
        assertThat(tx(()->service.confirm(draft.id(),new Command(2,"cycle-filled-confirm"))).status()).isEqualTo("CONFIRMED");
    }
    private String feeValue(DraftInput input,String key){return input.fees().stream().filter(f->f.key().equals(key)).findFirst().orElseThrow().value();}
    private DraftInput withCurrency(DraftInput in,UUID currency,String rate){return new DraftInput(in.goodsId(),in.clientId(),in.name(),in.batchQty(),currency,rate,
            in.effectiveDate(),in.usageStrategy(),in.priceStrategy(),in.templateId(),in.lineOverrides(),in.fees(),in.priceColumns(),in.priceCells(),in.extraFields(),in.notes());}
    private void templatePermissions(){permissions(Set.of("goods:view","goods:cost:view","goods:cost:edit","goods:cost:confirm","goods:cost:export","goods:cost:template"));}
    private PriceColumn column(String name,String type){return new PriceColumn("spray",name,type,"PROCESS","PERCENT".equals(type)?List.of("MATERIAL"):List.of());}
    private TemplateInput columnTemplate(List<PriceColumn> columns){return new TemplateInput("自动价格列模板",root,null,null,null,null,null,List.of(),columns,null);}
    private DraftInput resolved(Map<String,Object> payload){return (DraftInput)payload.get("resolvedInput");}
    private DraftInput withColumns(DraftInput in,List<PriceColumn> columns,List<PriceCell> cells,Map<String,String> extra){return new DraftInput(in.goodsId(),in.clientId(),in.name(),in.batchQty(),
            in.currencyId(),in.exchangeRateToLocal(),in.effectiveDate(),in.usageStrategy(),in.priceStrategy(),in.templateId(),in.lineOverrides(),in.fees(),columns,cells,extra,in.notes());}
    private DraftInput input(String price) {
        return new DraftInput(root,null,"测试成本","10",null,"1",LocalDate.of(2026,9,29),"ACTUAL_FIRST","MANUAL",null,
                List.of(new LineOverride(edge.toString(),null,null,price,"1","1",null,"AS_RECORDED",null,"MANUAL","已核对来源")),
                List.of(),List.of(),List.of(),Map.of(),null);
    }
    private <T> T tx(Supplier<T> command){return transaction.execute(status->command.get());}
    private void permissions(Set<String> values){when(current.get()).thenReturn(Optional.of(new AuthUser(actor,actor,"cost-test",values,false,true,false)));}
}
