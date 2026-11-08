package com.uten.imp.businesschain;

import com.uten.imp.businesschain.WorkshopMaterialClosePostgresTest.CloseBench;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.features.finance.cost.FinanceCostInputContracts;
import com.uten.imp.features.finance.cost.FinanceCostInputService;
import com.uten.imp.features.finance.cost.FinanceCostService;
import com.uten.imp.features.finance.report.ReportColumn;
import com.uten.imp.features.finance.report.ReportTableResponse;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseService;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseService.Result;
import com.uten.imp.features.warehouse.materialbin.close.WorkshopMaterialCloseService.TriggerKind;
import com.uten.imp.support.MigratedProjectionSchema;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.TestContext;
import org.springframework.test.context.TestExecutionListeners;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import com.uten.imp.testsupport.FixtureDatabaseProperties;
import com.uten.imp.testsupport.TestFlyway;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.SQLException;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static com.uten.imp.businesschain.WorkshopMaterialClosePostgresTest.money;
import static org.junit.jupiter.api.Assertions.*;

/**
 * ADR-131 §7.5 附件8 换源 (包 S3): 真实车间月结接原13列及三附表；期间、内料仓和材料单位留在来源元数据。
 * KG换算及两类不良方向须显式核对，缺少来源时保持未知；非有限比例使用本次明确选择。
 * 附件 8-1/8-2/8-3 分别取内料仓发料、退回流水与已结算的理论明细。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "spring.flyway.target=1087", "uten.audit.retention.enabled=false",
        "spring.jpa.mapping-resources=" + HistoricalOrmMappings.BEFORE_V1097,
        "uten.read-summary.compaction-enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false", "uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false", "uten.storage.uploads-enabled=true",
        "uten.storage.malware-scan.provider=test-only",
        "uten.workshop-material.auto-close.enabled=false",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners = PlasticUsageAttachmentPostgresTest.Cleanup.class,
        mergeMode = TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
class PlasticUsageAttachmentPostgresTest {
    private static final PostgreSQLContainer DATABASE=new PostgreSQLContainer("postgres:16-alpine")
            .withDatabaseName("plastic_usage_upgrade").withUsername("fixture_admin").withPassword("uten")
            .withCreateContainerCmdModifier(command->command.getHostConfig()
                    .withMemory(1024L*1024*1024).withNanoCPUs(1_000_000_000L));

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) throws Exception {
        DATABASE.start();
        FixtureDatabaseProperties.bindSameRole(registry, DATABASE::getJdbcUrl,
                DATABASE::getUsername, DATABASE::getPassword);
        var attachments = java.nio.file.Files.createTempDirectory("plastic-usage-attachments-");
        registry.add("uten.storage.local-dir", attachments::toString);
    }
    public static class Cleanup extends AbstractTestExecutionListener {
        @Override public int getOrder() { return new DirtiesContextTestExecutionListener().getOrder()-1; }
        @Override public void afterTestClass(TestContext ignored) throws Exception {
            DATABASE.stop();
        }
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired WorkshopMaterialCloseService closes;
    @Autowired FinanceCostService finance;
    @Autowired FinanceCostInputService inputs;

    @AfterEach
    void logout() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void attachmentEightReadsTheClosedPeriodsWithTheTemplateColumnsInOrder() throws Exception {
        HistoricalOrmMappings.requireOriginalSchema(db, 1087);
        // Retained-record reads consult the V1120 registry while this chain stays
        // at V1087 (then 1088); install the real read-side table and lookup
        // function from the current migrated catalog like the other pinned chains.
        MigratedProjectionSchema.createCurrentTables(db, "imported_document_registry");
        MigratedProjectionSchema.createCurrentFunctions(db, "fn_imported_business_document_registered");
        // 一期: 发 3 公斤、退回 0.5、盘剩 1.3 → 实际 1.2; 报工 5 件 x 0.2 公斤 → 理论 1.0
        CloseBench bench = CloseBench.create(beans, "plastic");
        UUID granule = bench.granule("塑料颗粒", "OWN");
        bench.edge(bench.world.goodsA(), granule, "0.2");
        bench.stockIn(granule, "10", "10");
        bench.confirmInboundAndDrain();
        bench.enable(List.of());
        bench.issue(granule, "3", null);
        bench.returned(granule, "0.5");
        LocalDate cutoff = BusinessTime.today().minusDays(1);
        UUID count = bench.startCount(bench.firstPeriod, cutoff);
        bench.weighed(count, "granule", granule, "1.3");
        bench.submit(count);
        assertEquals(Result.CLOSED, closes.attempt(bench.firstPeriod, TriggerKind.AFTER_COUNT, bench.admin));
        String code = db.queryForObject("SELECT code FROM goods WHERE id = ?", String.class, granule);
        String binName = db.queryForObject("SELECT name FROM warehouses WHERE id = ?", String.class, bench.bin);

        LocalDate monthStart = cutoff.withDayOfMonth(1);
        LocalDate monthEnd = cutoff.withDayOfMonth(cutoff.lengthOfMonth());
        var unreviewed = finance.plasticUsage(code, monthStart, monthEnd, 1, 50).rows().getFirst();
        assertEquals(Boolean.TRUE,unreviewed.get("__pending"));
        assertNull(unreviewed.get("unit"),"没有KG换算依据时不按单位名称猜换算");
        for(String field:List.of("finishedWeight","rejectReturnQty","rejectIssueQty","usageRatio"))
            assertNull(unreviewed.get(field),field);
        UUID periodLine=UUID.fromString(unreviewed.get("__periodLineId").toString());
        var originalInput=new FinanceCostInputContracts.Plastic(UUID.randomUUID(),periodLine,-1L,
                BigDecimal.ZERO,BigDecimal.ZERO,"已核对盘点差异；本期退料均为普通退料，无安装挑选不良",true,
                BigDecimal.ONE,"塑料颗粒",1,"真实月结原单位与KG对应1:1，核对退料方向及期末盘点");
        var saved=inputs.savePlastic(originalInput);
        assertEquals(saved,inputs.savePlastic(originalInput),"同一补充请求只保存一次，保原回执");
        String originalRow=db.queryForObject("SELECT to_jsonb(input)::text FROM finance_plastic_template_inputs input WHERE period_line_id=?",String.class,periodLine);
        String originalReceipt=db.queryForObject("SELECT to_jsonb(operation)::text FROM finance_cost_input_operations operation WHERE request_id=?",String.class,originalInput.requestId());
        String originalClose=db.queryForObject("SELECT to_jsonb(period_close)::text FROM workshop_material_period_closes period_close WHERE id=(SELECT source_close_id FROM finance_plastic_template_inputs WHERE period_line_id=?)",String.class,periodLine);
        assertEquals(List.of("numeric","numeric"),db.queryForList("SELECT format_type(atttypid,atttypmod) FROM pg_attribute WHERE attrelid='finance_plastic_template_inputs'::regclass AND attname IN('reject_return_qty','reject_issue_qty') ORDER BY attname",String.class),
                "V1011已放宽数量存储，不能再依据早期建表定义重复改列");
        String quantityGuards=quantityGuards();
        assertKgAnnotationDomain(periodLine,false);
        TestFlyway.configure().dataSource(DATABASE.getJdbcUrl(),DATABASE.getUsername(),DATABASE.getPassword())
                .locations("classpath:db/migration").target("1088").load().migrate();
        assertEquals(originalRow,db.queryForObject("SELECT to_jsonb(input)::text FROM finance_plastic_template_inputs input WHERE period_line_id=?",String.class,periodLine));
        assertEquals(originalReceipt,db.queryForObject("SELECT to_jsonb(operation)::text FROM finance_cost_input_operations operation WHERE request_id=?",String.class,originalInput.requestId()));
        assertEquals(originalClose,db.queryForObject("SELECT to_jsonb(period_close)::text FROM workshop_material_period_closes period_close WHERE id=(SELECT source_close_id FROM finance_plastic_template_inputs WHERE period_line_id=?)",String.class,periodLine));
        assertEquals(quantityGuards,quantityGuards(),"已有非负和共享40/24数量约束保持原定义");
        assertKgAnnotationDomain(periodLine,true);
        rejectsOutOfDomainInputsWithoutChangingTheOriginal(periodLine);
        ReportTableResponse table;
        try(var ratio=BusinessPrecisionContext.use(Map.of("finance.plastic.usageRatio",
                new BusinessPrecisionContext.Choice(4,"DOWN")))){
            table=finance.plasticUsage(code,monthStart,monthEnd,1,50);
        }
        assertEquals(List.of("rowNo", "goodsName", "prevBalance", "drawQty", "returnQty", "rejectReturnQty",
                        "rejectIssueQty", "finishedWeight", "bookBalance", "checkQty", "diff", "usageRatio", "reason"),
                table.columns().stream().map(ReportColumn::key).toList(), "保原13列，来源元数据不挤入原表");
        var originalFullHeaders=List.of("序号", "材料名称", "上月结存", "本月仓库领用", "不良品退注塑车 / 退料",
                        "不良品退注塑车 / 安装挑选不良", "不良品退注塑车 / 安装挑选不良", "产品入库数", "账面结存",
                        "实 际 盘 点 数", "差异", "成品占材料比例%", "原因");
        assertEquals(List.of("序号", "材料名称", "上月结存", "本月仓库领用", "退料", "安装挑选不良",
                        "安装挑选不良", "产品入库数", "账面结存", "实 际 盘 点 数", "差异", "成品占材料比例%", "原因"),
                table.columns().stream().map(ReportColumn::label).toList(),"原表两层表头的叶文字保持原样");
        var mergedOriginalGroup=new ReportColumn.HeaderGroup("plasticUsage:E3","不良品退注塑车");
        var separateOriginalGroup=new ReportColumn.HeaderGroup("plasticUsage:G3","不良品退注塑车");
        assertEquals(List.of(List.of(),List.of(),List.of(),List.of(),List.of(mergedOriginalGroup),
                        List.of(mergedOriginalGroup),List.of(separateOriginalGroup),List.of(),List.of(),List.of(),
                        List.of(),List.of(),List.of()),
                table.columns().stream().map(ReportColumn::headerGroups).toList(),
                "E3合并组与G3独立原单元格虽同名仍保留不同来源身份");
        assertEquals(originalFullHeaders,table.columns().stream().map(column->{
            var parts=new java.util.ArrayList<String>();
            column.headerGroups().forEach(group->parts.add(group.label()));parts.add(column.label());
            return String.join(" / ",parts);
        }).toList(),"分组与叶文字仍精确组成原13个完整名称，未删改父名");
        assertEquals(1, table.rows().size());
        Map<String, Object> row = table.rows().getFirst();
        assertEquals(code, row.get("goodsCode"));
        money("0", row.get("prevBalance"));
        money("3", row.get("drawQty"));
        money("0.5", row.get("returnQty"));
        assertNull(row.get("rejectQty"),"尚无不良事件记录时不能显示已知零");
        money("0",row.get("rejectReturnQty"));money("0",row.get("rejectIssueQty"));
        assertEquals(Boolean.FALSE,row.get("__pending"));
        assertFalse(table.columnSearchKeys().contains("rejectQty"));
        assertEquals("%",table.columns().stream().filter(column->column.key().equals("usageRatio")).findFirst().orElseThrow().unitLabel());
        assertEquals("KG",row.get("unit"));
        assertEquals(db.queryForObject("SELECT unit_id FROM workshop_material_period_lines WHERE period_id=? AND goods_id=?",UUID.class,bench.firstPeriod,granule).toString(),row.get("__unitId"));
        money("1", row.get("finishedWeight"));
        money("1.5", row.get("bookBalance"));
        money("1.3", row.get("checkQty"));
        money("-0.2", row.get("diff"));
        money("83.3333", row.get("usageRatio"));
        money("0", row.get("otherIssueQty"));
        assertEquals(CloseBench.GO_LIVE + " 至 " + cutoff, row.get("periodLabel"));
        assertEquals(binName, row.get("binName"));

        // This is a classification of an actual existing return, not another
        // stock movement. The public DTO already accepts 24 fractional places.
        var tinyInput=new FinanceCostInputContracts.Plastic(UUID.randomUUID(),periodLine,saved.version(),
                new BigDecimal("0.000000000000000000000001"),BigDecimal.ZERO,
                "已核对原退料：其中1e-24归安装挑选不良，其余普通退料，原实退总数不变",true,
                BigDecimal.ONE,"塑料颗粒",1,"同一已结算原行的精确分类；不改库存或月结事实");
        var tinySaved=inputs.savePlastic(tinyInput);
        assertEquals(saved.version()+1,tinySaved.version());
        assertEquals(saved,inputs.savePlastic(originalInput),"旧成功请求保原回执，不能重新覆盖后来的明确分类");
        try(var ratio=BusinessPrecisionContext.use(Map.of("finance.plastic.usageRatio",
                new BusinessPrecisionContext.Choice(4,"DOWN")))){
            var current=finance.plasticUsage(code,monthStart,monthEnd,1,50).rows().getFirst();
            money("0.000000000000000000000001",current.get("rejectReturnQty"));
            money("0.499999999999999999999999",current.get("returnQty"));
            money("1.5",current.get("bookBalance"));money("-0.2",current.get("diff"));
            money("83.3333",current.get("usageRatio"));
            assertEquals(Boolean.FALSE,current.get("__pending"));
        }
        assertEquals(tinySaved.version(),((Number)inputs.plastic(periodLine).get("version")).longValue());

        // 期末日不在所选月份的期不出; 没结算的期不出
        LocalDate earlier = monthStart.minusMonths(1);
        assertTrue(finance.plasticUsage(code, earlier, earlier.withDayOfMonth(earlier.lengthOfMonth()), 1, 50)
                .rows().isEmpty());

        // 附件 8-1 领料明细: 内料仓发料流水
        ReportTableResponse issued = finance.plasticDetail("issue", code, BusinessTime.today(), BusinessTime.today(),
                1, 50);
        assertEquals(1, issued.rows().size());
        money("3", issued.rows().getFirst().get("qty"));
        assertTrue(issued.rows().getFirst().get("planNo").toString().startsWith("ZL"));
        assertNotNull(issued.rows().getFirst().get("billNo"));

        // 附件 8-2 退料明细: 内料仓退回流水 (实退数量为正)
        ReportTableResponse returned = finance.plasticDetail("return", code, BusinessTime.today(),
                BusinessTime.today(), 1, 50);
        assertEquals(1, returned.rows().size());
        money("0.5", returned.rows().getFirst().get("qty"));

        // 附件 8-3 产品入库明细: 已结算的理论明细 (重量 = 良品 x 单个重量)
        String productCode = db.queryForObject("SELECT code FROM goods WHERE id = ?", String.class,
                bench.world.goodsA());
        String materialName = db.queryForObject("SELECT name FROM goods WHERE id = ?", String.class, granule);
        ReportTableResponse finished = finance.plasticDetail("finished", productCode, LocalDate.of(2026, 1, 1),
                LocalDate.of(2026, 1, 31), 1, 50);
        List<Map<String, Object>> ours = finished.rows().stream()
                .filter(line -> materialName.equals(line.get("material")))
                .toList();
        assertEquals(1, ours.size());
        money("1", ours.getFirst().get("weight"));
        money("5", ours.getFirst().get("qty"));
    }

    private void rejectsOutOfDomainInputsWithoutChangingTheOriginal(UUID line) throws Exception {
        try(Connection connection=java.sql.DriverManager.getConnection(DATABASE.getJdbcUrl(),DATABASE.getUsername(),DATABASE.getPassword())){
            connection.setAutoCommit(false);
            try {
                for(String field:List.of("reject_return_qty","reject_issue_qty","weight_kg_per_unit"))
                    for(String value:List.of("0.0000000000000000000000001","10000000000000000000000000000000000000000","NaN","-1")){
                        var save=connection.setSavepoint();
                        try(var update=connection.prepareStatement("UPDATE finance_plastic_template_inputs SET "+field+"=CAST(? AS numeric) WHERE period_line_id=?")){
                            update.setString(1,value);update.setObject(2,line);
                            SQLException error=assertThrows(SQLException.class,update::executeUpdate,field+" "+value);
                            assertEquals("23514",error.getSQLState(),"The actual exact/signed CHECK must reject this value");
                        } finally {connection.rollback(save);}
                    }
            } finally {connection.rollback();}
        }
    }
    private String quantityGuards(){return db.queryForObject("SELECT jsonb_agg(jsonb_build_object('name',conname,'definition',pg_get_constraintdef(oid)) ORDER BY conname)::text FROM pg_constraint WHERE conrelid='finance_plastic_template_inputs'::regclass AND contype='c' AND pg_get_constraintdef(oid) ~ 'reject_(return|issue)_qty'",String.class);}
    /** Domain probe only, always rolled back; it does not certify a new KG conversion. */
    private void assertKgAnnotationDomain(UUID line,boolean upgraded) throws Exception {
        try(Connection connection=java.sql.DriverManager.getConnection(DATABASE.getJdbcUrl(),DATABASE.getUsername(),DATABASE.getPassword())){
            connection.setAutoCommit(false);
            try(var update=connection.prepareStatement("UPDATE finance_plastic_template_inputs SET weight_kg_per_unit=CAST(? AS numeric) WHERE period_line_id=?")){
                update.setString(1,"0.000000000000000000000001");update.setObject(2,line);
                if(upgraded){
                    assertEquals(1,update.executeUpdate());
                    try(var read=connection.prepareStatement("SELECT weight_kg_per_unit FROM finance_plastic_template_inputs WHERE period_line_id=?")){
                        read.setObject(1,line);try(var values=read.executeQuery()){
                            assertTrue(values.next());money("0.000000000000000000000001",values.getBigDecimal(1));
                        }
                    }
                }else assertEquals("23514",assertThrows(SQLException.class,update::executeUpdate).getSQLState());
            }finally{connection.rollback();}
        }
    }
}
