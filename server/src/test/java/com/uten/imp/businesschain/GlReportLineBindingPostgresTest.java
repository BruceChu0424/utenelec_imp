package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.gl.GlReportLineBindingService;
import com.uten.imp.features.finance.gl.GlReportService;
import com.uten.imp.features.finance.gl.FinanceControlledJournalService;
import com.uten.imp.features.finance.report.ReportTableResponse;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * 真库验收: 原表行按配置的科目/部门读取可证明的会计来源；人事审核不冒充已入账工资成本。
 * 折旧/摊销使用与总账对齐的不可变过账事实，同名科目与原表人员/渠道分组分别保留身份。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false", "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false", "uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true", "uten.storage.malware-scan.provider=test-only", "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789", "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test", "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class GlReportLineBindingPostgresTest {
    private static final int YEAR = 2031;
    private static final int MONTH = 9;
    private static final String PERIOD = "2031-09";

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate jdbc;
    @Autowired GlReportService reports;
    @Autowired GlReportLineBindingService bindings;
    @Autowired com.uten.imp.features.finance.gl.FinanceExpenseAnalysisService analysis;
    @Autowired FinanceControlledJournalService journals;
    @Autowired TransactionTemplate transactions;
    FullChainEndToEndTest fixture;
    private UUID assetPreparer;

    @BeforeEach
    void setup() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
    }

    @AfterEach
    void logout() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void bindingsReadPostedAssetFactsAndPayrollApprovalDoesNotInventPostedCost() {
        var w=fixture.seedWorld("gl-lines");
        assetPreparer=fixture.seedWorld("gl-lines-preparer").superAdminUserId();
        fixture.loginAs(w.superAdminUserId());
        String token=UUID.randomUUID().toString().substring(0,8).toUpperCase(java.util.Locale.ROOT);
        UUID depreciationStyle=style("GL-DEP-"+token,"设备折旧费用"+token,"EXPENSE");
        UUID amortizationStyle=style("GL-AMORT-"+token,"待摊摊销费用"+token,"EXPENSE");
        UUID accumulatedStyle=style("GL-ACC-"+token,"累计折旧"+token,"ACCOUNT");
        postDepreciation(depreciationStyle,accumulatedStyle,token,new BigDecimal("100.0000"));
        postAmortization(amortizationStyle,accumulatedStyle,new BigDecimal("20.0000"));
        approvedPayroll(w,new BigDecimal("1000.0000"));
        bindings.replace("LABOR_DIRECT",List.of());
        bindings.replace("OP_DEPRECIATION_EQUIPMENT",List.of());
        var unbound=operating();
        assertThat(byKey(unbound,"LABOR_DIRECT")).containsEntry("item","直接人员工资");
        assertThat(byKey(unbound,"LABOR_DIRECT").get("m"+MONTH)).isNull();
        assertThat(byKey(unbound,"LABOR_DIRECT").get("__basis")).isEqualTo("待配置取数或确认无业务");
        assertThat(byKey(unbound,"OP_DEPRECIATION_EQUIPMENT").get("m"+MONTH)).isNull();
        bindings.replace("LABOR_DIRECT",List.of(w.departmentId()));
        bindings.replace("OP_DEPRECIATION_EQUIPMENT",List.of(depreciationStyle));
        bindings.replace("MFG_DEPRECIATION",List.of(depreciationStyle));
        bindings.replace("ADM_OFFICE_AMORT",List.of(amortizationStyle));
        var pl=operating();
        // Approval is not the native payroll accrual's immutable GL/source evidence.
        assertThat(byKey(pl,"LABOR_DIRECT").get("m"+MONTH)).isNull();
        assertThat(byKey(pl,"LABOR_DIRECT").get("__pending")).isEqualTo(true);
        assertThat((BigDecimal)byKey(pl,"OP_DEPRECIATION_EQUIPMENT").get("m"+MONTH)).isEqualByComparingTo("100");
        assertThat(byKey(pl,"OP_LABOR_TOTAL")).containsEntry("sub","工费合计");
        assertThat(byKey(pl,"OP_LABOR_TOTAL").get("m"+MONTH)).isNull();
        assertThat(byKey(pl,"OP_ADMIN_TOTAL")).containsEntry("sub","一般管理费合计");
        assertThat(byKey(pl,"OP_ADMIN_TOTAL").get("m"+MONTH)).isNull();
        var manufacturing=reports.manufacturingExpense(YEAR);
        assertThat((BigDecimal)byKey(manufacturing,"MFG_DEPRECIATION").get("m"+MONTH)).isEqualByComparingTo("100");
        assertThat((BigDecimal)byKey(manufacturing,"MFG_DEPRECIATION").get("m1")).isZero();
        assertThat((BigDecimal)byKey(reports.adminExpense(YEAR),"ADM_OFFICE_AMORT").get("m"+MONTH)).isEqualByComparingTo("20");
        assertThat(byKey(manufacturing,"LABOR_INDIRECT").get("m"+MONTH)).isNull();
        // A deliberately confirmed empty component is known zero, never a guessed absent fact.
        bindings.replace("OP_MEAL",List.of(),true);
        assertThat((BigDecimal)byKey(operating(),"OP_MEAL").get("m"+MONTH)).isZero();
        UUID later=style("GL-DEP2-"+token,"后改的折旧科目"+token,"EXPENSE");
        jdbc.update("UPDATE finance_asset_books SET expense_style_id=? WHERE expense_style_id=?",later,depreciationStyle);
        jdbc.update("UPDATE payment_styles SET name=? WHERE id=?","改名后的设备折旧"+token,depreciationStyle);
        assertThat((BigDecimal)byKey(operating(),"OP_DEPRECIATION_EQUIPMENT").get("m"+MONTH)).isEqualByComparingTo("100");
        assertThat(bindings.list().stream().filter(line->line.lineKey().equals("OP_DEPRECIATION_EQUIPMENT")).findFirst().orElseThrow().targets())
                .extracting(GlReportLineBindingService.Target::id).containsExactly(depreciationStyle);
    }

    private ReportTableResponse operating() {
        return reports.operatingPlPage(YEAR,MONTH,1,500);
    }
    private static Map<String,Object> byKey(ReportTableResponse report,String key) {
        return report.rows().stream().filter(row->key.equals(row.get("__lineKey"))).findFirst().orElseThrow();
    }

    @Test
    void bindingsAreValidatedAndOneDepartmentCannotBeCountedTwice() {
        FullChainEndToEndTest.World w = fixture.seedWorld("gl-lines-guard");
        fixture.loginAs(w.superAdminUserId());
        bindings.replace("LABOR_DIRECT", List.of(w.departmentId()));
        assertThatThrownBy(() -> bindings.replace("LABOR_INDIRECT", List.of(w.departmentId())))
                .isInstanceOf(ApiException.class).hasMessageContaining("不能同时计入直接人工和间接人工");
        UUID accountStyle = style("GL-NOT-EXPENSE-" + UUID.randomUUID().toString().substring(0, 8), "银行存款科目", "ACCOUNT");
        assertThatThrownBy(() -> bindings.replace("ADM_RENT", List.of(accountStyle)))
                .isInstanceOf(ApiException.class).hasMessageContaining("只能绑定费用类的末级科目");
        String suffix = UUID.randomUUID().toString().substring(0, 8);
        UUID directory = style("GL-DIR-" + suffix, "费用目录" + suffix, "EXPENSE");
        jdbc.update("""
                INSERT INTO payment_styles(id,code,name,category,level,status,parent_id)
                VALUES(?,?,?,'EXPENSE',1,'使用',?)
                """, UUID.randomUUID(), "GL-LEAF-" + suffix, "费用末级" + suffix, directory);
        assertThatThrownBy(() -> bindings.replace("ADM_RENT", List.of(directory)))
                .as("绑目录只算目录本身的发生额, 会漏算下级")
                .isInstanceOf(ApiException.class).hasMessageContaining("只能绑定费用类的末级科目");
        assertThatThrownBy(() -> jdbc.update("""
                INSERT INTO finance_report_line_bindings(line_key,binding_kind,style_id) VALUES('ADM_RENT','STYLE',?)
                """, accountStyle)).as("数据库守卫同口径拦截绕过服务的写入")
                .hasMessageContaining("EXPENSE");
        UUID disabledLeaf = style("GL-OFF-" + suffix, "已停用费用" + suffix, "EXPENSE");
        jdbc.update("UPDATE payment_styles SET status='禁用' WHERE id=?", disabledLeaf);
        assertThat(bindings.replace("ADM_RENT", List.of(disabledLeaf)).targets())
                .as("停用科目仍可绑定, 用于统计历史发生额")
                .extracting(GlReportLineBindingService.Target::id).containsExactly(disabledLeaf);
        assertThatThrownBy(() -> bindings.replace("NOT_A_LINE", List.of()))
                .isInstanceOf(ApiException.class).hasMessageContaining("报表行不存在");
        assertThat(bindings.list()).anySatisfy(line -> {
            assertThat(line.lineKey()).isEqualTo("LABOR_DIRECT");
            assertThat(line.bindingKind()).isEqualTo("DEPARTMENT");
            assertThat(line.targets()).extracting(GlReportLineBindingService.Target::id).containsExactly(w.departmentId());
        });
        bindings.replace("LABOR_DIRECT", List.of());
        assertThat(jdbc.queryForObject("SELECT count(*) FROM finance_report_line_bindings WHERE line_key='LABOR_DIRECT'",
                Long.class)).isZero();
    }

    /** 附 14: 同名的两个销售费用科目各出一行、各算各的(按科目主键分组, 同月多笔累加), 不互相覆盖。 */
    @Test
    void salesExpenseKeepsSameNamedStylesApartAndAddsEveryEntryOfTheMonth() {
        FullChainEndToEndTest.World w = fixture.seedWorld("gl-sales-fee");
        fixture.loginAs(w.superAdminUserId());
        String token = UUID.randomUUID().toString().substring(0, 8).toUpperCase(java.util.Locale.ROOT);
        String name = "同名销售费用" + token;
        // Same labels remain a real UUID-grouping regression, under distinct
        // lawful parents rather than an ambiguous sibling path rejected by V959.
        UUID firstParent=style("GL-SF-PA-"+token,"销售费用目录A"+token,"EXPENSE");
        UUID secondParent=style("GL-SF-PB-"+token,"销售费用目录B"+token,"EXPENSE");
        UUID first = style("GL-SF-A-" + token, name, "EXPENSE",firstParent);
        UUID second = style("GL-SF-B-" + token, name, "EXPENSE",secondParent);
        assertThat(jdbc.queryForObject("SELECT a.name=b.name AND a.parent_id<>b.parent_id FROM payment_styles a,payment_styles b WHERE a.id=? AND b.id=?",
                Boolean.class,first,second)).isTrue();
        bindings.replace("SALES_FEE", List.of(first, second));
        post(first, "10.0000", java.time.LocalDate.of(YEAR, MONTH, 1));
        post(first, "5.0000", java.time.LocalDate.of(YEAR, MONTH, 15));
        post(second, "7.0000", java.time.LocalDate.of(YEAR, MONTH, 2));

        var sources=analysis.entries(PERIOD,1,100,com.uten.imp.features.finance.report.FinanceReportColumnOptions.NONE);
        var matching=sources.rows().stream().filter(row->name.equals(row.get("styleName"))).toList();
        assertThat(matching).hasSize(3);
        for(var expected:List.of(new Object[]{first,"GL-SF-A-"+token,"15"},new Object[]{second,"GL-SF-B-"+token,"7"})) {
            BigDecimal sum=matching.stream().filter(row->expected[1].equals(row.get("styleCode")))
                    .map(row->(BigDecimal)row.get("amount")).reduce(BigDecimal.ZERO,BigDecimal::add);
            assertThat(sum).isEqualByComparingTo(expected[2].toString());
        }
        // The original sales sheet groups actual employees/channels and fee classes.
        // Its presentation must not invent rows grouped by the expense account label.
        var before=reports.salesExpense(YEAR);
        assertThat(before.rows()).noneMatch(row->name.equals(row.get("item")));
        UUID firstGroup=UUID.randomUUID(),secondGroup=UUID.randomUUID();
        analysis.saveGroup(new com.uten.imp.features.finance.gl.FinanceExpenseAnalysisContracts.GroupInput(firstGroup,PERIOD,-1,"渠道A"+token,null,"DOMESTIC","0",true,true,"测试原表渠道A核对",1));
        analysis.saveGroup(new com.uten.imp.features.finance.gl.FinanceExpenseAnalysisContracts.GroupInput(secondGroup,PERIOD,-1,"渠道B"+token,null,"FOREIGN","0",true,true,"测试原表渠道B核对",2));
        for(var row:matching) {
            UUID id=UUID.fromString(row.get("entryId").toString());
            var source=analysis.entry(id);
            UUID group=("GL-SF-A-"+token).equals(row.get("styleCode"))?firstGroup:secondGroup;
            analysis.assign(new com.uten.imp.features.finance.gl.FinanceExpenseAnalysisContracts.AssignmentInput(id,source.get("sourceFingerprint").toString(),-1,
                    List.of(new com.uten.imp.features.finance.gl.FinanceExpenseAnalysisContracts.Allocation(group,"FREIGHT",null,((BigDecimal)row.get("amount")).toPlainString())),"测试原表费用分录完整核对"));
        }
        var sales=reports.salesExpense(YEAR);
        assertThat((BigDecimal)byKey(sales,firstGroup.toString()).get("FREIGHT")).isEqualByComparingTo("15");
        assertThat((BigDecimal)byKey(sales,secondGroup.toString()).get("FREIGHT")).isEqualByComparingTo("7");
        assertThat((BigDecimal)byKey(sales,"SALES_TOTAL_"+MONTH).get("expenseTotal")).isEqualByComparingTo("22");

        Map<String, Object> profitRow = opRow(reports.profitAnnual(YEAR), "销售费用");
        assertThat((BigDecimal) profitRow.get("m" + MONTH)).as("利润表销售费用 = 两个同名科目合计")
                .isEqualByComparingTo("22");
    }

    /** 利润表: 未配置科目的行留空并标注, 不计入利润; 已配置但没有发生额的行显示 0。 */
    @Test
    void profitStatementLeavesUnconfiguredRowsEmptyAndShowsZeroForConfiguredRowsWithoutEntries() {
        FullChainEndToEndTest.World w = fixture.seedWorld("gl-profit-null");
        fixture.loginAs(w.superAdminUserId());
        String token = UUID.randomUUID().toString().substring(0, 8).toUpperCase(java.util.Locale.ROOT);
        bindings.replace("PL_TAX", List.of());
        bindings.replace("PL_FINANCE", List.of(style("GL-FIN-" + token, "手续费" + token, "EXPENSE")));

        ReportTableResponse annual = reports.profitAnnual(YEAR);
        Map<String, Object> tax = opRow(annual, "营业税金及附加");
        assertThat(tax.get("m" + MONTH)).isNull();
        assertThat(tax.get("basis")).isEqualTo("待财务配置科目或确认无业务");
        assertThat((BigDecimal) opRow(annual, "财务费用").get("m" + MONTH)).isEqualByComparingTo("0");
        Map<String, Object> monthly = opRow(reports.profitMonthly(YEAR, MONTH), "营业税金及附加");
        assertThat(monthly.get("monthAmount")).isNull();
        assertThat(monthly.get("yearAmount")).isNull();
    }

    /** 同一张表里一个科目只能归一行(科目行与折旧行之间也一样); 不同表可以各自归一行。 */
    @Test
    void oneStyleCanSitOnOnlyOneLineOfTheSameSheet() {
        FullChainEndToEndTest.World w = fixture.seedWorld("gl-lines-sheet");
        fixture.loginAs(w.superAdminUserId());
        String token = UUID.randomUUID().toString().substring(0, 8).toUpperCase(java.util.Locale.ROOT);
        UUID office = style("GL-OFF-" + token, "办公用品" + token, "EXPENSE");
        bindings.replace("ADM_OFFICE", List.of(office));
        assertThatThrownBy(() -> bindings.replace("ADM_PHONE", List.of(office)))
                .isInstanceOf(ApiException.class).hasMessageContaining("同一张表里一个科目只能归一行");
        assertThat(bindings.replace("OP_OFFICE", List.of(office)).targets())
                .as("附 16 是另一张表, 可以再归一行").extracting(GlReportLineBindingService.Target::id)
                .containsExactly(office);
        UUID depreciation = style("GL-DEPX-" + token, "折旧费用" + token, "EXPENSE");
        bindings.replace("MFG_DEPRECIATION", List.of(depreciation));
        assertThatThrownBy(() -> bindings.replace("MFG_OTHER", List.of(depreciation)))
                .as("折旧本身也按同一费用科目过进总账, 同表再作为科目行会重复计算")
                .isInstanceOf(ApiException.class).hasMessageContaining("资产折旧");
    }

    /** 老库导入科目之后(以及报表设置里「按默认名单补齐」)按原科目名单补默认绑定: 只补没有绑定的行, 幂等。 */
    @Test
    void defaultBindingsFillOnlyUnboundLinesAndAreIdempotent() {
        FullChainEndToEndTest.World w = fixture.seedWorld("gl-lines-seed");
        fixture.loginAs(w.superAdminUserId());
        String token = UUID.randomUUID().toString().substring(0, 8).toUpperCase(java.util.Locale.ROOT);
        UUID rent = style("GL-RENT-" + token, "房租", "EXPENSE");
        UUID custom = style("GL-PHONE-" + token, "自定义电话科目" + token, "EXPENSE");
        bindings.replace("ADM_RENT", List.of());
        bindings.replace("OP_RENT", List.of());
        bindings.replace("OP_PHONE", List.of(custom));

        var seeded = bindings.seedDefaults();
        assertThat(targets(seeded, "ADM_RENT")).contains(rent);
        assertThat(targets(seeded, "OP_RENT")).contains(rent);
        assertThat(targets(seeded, "OP_PHONE")).as("已有绑定的行不动").containsExactly(custom);
        long count = jdbc.queryForObject("SELECT count(*) FROM finance_report_line_bindings", Long.class);
        bindings.seedDefaults();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM finance_report_line_bindings", Long.class))
                .as("再补一次不重复").isEqualTo(count);
        assertThat(jdbc.queryForObject("SELECT fn_finance_report_line_bindings_seed_defaults()", Integer.class))
                .as("老库导入调用的是同一个库函数").isZero();
    }

    private static List<UUID> targets(List<GlReportLineBindingService.LineBinding> lines, String key) {
        return lines.stream().filter(line -> line.lineKey().equals(key)).findFirst().orElseThrow()
                .targets().stream().map(GlReportLineBindingService.Target::id).toList();
    }

    /**
     * 一张借贷平衡的手工凭证: 借费用科目, 贷一个不参与报表行绑定的往来科目(同额)。
     * 测试库在 CI 全量里被所有用例共用, 单边凭证会让别的用例的"全局凭证借贷必平"不变量失败。
     */
    private void post(UUID style, String amount, java.time.LocalDate date) {
        UUID voucher = UUID.randomUUID();
        String period = date.toString().substring(0, 7);
        jdbc.update("""
                INSERT INTO gl_vouchers(id,voucher_no,period,voucher_date,source,source_type,remark)
                VALUES (?,?,?,?,'MANUAL','MANUAL','报表验收')
                """, voucher, "GL-LINE-" + voucher, period, date);
        jdbc.update("""
                INSERT INTO gl_entries(id,voucher_id,line_no,style_id,direction,amount,entry_date,period,summary)
                VALUES (?,?,1,?,1,?,?,?,'报表验收')
                """, UUID.randomUUID(), voucher, style, new BigDecimal(amount), date, period);
        jdbc.update("""
                INSERT INTO gl_entries(id,voucher_id,line_no,style_id,direction,amount,entry_date,period,summary)
                VALUES (?,?,2,?,-1,?,?,?,'报表验收对方科目')
                """, UUID.randomUUID(), voucher, offsetStyle(), new BigDecimal(amount), date, period);
    }

    private UUID offsetStyle;

    /** 贷方对方科目: 往来类(不是费用类), 不绑定任何报表行, 不影响费用取数。 */
    private UUID offsetStyle() {
        if (offsetStyle == null) {
            offsetStyle = style("GL-CR-" + UUID.randomUUID().toString().substring(0, 8), "报表验收对方科目", "ACCOUNT");
        }
        return offsetStyle;
    }

    private UUID style(String code, String name, String category) {
        return style(code,name,category,null);
    }

    private UUID style(String code,String name,String category,UUID parent) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO payment_styles(id,code,name,category,parent_id,level,status) VALUES(?,?,?,?,?,?,'使用')",
                id, code, name, category,parent,parent==null?0:1);
        return id;
    }

    /** 一笔已过账的固定资产正常折旧(公司账簿)。 */
    private void postDepreciation(UUID expenseStyle, UUID accumulatedStyle, String token, BigDecimal amount) {
        UUID asset = UUID.randomUUID();
        UUID book = UUID.randomUUID();
        UUID run = UUID.randomUUID();
        UUID line = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO fixed_assets(id,code,name,original_value,salvage_rate,useful_months,start_period)
                VALUES(?,?,?,1200,0,12,?)
                """, asset, "FA20260923" + String.format("%06d", java.util.concurrent.ThreadLocalRandom.current().nextInt(1, 1_000_000)),
                "报表折旧验收资产", PERIOD);
        jdbc.update("""
                INSERT INTO finance_asset_books(id,asset_id,book_type,method,original_value,residual_rate,residual_amount,
                    depreciable_amount,useful_months,start_period,accumulated_amount,net_book_value,
                    expense_style_id,accumulated_style_id,policy_snapshot,status)
                VALUES(?,?,'CORPORATE','STRAIGHT_LINE',1200,0,0,1200,12,?,0,1200,?,?,'{}'::jsonb,'DRAFT')
                """, book, asset, PERIOD, expenseStyle, accumulatedStyle);
        jdbc.update("""
                INSERT INTO finance_asset_posting_runs(id,run_type,book_type,period,input_fingerprint,algorithm_version,
                    idempotency_key,item_count,total_amount)
                VALUES(?,'DEPRECIATION','CORPORATE',?,'fp','v1',?,1,?)
                """, run, PERIOD, "gl-line-" + token, amount);
        jdbc.update("""
                INSERT INTO finance_asset_posting_lines(id,run_id,object_type,fixed_asset_id,asset_book_id,sequence,period,
                    opening_balance,amount,accumulated_amount,closing_balance,expense_style_id,accumulated_style_id,
                    calculation_snapshot,status,line_kind)
                VALUES(?,?,'FIXED_ASSET',?,?,1,?,1200,?,?,1200-?,?,?,'{}'::jsonb,'INCLUDED','NORMAL')
                """, line, run, asset, book, PERIOD, amount, amount, amount, expenseStyle, accumulatedStyle);
        UUID voucher = assetGl(run, amount, expenseStyle, accumulatedStyle, "FA_DEP");
        jdbc.update("""
                INSERT INTO fa_depreciation_log(asset_id,period,amount,asset_book_id,posting_run_id,posting_line_id,
                    sequence,opening_balance,accumulated_amount,closing_balance,entry_kind,status,calculation_snapshot,voucher_id)
                VALUES(?,?,?,?,?,?,1,1200,?,1200-?,'NORMAL','ACTIVE','{}'::jsonb,?)
                """, asset, PERIOD, amount, book, run, line, amount, amount, voucher);
        finishAssetRun(line, run, voucher);
    }

    /** 一笔已过账的长期待摊正常摊销(公司账簿), 过账明细冻结摊销费用科目。 */
    private void postAmortization(UUID expenseStyle, UUID accountStyle, BigDecimal amount) {
        UUID deferred = UUID.randomUUID();
        UUID version = UUID.randomUUID();
        UUID scheduleLine = UUID.randomUUID();
        UUID run = UUID.randomUUID();
        UUID line = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO deferred_expenses(id,code,name,total_amount,useful_months,start_period)
                VALUES(?,?,?,1200,12,?)
                """, deferred, "DA20260923" + String.format("%06d",
                        java.util.concurrent.ThreadLocalRandom.current().nextInt(1, 1_000_000)),
                "报表摊销验收", PERIOD);
        jdbc.update("""
                INSERT INTO finance_deferral_schedule_versions(id,deferred_id,version,method,total_amount,useful_months,
                    start_period,end_period,benefit_start_on,benefit_end_on,expense_style_id,cost_style_id,clearing_style_id)
                VALUES(?,?,1,'STRAIGHT_LINE',1200,12,?,'2032-08',DATE '2031-09-01',DATE '2032-08-31',?,?,?)
                """, version, deferred, PERIOD, expenseStyle, accountStyle, accountStyle);
        jdbc.update("""
                INSERT INTO finance_deferral_schedule_lines(id,schedule_version_id,sequence,period,opening_balance,
                    amount,accumulated_amount,closing_balance)
                VALUES(?,?,1,?,1200,?,?,1200-?)
                """, scheduleLine, version, PERIOD, amount, amount, amount);
        jdbc.update("""
                INSERT INTO finance_asset_posting_runs(id,run_type,book_type,period,input_fingerprint,algorithm_version,
                    idempotency_key,item_count,total_amount)
                VALUES(?,'AMORTIZATION','CORPORATE',?,'fp','v1',?,1,?)
                """, run, PERIOD, "gl-line-da-" + run, amount);
        jdbc.update("""
                INSERT INTO finance_asset_posting_lines(id,run_id,object_type,deferred_expense_id,schedule_version_id,
                    schedule_line_id,sequence,period,opening_balance,amount,accumulated_amount,closing_balance,
                    expense_style_id,cost_style_id,calculation_snapshot,status,line_kind)
                VALUES(?,?,'DEFERRED_EXPENSE',?,?,?,1,?,1200,?,?,1200-?,?,?,'{}'::jsonb,'INCLUDED','NORMAL')
                """, line, run, deferred, version, scheduleLine, PERIOD, amount, amount, amount, expenseStyle, accountStyle);
        UUID voucher = assetGl(run, amount, expenseStyle, accountStyle, "DA_AMT");
        jdbc.update("""
                INSERT INTO da_amortization_log(deferred_id,period,amount,schedule_version_id,schedule_line_id,
                    posting_run_id,posting_line_id,sequence,opening_balance,accumulated_amount,closing_balance,
                    entry_kind,status,calculation_snapshot,voucher_id)
                VALUES(?,?,?,?,?,?,?,1,1200,?,1200-?,'NORMAL','ACTIVE','{}'::jsonb,?)
                """, deferred, PERIOD, amount, version, scheduleLine, run, line, amount, amount, voucher);
        finishAssetRun(line, run, voucher);
    }

    private UUID assetGl(UUID run, BigDecimal amount, UUID expense, UUID account, String type) {
        UUID actor = beans.getBean(com.uten.imp.security.SecurityContextCurrentUser.class).requireId();
        assertThat(actor).isNotEqualTo(assetPreparer);
        return transactions.execute(status -> journals.post("GL-ASSET-" + run,
                java.time.LocalDate.of(YEAR, MONTH, 30), type, run, "POSTING_RUN", "报表过账来源验收",
                List.of(new FinanceControlledJournalService.Entry(expense, 1, amount, "费用来源"),
                        new FinanceControlledJournalService.Entry(account, -1, amount, "对方来源")), actor)
                .voucherId());
    }

    private void finishAssetRun(UUID line, UUID run, UUID voucher) {
        UUID poster=beans.getBean(com.uten.imp.security.SecurityContextCurrentUser.class).requireId();
        assertThat(poster).isNotEqualTo(assetPreparer);
        // The production posting service inserts the immutable ledger fact with its
        // voucher reference already present, then finalizes the line and run.
        jdbc.update("UPDATE finance_asset_posting_lines SET voucher_id=?,status='POSTED' WHERE id=? AND status='INCLUDED'",voucher,line);
        jdbc.update("UPDATE finance_asset_posting_runs SET voucher_id=?,status='POSTED',submitted_at=now(),submitted_by=?,approved_at=now(),approved_by=?,posted_at=now(),posted_by=? WHERE id=?",voucher,assetPreparer,poster,poster,run);
    }

    /** 一张已审核的部门工资单(应发 gross)。 */
    private void approvedPayroll(FullChainEndToEndTest.World w, BigDecimal gross) {
        UUID batch = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO payroll_batches(id,payroll_year,payroll_month,department_id,status,headcount,
                    gross_income,total_deduction,net_income,generated_by,approved_by,approved_at)
                VALUES(?,?,?,?,'APPROVED',1,?,0,?,?,?,now())
                """, batch, YEAR, MONTH, w.departmentId(), gross, gross, w.employeeId(), w.employeeId());
        jdbc.update("""
                INSERT INTO payroll_slips(batch_id,employee_id,employee_code_snapshot,employee_name_snapshot,
                    department_id_snapshot,payroll_year,payroll_month,gross_income,total_deduction,net_income)
                VALUES(?,?,'E-GL','报表验收员工',?,?,?,?,0,?)
                """, batch, w.employeeId(), w.departmentId(), YEAR, MONTH, gross, gross);
    }

    private static Map<String, Object> opRow(ReportTableResponse report, String item) {
        return report.rows().stream().filter(row -> item.equals(row.get("item"))).findFirst().orElseThrow();
    }

    private static Map<String, Object> subtotal(ReportTableResponse report, String sub) {
        return report.rows().stream().filter(row -> sub.equals(row.get("sub"))).findFirst().orElseThrow();
    }

    private static Map<String, Object> pivotRow(ReportTableResponse report, String item) {
        return opRow(report, item);
    }
}
