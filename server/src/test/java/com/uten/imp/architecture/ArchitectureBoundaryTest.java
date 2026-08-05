package com.uten.imp.architecture;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * 模块边界棘轮测试。
 *
 * <p>先冻结当前允许的模块依赖图，再逐步删除边；任何新增边必须先经过架构评审并更新
 * ADR-017。测试只使用 JDK + JUnit，避免为了结构检查引入运行时依赖。
 */
class ArchitectureBoundaryTest {

    private static final Path MAIN_SOURCE = Path.of("src/main/java/com/uten/imp");
    private static final Path FEATURE_SOURCE = MAIN_SOURCE.resolve("features");
    private static final Pattern FEATURE_IMPORT = Pattern.compile(
            "(?m)^import\\s+com\\.uten\\.imp\\.features\\.([a-zA-Z0-9_]+)\\.");
    private static final Pattern REPOSITORY_DEPENDENCY = Pattern.compile(
            "(?m)^import\\s+.*Repository;\\s*$|private\\s+final\\s+[\\w.]*Repository\\s+\\w+\\s*;");

    /**
     * 现状基线：只允许这些“模块 → 模块”方向。删除代码产生的边不要求保留；
     * 新增方向会直接失败。模块内部依赖不计入。
     */
    private static final Set<String> APPROVED_FEATURE_EDGES = Set.of(
            "admin->auth",
            "admin->org",
            "admin->rbac",
            "auth->admin",
            "auth->org",
            "auth->rbac",
            "dashboard->notice",
            "dashboard->operations",
            "dashboard->production",
            "dashboard->profilechange",
            "dashboard->visitor",
            "finance->admin",
            "notice->auth",
            "notice->org",
            "notice->rbac",
            "org->auth",
            "org->profilechange",
            "org->rbac",
            "production->admin",
            "production->notice",
            "production->purchase",
            "production->stock",
            "profilechange->auth",
            "profilechange->notice",
            "profilechange->org",
            "purchase->admin",
            "purchase->finance",
            "purchase->stock",
            "sales->admin",
            "sales->finance",
            "sales->production",
            "sales->stock",
            "stock->admin",
            "subcontract->admin",
            "subcontract->finance",
            "subcontract->stock",
            "suggestion->org",
            // 2026-08-05：并行 feature 的合法跨 feature 依赖（rd_task BOM 转发涉及 notice/production；
            // 仓库到货控制 ProcurementArrivalControl 跨 warehouse+purchase+subcontract）
            "notice->rd_task",
            "production->rd_task",
            "warehouse->purchase",
            "warehouse->subcontract",
            // 2026-08-06：IQC 待检隔离（V222）落仓库侧，PASS 放行需写库存——warehouse 依赖 stock
            //（与 purchase/subcontract/sales/production →stock 同构，更新 ADR-017）。
            "warehouse->stock",
            "visitor->admin",
            "visitor->org");

    @Test
    void controllersDoNotDependDirectlyOnRepositories() throws IOException {
        List<String> violations = new ArrayList<>();
        for (Path file : javaFiles(FEATURE_SOURCE)) {
            if (!file.getFileName().toString().endsWith("Controller.java")) {
                continue;
            }
            String source = Files.readString(file);
            if (REPOSITORY_DEPENDENCY.matcher(source).find()) {
                violations.add(relative(file));
            }
        }
        assertTrue(violations.isEmpty(),
                () -> "Controller 必须通过应用 Service/Facade 访问数据，禁止直连 Repository:\n"
                        + String.join("\n", violations));
    }

    @Test
    void foundationPackagesDoNotDependOnBusinessFeatures() throws IOException {
        List<String> violations = new ArrayList<>();
        for (String packageName : List.of("audit", "common", "config")) {
            Path packagePath = MAIN_SOURCE.resolve(packageName);
            if (!Files.exists(packagePath)) {
                continue;
            }
            for (Path file : javaFiles(packagePath)) {
                if (FEATURE_IMPORT.matcher(Files.readString(file)).find()) {
                    violations.add(relative(file));
                }
            }
        }
        assertTrue(violations.isEmpty(),
                () -> "基础包不得反向依赖业务 feature:\n" + String.join("\n", violations));
    }

    @Test
    void featureDependencyGraphDoesNotGrow() throws IOException {
        Set<String> actualEdges = new HashSet<>();
        for (Path file : javaFiles(FEATURE_SOURCE)) {
            Path relative = FEATURE_SOURCE.relativize(file);
            if (relative.getNameCount() < 2) {
                continue;
            }
            // Windows 目录历史上存在 profileChange/profilechange 的大小写差异，
            // Java 包名与架构模块名统一按小写比较。
            String sourceFeature = relative.getName(0).toString().toLowerCase(Locale.ROOT);
            Matcher matcher = FEATURE_IMPORT.matcher(Files.readString(file));
            while (matcher.find()) {
                String targetFeature = matcher.group(1).toLowerCase(Locale.ROOT);
                if (!sourceFeature.equals(targetFeature)) {
                    actualEdges.add(sourceFeature + "->" + targetFeature);
                }
            }
        }

        Set<String> unapproved = new HashSet<>(actualEdges);
        unapproved.removeAll(APPROVED_FEATURE_EDGES);
        assertTrue(unapproved.isEmpty(),
                () -> "检测到新的跨 feature 依赖方向；请改用公开 Facade/Port，或先更新 ADR-017:\n"
                        + String.join("\n", unapproved.stream().sorted().toList()));
    }

    private List<Path> javaFiles(Path root) throws IOException {
        try (var files = Files.walk(root)) {
            return files.filter(path -> path.toString().endsWith(".java")).toList();
        }
    }

    private String relative(Path file) {
        return MAIN_SOURCE.relativize(file).toString().replace('\\', '/');
    }
}
