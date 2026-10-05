package com.uten.imp.architecture;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * ADR-143 §五 源码扫描契约: 「前置自制 / 唯一子件 / 目标件出仓 / 委外商自备料」这些被删除的概念,
 * 在服务端主代码(src/main/java 与非迁移资源)里不许以任何字面量复活。
 *
 * <p>V798 已经删掉了库里的列、表、函数与取值; 但 PostgreSQL 不跟踪 plpgsql / 原生 SQL 字符串对列的依赖,
 * Java 里残留的 {@code flow_mode} 之类只会在运行时 42703。本测试是 V798 后置扫描在 Java 侧的对偶。
 *
 * <p>历史迁移 V1..V797 原样保留(不可改), V798 自己要写出被删对象的名字(前置检查、删除、后置扫描),
 * 所以 {@code db/migration} 不在扫描范围内。
 *
 * <p>白名单只收与被删概念同名、但含义无关的合法用法, 逐条写明位置、上下文与理由; 白名单条目
 * 不再命中时测试同样失败(防止白名单烂掉后悄悄放过新残留)。
 */
class SubcontractRemovedConceptSourceScanTest {

    private static final Path MAIN_JAVA = Path.of("src/main/java");
    private static final Path MAIN_RESOURCES = Path.of("src/main/resources");
    private static final Path MIGRATIONS = MAIN_RESOURCES.resolve("db").resolve("migration");

    /** 被删的概念(ADR-143 §五 / CONTRACT §2.1、§2.2、§4.3、CONTRACT_NOBOM §3)。标识符按词边界匹配。 */
    private static final List<String> REMOVED_IDENTIFIERS = List.of(
            // 计划行流向判定与准备态列(V798 删列)
            "flow_mode", "flowMode",
            "prepared_qty", "preparedQty",
            "preparation_status",
            "preparation_warehouse_id", "preparationWarehouseId",
            "preparation_bom_fingerprint",
            "preparation_analysis_id",
            "preparation_analysis_item_id",
            "preparation_started_by",
            "preparation_started_at",
            "preparation_version",
            "bom_has_children_snapshot", "bomHasChildrenSnapshot",
            "loss_replacement_qty_base", "lossReplacementQtyBase",
            "subcontract_order_qty_base",
            // 流向取值与被删的加总写法
            "MAKE_THEN_OUTBOUND",
            "PREPARED_OUTBOUND",
            "DIRECT_OUTBOUND",
            "COMPONENT_OUTBOUND",
            "LEGACY_BOM_COMPONENT",
            "DIRECT_TARGET",
            "ISSUED_TARGET_BASE_SUM",
            "NEW_FLOW_MODES",
            "SubcontractOutboundFlowSql",
            // 前置自制全家(来源类型、外部单据类型、预留归属、类与端口)
            "SUBCONTRACT_PREPARATION",
            "SUBCONTRACT_PREPARE_TASK",
            "SUBCONTRACT_ORDER_PREPARATION",
            "SubcontractMakeTaskService",
            "SubcontractOrderPreparationPort",
            "SubcontractOrderPreparationAdapter",
            "SubcontractPreparationPort",
            "SubcontractPreparationInventoryPort",
            "SubcontractPreparationCoordinator",
            "SubcontractPreparationContracts",
            "SubcontractPreparationAutoStartReconciler",
            "SubcontractPreparationEntitlementHandoffService",
            "SubcontractPreparationTaskAdapter",
            "SubcontractDraftPreparationAccessPolicy",
            "subcontract_outbound_preparation_commands",
            "DELEGATED_TO_SUBCONTRACT_PREPARATION",
            "notifySubcontractMakeTaskCreated",
            // 唯一子件判据与 V797 的整体外发函数
            "fn_subcontract_sole_component_goods",
            "fn_subcontract_component_outbound_goods",
            "fn_subcontract_component_edges",
            "fn_subcontract_component_kit_capacity",
            "fn_subcontract_component_available_stock",
            "requireSoleComponentStockAvailable",
            "requireNoMakeThenShortage",
            "wakeOutboundAfterStockIn",
            "v_subcontract_quantity_basis_issues",
            // 任务中心旧阶段与「委外商自备料」
            "WAITING_COMPONENT_STOCK",
            "COMPONENT_STOCK_READY",
            "OUTBOUND_WAITING_COMPONENT",
            "AWAITING_OUTBOUND",
            "SUPPLIER_SELF_SUPPLIED");

