package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.gl.GlReportLineBindingService;
import com.uten.imp.features.finance.gl.GlReportService;
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

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * overhaul-gap-03 真库验收: 总账附表/经营损益表的人工行取已审核工资单、折旧行取固定资产折旧事实,
 * 行与科目/部门的绑定来自配置表; 未配置的行明确标注, 科目改名不影响取数。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false", "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false", "uten.policy-intelligence.enabled=false", "uten.features.goods-owner-scope-enabled=false",
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
    FullChainEndToEndTest fixture;

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
    void laborAndDepreciationRowsEqualThePayrollAndDepreciationFacts() {
        FullChainEndToEndTest.World w = fixture.seedWorld("gl-lines");
        fixture.loginAs(w.superAdminUserId());
        String token = UUID.randomUUID().toString().substring(0, 8).toUpperCase(java.util.Locale.ROOT);
        UUID depreciationStyle = style("GL-DEP-" + token, "设备折旧费用" + token, "EXPENSE");
        UUID accumulatedStyle = style("GL-ACC-" + token, "累计折旧" + token, "ACCOUNT");
        postDepreciation(depreciationStyle, accumulatedStyle, token, new BigDecimal("100.0000"));
        postAmortization(depreciationStyle, accumulatedStyle, new BigDecimal("20.0000"));
        approvedPayroll(w, new BigDecimal("1000.0000"));

        // 未绑定前: 行金额为空并明确标注, 不再显示空白。
        Map<String, Object> unboundLabor = opRow(reports.operatingPl(YEAR, MONTH), "直接人员工资");
        assertThat(unboundLabor.get("amount")).isNull();
        assertThat(unboundLabor.get("basis")).isEqualTo("未配置部门");
        assertThat(opRow(reports.operatingPl(YEAR, MONTH), "设备折旧费").get("basis")).isEqualTo("未配置科目");

        bindings.replace("LABOR_DIRECT", List.of(w.departmentId()));
        bindings.replace("OP_DEPRECIATION_EQUIPMENT", List.of(depreciationStyle));
        bindings.replace("MFG_DEPRECIATION", List.of(depreciationStyle));

        ReportTableResponse pl = reports.operatingPl(YEAR, MONTH);
        assertThat((BigDecimal) opRow(pl, "直接人员工资").get("amount")).isEqualByComparingTo("1000");
        assertThat((BigDecimal) opRow(pl, "设备折旧费").get("amount")).as("固定资产折旧 100 + 长期待摊摊销 20")
                .isEqualByComparingTo("120");
        assertThat((String) opRow(pl, "设备折旧费").get("basis")).contains("设备折旧费用" + token);
        assertThat((BigDecimal) subtotal(pl, "工费合计").get("amount")).as("工费合计包含工资单应发")
                .isEqualByComparingTo("1000");
        assertThat((BigDecimal) subtotal(pl, "管理费合计").get("amount")).as("管理费合计包含折旧与摊销")
                .isEqualByComparingTo("120");

        ReportTableResponse manufacturing = reports.manufacturingExpense(YEAR);
        assertThat((BigDecimal) pivotRow(manufacturing, "直接人工").get("m" + MONTH)).isEqualByComparingTo("1000");
        assertThat((BigDecimal) pivotRow(manufacturing, "资产折旧").get("m" + MONTH)).isEqualByComparingTo("120");
        assertThat((BigDecimal) pivotRow(manufacturing, "资产折旧").get("m1")).as("已配置但当月没有发生额记 0, 不是空")
                .isEqualByComparingTo("0");
        assertThat(pivotRow(manufacturing, "间接人工").get("m" + MONTH)).as("未配置的行留空").isNull();
        assertThat(pivotRow(manufacturing, "间接人工").get("basis")).isEqualTo("未配置部门");

        // 过账后账簿改了折旧费用科目, 历史折旧仍按过账时冻结的科目归行, 与总账发生额一致。
        UUID laterStyle = style("GL-DEP2-" + token, "后改的折旧科目" + token, "EXPENSE");
        jdbc.update("UPDATE finance_asset_books SET expense_style_id=? WHERE expense_style_id=?", laterStyle, depreciationStyle);
        assertThat((BigDecimal) opRow(reports.operatingPl(YEAR, MONTH), "设备折旧费").get("amount"))
                .isEqualByComparingTo("120");

        // 科目改名后照样取数(按科目主键绑定, 不再按名字猜)。
        jdbc.update("UPDATE payment_styles SET name=? WHERE id=?", "改名后的设备折旧" + token, depreciationStyle);
        ReportTableResponse renamed = reports.operatingPl(YEAR, MONTH);
        assertThat((BigDecimal) opRow(renamed, "设备折旧费").get("amount")).isEqualByComparingTo("120");
        assertThat((String) opRow(renamed, "设备折旧费").get("basis")).contains("改名后的设备折旧" + token);
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
        UUID first = style("GL-SF-A-" + token, name, "EXPENSE");
        UUID second = style("GL-SF-B-" + token, name, "EXPENSE");
        bindings.replace("SALES_FEE", List.of(first, second));
        post(first, "10.0000", java.time.LocalDate.of(YEAR, MONTH, 1));
        post(first, "5.0000", java.time.LocalDate.of(YEAR, MONTH, 15));
        post(second, "7.0000", java.time.LocalDate.of(YEAR, MONTH, 2));

        ReportTableResponse sales = reports.salesExpense(YEAR);
        Map<String, Object> firstRow = opRow(sales, name + " (GL-SF-A-" + token + ")");
        Map<String, Object> secondRow = opRow(sales, name + " (GL-SF-B-" + token + ")");
        assertThat((BigDecimal) firstRow.get("m" + MONTH)).isEqualByComparingTo("15");
        assertThat((BigDecimal) secondRow.get("m" + MONTH)).isEqualByComparingTo("7");
        assertThat((BigDecimal) firstRow.get("m1")).as("已配置科目当月无发生额记 0").isEqualByComparingTo("0");

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
        assertThat(tax.get("basis")).isEqualTo("未配置科目");
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
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO payment_styles(id,code,name,category,level,status) VALUES(?,?,?,?,0,'使用')",
                id, code, name, category);
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
                VALUES(?,?,'FIXED_ASSET',?,?,1,?,1200,?,?,1200-?,?,?,'{}'::jsonb,'POSTED','NORMAL')
                """, line, run, asset, book, PERIOD, amount, amount, amount, expenseStyle, accumulatedStyle);
        jdbc.update("""
                INSERT INTO fa_depreciation_log(asset_id,period,amount,asset_book_id,posting_run_id,posting_line_id,
                    sequence,opening_balance,accumulated_amount,closing_balance,entry_kind,status,calculation_snapshot)
                VALUES(?,?,?,?,?,?,1,1200,?,1200-?,'NORMAL','ACTIVE','{}'::jsonb)
                """, asset, PERIOD, amount, book, run, line, amount, amount);
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
                VALUES(?,?,'DEFERRED_EXPENSE',?,?,?,1,?,1200,?,?,1200-?,?,?,'{}'::jsonb,'POSTED','NORMAL')
                """, line, run, deferred, version, scheduleLine, PERIOD, amount, amount, amount, expenseStyle, accountStyle);
        jdbc.update("""
                INSERT INTO da_amortization_log(deferred_id,period,amount,schedule_version_id,schedule_line_id,
                    posting_run_id,posting_line_id,sequence,opening_balance,accumulated_amount,closing_balance,
                    entry_kind,status,calculation_snapshot)
                VALUES(?,?,?,?,?,?,?,1,1200,?,1200-?,'NORMAL','ACTIVE','{}'::jsonb)
                """, deferred, PERIOD, amount, version, scheduleLine, run, line, amount, amount);
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
