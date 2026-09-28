package com.uten.imp.architecture;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Pattern;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * ADR-131 §3.5「有没有 BOM」的两个口径锁边。
 *
 * <p>组件发料方式为整批领料 (goods.issue_method='PERIODIC') 的 BOM 行是期间边: 料整批放在车间内料仓,
 * 按期盘点计耗, 物料分析、MRP、委外、履约足迹一律不读它。读 BOM 的 SQL 只有两种合法写法:
 * 边遍历在组件上加「发料方式不是 PERIODIC」(片段里出现 issue_method), 或「有没有 BOM」改调
 * fn_goods_has_bom / fn_goods_has_order_bom / fn_goods_has_periodic_bom (片段里出现 fn_goods_has_)。
 *
 * <p>以 SQL 片段为单位检查: 一个文本块, 或只用 + 连起来的一串字符串字面量算一个片段; 注释不算。
 * 出现 goods_bom_items 的片段必须同时出现上面两种写法之一。白名单按文件与按片段两级, 逐条写明理由;
 * 新增的读者不许进白名单, 应当改用判定函数或加谓词。
 */
class BomPresencePredicateContractTest {

    private static final Path MAIN_SOURCE = Path.of("src/main/java/com/uten/imp");
    private static final String BOM_TABLE = "goods_bom_items";
    private static final List<String> PERIODIC_AWARE = List.of("issue_method", "fn_goods_has_");
    private static final Pattern CONCATENATION = Pattern.compile("\\s*\\+\\s*");

    /** 整个文件豁免 (相对 MAIN_SOURCE 的路径或路径前缀 → 理由)。 */
    private static final Map<String, String> FILE_EXEMPTIONS = Map.ofEntries(
            Map.entry("features/master/goods/",
                    "BOM 维护本身 (增删改、粘贴、导入、发料方式切换、上线准备) 要看全部边, 期间边就在这里维护"),
            Map.entry("features/master/lifecycle/",
                    "主档删除与引用目录: 期间边同样是引用, 被引用的货品不能删"),
            Map.entry("audit/",
                    "审计解读只把表名翻译成中文, 不读 BOM 内容"),
            Map.entry("features/production/mrp/ProductionExecutionPlanningService.java",
                    "下达读全部边后自己分流: 期间边不建需求, 只决定零料原因与执行指纹的料身份 (ADR-131 §3.3、§3.4)"),
            Map.entry("features/production/report/ProductionWhereUsedQueryService.java",
                    "「在哪用到」报表要显示期间边, 颗粒用在哪些产品上正是要查的"),
            Map.entry("features/production/analysis/MaterialAnalysisBomSnapshotReader.java",
                    "物料分析快照: 已在两段 JOIN 组件上过滤期间边, 「有没有下层」调 fn_goods_has_order_bom;"
                            + " 校验 SQL 由 %s 拼接, 片段形状特殊, 整文件豁免"),
            Map.entry("features/finance/cost/FinanceCostService.java",
                    "附件8 塑料用量换源到车间内料仓期间报表后不再读 BOM, 换源完成前的过渡期豁免"),
            Map.entry("features/production/mrp/BottomUpPlanOrchestrator.java",
                    "只在注释里提到 BOM 表, 不读 BOM"));

    /** 按片段豁免: 文件 + 片段里的标志文字 → 理由。 */
    private record FragmentExemption(String file, String marker, String reason) { }

    private static final List<FragmentExemption> FRAGMENT_EXEMPTIONS = List.of(
            new FragmentExemption("features/notice/ChainNoticeService.java",
                    "SELECT COUNT(*) FROM goods_bom_items WHERE goods_id = ?",
                    "研发「BOM 缺失」任务自动完成: 期间边就是注塑件完整的 BOM, 算已维护 (ADR-131 §6 第 18 条)"),
            new FragmentExemption("features/production/fulfillment/ProductionMaterialDiscoveryService.java",
                    "WITH RECURSIVE descendants",
                    "领料发现的组件环检测: 环要看全部边"),
            new FragmentExemption("features/production/mrp/MrpService.java",
                    "has_cycle",
                    "MRP 展开前的环与超深检测: 环要看全部边, 不改"));