    /**
     * 前缀型标识符: 词边界开头, 后面可以接任意标识符字符。
     * SUBCONTRACT_MAKE 同时盖住 SUBCONTRACT_MAKE_TASK; preplan_subcontract_ 盖住整组前置自制表/视图。
     */
    private static final List<String> REMOVED_PREFIXES = List.of(
            "SUBCONTRACT_MAKE",
            "preplan_subcontract_",
            "v_preplan_subcontract_");

    /** 不是标识符的字面量(权限码、中文业务词), 按子串匹配。 */
    private static final List<String> REMOVED_PHRASES = List.of(
            "subcontract_outbound:close",
            "前置自制",
            "自备料",
            "唯一子件");

    /**
     * 合法的同名用法。file 为相对 src/main/java 的路径; context 是命中行必须包含的上下文片段,
     * 只有「同一文件 + 同一字面量 + 该行含 context」的命中才被放过。
     */
    private record Allowed(String file, String literal, String context, String reason) {
    }

    private static final List<Allowed> ALLOWLIST = List.of(
            new Allowed("com/uten/imp/features/notice/ChainNoticeService.java",
                    "preparation_status", "task.preparation_status",
                    "生产执行工作台视图 v_production_execution_workbench_segments 的备料状态列, "
                            + "与已删除的委外计划行准备态无关"),
            new Allowed("com/uten/imp/features/production/execution/ProductionExecutionWorkbenchService.java",
                    "preparation_status", "task.preparation_status",
                    "生产执行工作台的备料状态(PREPARED / 未备齐), 与已删除的委外计划行准备态无关"));

    private record Hit(String file, int line, String literal, String text) {
        @Override
        public String toString() {
            return file + ":" + line + " [" + literal + "] " + text.strip();
        }
    }

    @Test
    void removedSubcontractMakeFirstAndSoleComponentConceptsDoNotSurviveInServerSources() throws IOException {
        assertTrue(Files.isDirectory(MAIN_JAVA),
                "测试必须在 server 目录下运行, 找不到 " + MAIN_JAVA.toAbsolutePath());
        List<Hit> hits = new ArrayList<>();
        int scanned = 0;
        for (Path file : sourceFiles()) {
            scanned++;
            hits.addAll(scan(file));
        }
        assertTrue(scanned > 500, "扫描到的源文件数 " + scanned + " 不对, 路径配置可能错了");

        Set<Allowed> usedAllowances = new LinkedHashSet<>();
        List<Hit> violations = new ArrayList<>();
        for (Hit hit : hits) {
            Allowed allowance = allowanceFor(hit);
            if (allowance == null) {
                violations.add(hit);
            } else {
                usedAllowances.add(allowance);
            }
        }
        assertTrue(violations.isEmpty(),
                "ADR-143 §五 已删除的概念在服务端源码里又出现了(代码与库对象实质删除, 不留兼容分支):\n  "
                        + String.join("\n  ", violations.stream().map(Hit::toString).toList()));

        List<Allowed> stale = ALLOWLIST.stream().filter(allowed -> !usedAllowances.contains(allowed)).toList();
        assertTrue(stale.isEmpty(),
                "白名单条目已不再命中, 请删掉它(不要让白名单比现实宽):\n  "
                        + String.join("\n  ", stale.stream()
                        .map(allowed -> allowed.file() + " [" + allowed.literal() + "] " + allowed.reason()).toList()));
    }

