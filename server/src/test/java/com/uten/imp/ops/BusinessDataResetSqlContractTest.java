package com.uten.imp.ops;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 工作台「系统测试 · 清空业务数据」三处事实的同步锁：
 * <ol>
 *   <li>ops/reset_business_data.sql（psql 停机版）的全量 CLEAR/PRESERVE 分类；</li>
 *   <li>迁移函数 business_data_reset()（应用内运行的孪生；V464 为最新整函数重发版，
 *       V462 为历史首版）的同一份分类。V474 起经运行时补丁插入
 *       {@link #RUNTIME_RESET_EXTENSIONS} 登记的扩展行（已应用的 V464 字节不可改）；</li>
 *   <li>BusinessDataResetService 只做编排（绑定 actor + 调函数），不内联清空 SQL。</li>
 * </ol>
 * 迁移新增表后必须同步两份清单，否则本测试失败关闭；运行时未知表同样拒绝执行。
 */
class BusinessDataResetSqlContractTest {

    private static final Pattern POLICY_ROW = Pattern.compile(
            "(?m)^\\s*\\('([^']+)'\\s*,\\s*'(CLEAR|PRESERVE)'\\)[,;]?$");

    /**
     * V474 起经「读取已安装函数定义 + 失败关闭锚点替换」插入孪生函数的扩展行。
     * 表名 -> 引入迁移版本号；新增扩展时同步登记，并保持 ops 脚本与补丁锚点一致。
     */
    private static final Map<String, Integer> RUNTIME_RESET_EXTENSIONS = Map.of(
            "preplan_public_supply_events", 474);

    private String opsScript;
    private String migrationSql;
    private String serviceSource;
    private String extensionSql;

    @BeforeEach
    void loadSources() throws IOException {
        opsScript = read(Path.of("ops", "reset_business_data.sql"),
                Path.of("server", "ops", "reset_business_data.sql"));
        migrationSql = read(
                Path.of("src", "main", "resources", "db", "migration",
                        "V464__reset_twin_order_item_sources.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration",
                        "V464__reset_twin_order_item_sources.sql"));
        extensionSql = read(
                Path.of("src", "main", "resources", "db", "migration",
                        "V474__preplan_public_supply_and_inbound_allocation.sql"),
                Path.of("server", "src", "main", "resources", "db", "migration",
                        "V474__preplan_public_supply_and_inbound_allocation.sql"));
        serviceSource = read(
                Path.of("src", "main", "java", "com", "uten", "imp", "features", "admin",
                        "systemtest", "BusinessDataResetService.java"),
                Path.of("server", "src", "main", "java", "com", "uten", "imp", "features",
                        "admin", "systemtest", "BusinessDataResetService.java"));
    }

    @Test
    void appTwinFunctionClassifiesExactlyTheOpsScriptTables() {
        Map<String, String> opsPolicy = policy(opsScript);
        Map<String, String> twinPolicy = policy(migrationSql);

        assertThat(opsPolicy).hasSize(320 + RUNTIME_RESET_EXTENSIONS.size());
        assertThat(opsPolicy.values().stream().filter("CLEAR"::equals).count())
                .isEqualTo(224 + RUNTIME_RESET_EXTENSIONS.size());
        assertThat(opsPolicy.values().stream().filter("PRESERVE"::equals).count())
                .isEqualTo(96);

        // V464 基础清单逐表一致：任何一侧漂移（新增/删除/改分类）都失败关闭。
        Map<String, String> opsBase = new LinkedHashMap<>(opsPolicy);
        RUNTIME_RESET_EXTENSIONS.keySet().forEach(opsBase::remove);
        assertThat(twinPolicy).isEqualTo(opsBase);
        // 扩展行必须全部 CLEAR：追加式运行时事件账随系统测试一并清空。
        RUNTIME_RESET_EXTENSIONS.keySet().forEach(table ->
                assertThat(opsPolicy.get(table))
                        .as(table + " runtime reset extension must be CLEAR")
                        .isEqualTo("CLEAR"));
    }

    @Test
    void runtimeResetExtensionsPatchTheTwinFunctionFailClosed() {
        // V474 的补丁构件：读取已安装定义、锚点替换插入、锚点缺失即失败关闭。
        assertThat(extensionSql)
                .contains("pg_get_functiondef('business_data_reset()'::regprocedure)")
                .contains("RAISE EXCEPTION 'V474 cannot extend business_data_reset policy safely'")
                .contains("(''preplan_supply_actions'', ''CLEAR'')");
        for (String table : RUNTIME_RESET_EXTENSIONS.keySet()) {
            assertThat(extensionSql)
                    .as(table + " must be inserted by the runtime reset patch")
                    .contains("(''" + table + "'', ''CLEAR'')");
        }
    }

    @Test
    void appTwinKeepsOpsFailClosedChecksAndAddsKickAll() {
        // 与 ops 版同款失败关闭构件
        assertThat(migrationSql)
                .contains("存在未分类 public 表")
                .contains("表分类重复/重叠")
                .contains("保留表仍引用待清业务表，禁止清空")
                .contains("EXECUTE 'TRUNCATE TABLE ' || clear_tables || ' RESTART IDENTITY'")
                .contains("清空校验失败")
                .contains("保留校验失败")
                .contains("物化视图清空校验失败")
                .contains("账户金额归零校验失败")
                .contains("遗留期初归零校验失败")
                .contains("货品安全库存/成本预算归零校验失败")
                .contains("USING ERRCODE = 'UT900'")
                .contains("REFRESH MATERIALIZED VIEW purchase_monthly_mv")
                .contains("REFRESH MATERIALIZED VIEW production_monthly_mv")
                .contains("REFRESH MATERIALIZED VIEW stock_monthly_mv")
                .contains("REFRESH MATERIALIZED VIEW finance_ar_ap_mv")
                .contains("REFRESH MATERIALIZED VIEW sales_monthly_mv")
                .contains("REFRESH MATERIALIZED VIEW subcontract_monthly_mv")
                .contains("UPDATE accounts")
                .contains("balance_current = 0")
                .contains("UPDATE payment_styles")
                .contains("init_balance = 0")
                .doesNotContain("DISABLE TRIGGER");

        // 应用内孪生独有的收尾：全员强制重新登录（epoch + 1 / 断续期）
        assertThat(migrationSql)
                .contains("UPDATE authorization_state")
                .contains("epoch = epoch + 1")
                .contains("TRUNCATE TABLE refresh_tokens RESTART IDENTITY");

        // 摘要出参：服务层据此回显
        assertThat(migrationSql)
                .contains("cleared_table_count INT")
                .contains("cleared_rows BIGINT")
                .contains("preserved_table_count INT")
                .contains("authorization_epoch_after BIGINT");
    }

    @Test
    void serviceOrchestratesOnlyAndBindsActorParameters() {
        // 服务层只编排：调用函数、绑定 actor（? 参数）、设置事务级超时；
        // 清空 SQL 全部在迁移函数里（安全写入门不允许 Java 内联此类 SQL）。
        assertThat(serviceSource)
                .contains("FROM business_data_reset()")
                .contains("SELECT set_config('app.actor_id', ?, true)")
                .contains("SET LOCAL lock_timeout = '15s'")
                .contains("SET LOCAL statement_timeout = '30min'")
                .doesNotContain("TRUNCATE TABLE")
                .doesNotContain("DO $$");
        // 编排门禁与排水
        assertThat(serviceSource)
                .contains("featureGate.requireEnabled()")
                .contains("drainGate.beginDrain")
                .contains("drainGate.endReset()");
    }

    private static Path resolve(Path direct, Path fallback) {
        return Files.exists(direct) ? direct : fallback;
    }

    private static String read(Path direct, Path fallback) throws IOException {
        return Files.readString(resolve(direct, fallback), StandardCharsets.UTF_8);
    }

    private Map<String, String> policy(String sql) {
        Map<String, String> result = new LinkedHashMap<>();
        Matcher matcher = POLICY_ROW.matcher(sql);
        while (matcher.find()) {
            String previous = result.put(matcher.group(1), matcher.group(2));
            assertThat(previous)
                    .as("duplicate policy row for " + matcher.group(1))
                    .isNull();
        }
        return result;
    }
}