    @Test
    void everyBomReaderSkipsPeriodicEdgesOrCallsThePresenceFunctions() throws IOException {
        List<String> violations = new ArrayList<>();
        int checked = 0;
        for (Path file : javaFiles(MAIN_SOURCE)) {
            String path = relative(file);
            if (fileExempt(path)) continue;
            for (Fragment fragment : bomFragments(file)) {
                if (fragmentExempt(path, fragment)) continue;
                checked++;
                if (!periodicAware(fragment)) violations.add(path + ":" + fragment.line());
            }
        }
        assertTrue(checked > 0, "没有扫描到任何读 BOM 的 SQL 片段, 源码路径或片段切分失效");
        assertTrue(violations.isEmpty(), () -> "读 goods_bom_items 的 SQL 必须跳过整批领料的期间边"
                + " (组件加 issue_method<>'PERIODIC'), 或改调 fn_goods_has_bom / fn_goods_has_order_bom /"
                + " fn_goods_has_periodic_bom (ADR-131 §3.5); 确需看全部边的写进白名单并写明理由:\n"
                + String.join("\n", violations));
    }

    @Test
    void exemptionsStillPointAtRealBomReaders() throws IOException {
        for (String path : FILE_EXEMPTIONS.keySet()) {
            assertTrue(Files.exists(MAIN_SOURCE.resolve(path)), () -> "白名单文件已不存在, 请删掉这一条: " + path);
        }
        for (FragmentExemption exemption : FRAGMENT_EXEMPTIONS) {
            Path file = MAIN_SOURCE.resolve(exemption.file());
            assertTrue(Files.exists(file), () -> "白名单文件已不存在, 请删掉这一条: " + exemption.file());
            assertTrue(bomFragments(file).stream().anyMatch(fragment -> fragment.text().contains(exemption.marker())),
                    () -> "白名单片段已不在 " + exemption.file() + " 里读 BOM, 请删掉这一条: " + exemption.marker());
        }
    }

    @Test
    void fragmentsFollowTextBlocksAndPlusConcatenationAndSkipComments() {
        String source = """
                class Sample {
                    // SELECT 1 FROM goods_bom_items (注释不算)
                    /* goods_bom_items 也不算 */
                    char quote = '"';
                    char escaped = '\\'';
                    String joined = "SELECT 1 FROM goods_bom_items bom "
                            + "JOIN goods c ON c.id=bom.component_goods_id "
                            // 连接中间的注释不打断片段
                            + "AND c.issue_method<>'PERIODIC'";
                    String ternary = flag ? "TRUE" : "NOT EXISTS (SELECT 1 FROM goods_bom_items bom)";
                    String block = \"""
                            SELECT fn_goods_has_order_bom(goods.id) FROM goods
                            WHERE note = 'say \\"hi\\"'
                            \""";
                    String bare = \"""
                            SELECT 1 FROM goods_bom_items
                            \""".formatted("goods_bom_items");
                }
                """;
        List<Fragment> fragments = fragments(source);
        List<Fragment> bom = fragments.stream().filter(fragment -> readsBom(fragment.text())).toList();
        assertEquals(4, bom.size(), () -> "片段切分不对: " + fragments);
        assertTrue(periodicAware(bom.get(0)), "只用 + 连起来的一串字面量是同一个片段");
        assertEquals(6, bom.get(0).line(), "片段行号取第一个字面量所在行");
        assertFalse(periodicAware(bom.get(1)), "三元表达式两边是不同的片段");
        assertFalse(periodicAware(bom.get(2)), "文本块与 formatted 的参数是不同的片段");
        assertFalse(periodicAware(bom.get(3)));
        assertTrue(fragments.stream().anyMatch(fragment -> fragment.text().contains("fn_goods_has_order_bom")),
                "文本块里的转义引号不提前结束文本块");
        assertTrue(fragments.stream().noneMatch(fragment -> fragment.text().contains("注释")),
                "注释里的文字不算片段");
    }

