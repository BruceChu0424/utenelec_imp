package com.uten.imp.migration;

import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * V740 (ADR-131) 迁移文本契约 (不连库):
 * <ul>
 *   <li>完全不触碰 V711 的 BOM 学习对象 (由 BOM 学习会话 ADR-129/132 独立维护与重建);</li>
 *   <li>每个锚点替换都在锚点缺失或多于一处时失败关闭;</li>
 *   <li>新增文字只用半角括号;</li>
 *   <li>热表上的 UPDATE 触发器按相关列起跳 (UPDATE OF + WHEN, ADR-106)。</li>
 * </ul>
 */
class WorkshopMaterialV740ContractTest {

    private static final String FILE = "V740__workshop_material_periodic_costing.sql";

    /** V711 学习对象: 函数、表、列与会话标记。 */
    private static final List<String> LEARNING_OBJECTS = List.of(
            "fn_touch_bom_learning", "fn_drain_bom_learning_queue", "fn_bom_learning_manual_ownership",
            "fn_refresh_bom_learning", "fn_publish_learned_bom", "fn_enqueue_bom_learning",
            "goods_bom_learning_material_totals", "goods_bom_learning_profiles", "production_bom_learning_samples",
            "production_bom_learning_refresh_queue", "learning_profile_goods_id", "learning_unit_id",
            "app.bom_learning_write");

    private static final Set<String> HOT_TABLES = Set.of(
            "production_execution_segments", "production_daily_reports", "production_daily_report_items",
            "production_material_demands", "stock_documents", "goods");

    private static final Pattern DO_BLOCK = Pattern.compile("(?s)\\bDO\\s+(\\$[a-z_0-9]*\\$)(.*?)\\1");
    private static final Pattern TRIGGER = Pattern.compile(
            "(?is)CREATE\\s+(?:CONSTRAINT\\s+)?TRIGGER\\s+(\\w+)\\s+(?:BEFORE|AFTER)\\s+(.*?)\\s+ON\\s+(\\w+)(.*?)EXECUTE\\s+FUNCTION");

    private static String sql;
    private static String code;

    @BeforeAll
    static void load() throws IOException {
        Path direct = Path.of("src", "main", "resources", "db", "migration", FILE);
        Path path = Files.exists(direct) ? direct
                : Path.of("server", "src", "main", "resources", "db", "migration", FILE);
        sql = Files.readString(path, StandardCharsets.UTF_8);
        code = stripComments(sql);
    }

    @Test
    void v740DoesNotReferenceLearningObjects() {
        for (String name : LEARNING_OBJECTS) {
            assertThat(code).as("V740 must not touch the V711 learning object " + name).doesNotContain(name);
        }
    }

    @Test
    void v740AnchorsFailClosed() {
        Matcher block = DO_BLOCK.matcher(code);
        int anchored = 0;
        while (block.find()) {
            String body = block.group(2);
            if (!body.contains("pg_get_functiondef") && !body.contains("pg_get_viewdef")
                    && !body.contains("pg_get_constraintdef")) {
                continue;
            }
            anchored++;
            assertThat(body).as("anchor block " + block.group(1) + " must fail closed")
                    .containsPattern("RAISE EXCEPTION 'V740 [^']*anchor changed'");
        }
        // 零料 CHECK、成本投入种类、零料证据守卫、成本刷新来源、直送异常视图、委外子件与预排私有能力的按单边读者、
        // 库内提示文字、清空孪生函数。
        assertThat(anchored).isEqualTo(8);
        assertThat(code).contains("pg_get_functiondef('fn_guard_execution_segment_requirement_shape()'::regprocedure)")
                .contains("pg_get_functiondef('fn_guard_cost_business_refresh_source()'::regprocedure)")
                .contains("pg_get_viewdef('v_workshop_direct_stock_anomalies'::regclass, true)")
                .contains("pg_get_functiondef('business_data_reset()'::regprocedure)")
                .contains("pg_get_functiondef('fn_subcontract_component_entitled_lots(uuid,uuid)'::regprocedure)")
                .contains("pg_get_functiondef('fn_subcontract_component_available_stock(uuid,uuid)'::regprocedure)")
                .contains("pg_get_functiondef('fn_preplan_future_source_private_capacity_qty(uuid)'::regprocedure)");
        // 零料证据守卫只做两处锚点替换, 不在 BEGIN 后插入新的早退。
        assertThat(code).doesNotContain("E'BEGIN\\n'");
    }

    @Test
    void v740NewUserMessagesUseAsciiParentheses() {
        assertThat(sql).as("V740 新增文字一律半角括号").doesNotContain("\uFF08").doesNotContain("\uFF09");
        Matcher message = Pattern.compile("RAISE EXCEPTION '([^']*)'").matcher(code);
        List<String> chinese = new ArrayList<>();
        while (message.find()) {
            if (message.group(1).codePoints().anyMatch(point -> point >= 0x4E00 && point <= 0x9FFF)) {
                chinese.add(message.group(1));
            }
        }
        assertThat(chinese).isNotEmpty();
        assertThat(chinese).allSatisfy(text -> assertThat(text)
                .doesNotContainPattern("[A-Za-z]+_[A-Za-z_]+")
                .doesNotContain("\uFF08").doesNotContain("\uFF09"));
    }

    @Test
    void hotTableTriggersHaveColumnGates() {
        Matcher trigger = TRIGGER.matcher(code);
        int hot = 0;
        while (trigger.find()) {
            String events = trigger.group(2).toUpperCase(Locale.ROOT);
            String table = trigger.group(3).toLowerCase(Locale.ROOT);
            if (!HOT_TABLES.contains(table) || !events.contains("UPDATE")) {
                continue;
            }
            hot++;
            assertThat(events).as(trigger.group(1) + " on hot table " + table + " must name its columns")
                    .contains("UPDATE OF");
            assertThat(trigger.group(4)).as(trigger.group(1) + " on hot table " + table + " needs a WHEN")
                    .containsIgnoringCase("WHEN (");
            assertThat(events).as(trigger.group(1) + " keeps INSERT in a separate trigger").doesNotContain("INSERT");
        }
        assertThat(hot).isGreaterThanOrEqualTo(8);
    }

    private static String stripComments(String text) {
        StringBuilder out = new StringBuilder();
        for (String line : text.split("\n", -1)) {
            int comment = line.indexOf("--");
            out.append(comment >= 0 ? line.substring(0, comment) : line).append('\n');
        }
        return out.toString();
    }
}