    @Test
    void theScannerItselfRecognisesEveryRemovedLiteral() {
        // 防止正则写错导致扫描形同虚设: 每个被删字面量放进一行典型代码里都必须被认出来。
        List<String> missed = new ArrayList<>();
        for (String identifier : REMOVED_IDENTIFIERS) {
            if (matches("String sql = \"SELECT x." + identifier + " FROM t\";").stream()
                    .noneMatch(found -> found.equals(identifier))) {
                missed.add(identifier);
            }
        }
        for (String prefix : REMOVED_PREFIXES) {
            if (matches("String sql = \"FROM " + prefix + "anything_here\";").isEmpty()) {
                missed.add(prefix + "*");
            }
        }
        for (String phrase : REMOVED_PHRASES) {
            if (matches("String text = \"说明" + phrase + "说明\";").isEmpty()) {
                missed.add(phrase);
            }
        }
        assertTrue(missed.isEmpty(), "扫描规则认不出这些字面量: " + missed);
        // 词边界: 只是包含相同字母的更长标识符不算命中(例如 SUBCONTRACT_COMPONENT_OUTBOUND_xx 里的 COMPONENT_OUTBOUND)。
        assertTrue(matches("String code = \"SUBCONTRACT_COMPONENT_OUTBOUNDX\";").isEmpty(),
                "词边界匹配失效, 会把无关标识符误判为残留");
    }

    // ===================== 扫描 =====================

    private static List<Path> sourceFiles() throws IOException {
        List<Path> files = new ArrayList<>();
        try (Stream<Path> java = Files.walk(MAIN_JAVA)) {
            java.filter(Files::isRegularFile).filter(path -> path.toString().endsWith(".java")).forEach(files::add);
        }
        if (Files.isDirectory(MAIN_RESOURCES)) {
            try (Stream<Path> resources = Files.walk(MAIN_RESOURCES)) {
                resources.filter(Files::isRegularFile)
                        .filter(path -> !path.startsWith(MIGRATIONS))
                        .forEach(files::add);
            }
        }
        files.sort(null);
        return files;
    }

    private static List<Hit> scan(Path file) throws IOException {
        List<Hit> hits = new ArrayList<>();
        List<String> lines = Files.readAllLines(file, StandardCharsets.UTF_8);
        String relative = relative(file);
        for (int index = 0; index < lines.size(); index++) {
            String text = lines.get(index);
            for (String literal : matches(text)) {
                hits.add(new Hit(relative, index + 1, literal, text));
            }
        }
        return hits;
    }

    /** 一行里命中的被删字面量(规范化为列表里的写法)。 */
    private static List<String> matches(String text) {
        List<String> found = new ArrayList<>();
        for (String identifier : REMOVED_IDENTIFIERS) {
            if (identifierPattern(identifier).matcher(text).find()) {
                found.add(identifier);
            }
        }
        for (String prefix : REMOVED_PREFIXES) {
            Matcher matcher = prefixPattern(prefix).matcher(text);
            if (matcher.find()) {
                found.add(prefix);
            }
        }
        for (String phrase : REMOVED_PHRASES) {
            if (text.contains(phrase)) {
                found.add(phrase);
            }
        }
        return found;
    }

    private static Pattern identifierPattern(String identifier) {
        return Pattern.compile("(?<![A-Za-z0-9_])" + Pattern.quote(identifier) + "(?![A-Za-z0-9_])");
    }

    private static Pattern prefixPattern(String prefix) {
        return Pattern.compile("(?<![A-Za-z0-9_])" + Pattern.quote(prefix));
    }

    private static Allowed allowanceFor(Hit hit) {
        for (Allowed allowed : ALLOWLIST) {
            if (allowed.file().equals(hit.file()) && allowed.literal().equals(hit.literal())
                    && hit.text().contains(allowed.context())) {
                return allowed;
            }
        }
        return null;
    }

    private static String relative(Path file) {
        Path base = file.startsWith(MAIN_JAVA) ? MAIN_JAVA : MAIN_RESOURCES;
        return base.relativize(file).toString().replace('\\', '/');
    }
}