    // -----------------------------------------------------------------
    // 片段切分: 跳过注释与字符字面量, 文本块与普通字符串各算字面量,
    // 相邻字面量之间只有 + 与空白时并成同一个片段。
    // -----------------------------------------------------------------

    record Fragment(int line, String text) { }

    private static List<Fragment> bomFragments(Path file) throws IOException {
        return fragments(Files.readString(file)).stream().filter(fragment -> readsBom(fragment.text())).toList();
    }

    static List<Fragment> fragments(String source) {
        List<Fragment> result = new ArrayList<>();
        StringBuilder current = null;
        int currentLine = 0;
        StringBuilder between = new StringBuilder();
        int line = 1;
        int i = 0;
        int n = source.length();
        while (i < n) {
            char c = source.charAt(i);
            if (c == '/' && i + 1 < n && source.charAt(i + 1) == '/') {
                int end = source.indexOf('\n', i);
                i = end < 0 ? n : end;
                continue;
            }
            if (c == '/' && i + 1 < n && source.charAt(i + 1) == '*') {
                int end = source.indexOf("*/", i + 2);
                end = end < 0 ? n : end + 2;
                line += newlines(source, i, end);
                i = end;
                continue;
            }
            if (c == '\'') {
                int j = i + 1;
                while (j < n && source.charAt(j) != '\'') {
                    if (source.charAt(j) == '\\') j++;
                    j++;
                }
                between.append('c');
                i = Math.min(j + 1, n);
                continue;
            }
            if (c == '"') {
                boolean block = source.startsWith("\"\"\"", i);
                int j = i + (block ? 3 : 1);
                StringBuilder text = new StringBuilder();
                while (j < n) {
                    char d = source.charAt(j);
                    if (d == '\\' && j + 1 < n) {
                        text.append(d).append(source.charAt(j + 1));
                        j += 2;
                        continue;
                    }
                    if (block ? source.startsWith("\"\"\"", j) : d == '"' || d == '\n') break;
                    text.append(d);
                    j++;
                }
                boolean concatenated = current != null && CONCATENATION.matcher(between).matches();
                if (!concatenated) {
                    if (current != null) result.add(new Fragment(currentLine, current.toString()));
                    current = new StringBuilder();
                    currentLine = line;
                }
                current.append(text);
                between.setLength(0);
                line += newlines(source, i, Math.min(j, n));
                i = Math.min(j + (block ? 3 : 1), n);
                continue;
            }
            if (c == '\n') line++;
            between.append(c);
            i++;
        }
        if (current != null) result.add(new Fragment(currentLine, current.toString()));
        return result;
    }

    private static int newlines(String source, int from, int to) {
        int count = 0;
        for (int k = from; k < to; k++) {
            if (source.charAt(k) == '\n') count++;
        }
        return count;
    }

    private static boolean readsBom(String text) {
        return text.toLowerCase(Locale.ROOT).contains(BOM_TABLE);
    }

    private static boolean periodicAware(Fragment fragment) {
        String text = fragment.text().toLowerCase(Locale.ROOT);
        return PERIODIC_AWARE.stream().anyMatch(text::contains);
    }

    private static boolean fileExempt(String path) {
        return FILE_EXEMPTIONS.keySet().stream().anyMatch(path::startsWith);
    }

    private static boolean fragmentExempt(String path, Fragment fragment) {
        return FRAGMENT_EXEMPTIONS.stream().anyMatch(exemption -> exemption.file().equals(path)
                && fragment.text().contains(exemption.marker()));
    }

    private static List<Path> javaFiles(Path root) throws IOException {
        try (Stream<Path> paths = Files.walk(root)) {
            return paths.filter(path -> path.toString().endsWith(".java")).sorted().toList();
        }
    }

    private static String relative(Path file) {
        return MAIN_SOURCE.relativize(file).toString().replace('\\', '/');
    }
}
