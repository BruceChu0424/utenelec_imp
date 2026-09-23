package com.uten.imp.architecture;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
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
    private static final Pattern ADMIN_CONTROLLER = Pattern.compile(
            "(?m)^@RequestMapping\\(\"/api/admin");
    private static final Pattern WRITE_MAPPING = Pattern.compile(
            "^@(Post|Put|Patch|Delete)Mapping\\b");
    private static final Pattern STEP_UP_EXEMPT = Pattern.compile(
            "@StepUpExempt\\(\"([^\"]*)\"");
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
            "expenseclaim->attachment",
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
            // 2026-09-05 全链弹窗补齐：仓库入库确认后按聚合并撤回「待仓库入库」
            // 居中行动卡（ProcurementIqcStockInService -> ChainNoticeService）。
            "warehouse->notice",
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
            // IQC 隔离与仓库确认入库都落仓库侧；品质 PASS 不写库存，只有仓库确认批次
            // 通过统一 StockService 记账，因此 warehouse 仍合法依赖 stock（ADR-017）。
            "warehouse->stock",
            // 2026-08-06：庆典互动/账号锁定跨切面（V224/V226）——notice 读 system_settings、
            // org 员工详情锁账号，均依赖 admin（admin 为账号/系统设置枢纽，与 finance/production/
            // stock/visitor →admin 同构，已登记 ADR-017）。
            "notice->admin",
            "org->admin",
            "visitor->admin",
            "visitor->org",
            // 2026-09-18：访客黑名单运营元数据（V603）——VisitorGateService 拉黑/解除
            // 需要按 blocked_by 校验并回填操作人，读 features.auth 的 UserAccountRepository
            // （只读跨查，与 visitor->admin/org 同构，ADR-017 登记边）。
            "visitor->auth",
            // 2026-08-07：统一任务并发认领（ADR-023）show-as-locked 守卫接入协作 feature——
            // 费用审批/销售审核/采购分解/仓库单据编辑依赖 features.common.taskclaim 的
            // TaskClaimService 做重复操作服务端兜底（UX 层；正确性底线仍是各 feature 的悲观锁+状态守卫）。
            "expenseclaim->common",
            "purchase->common",
            "sales->common",
            "stock->common");

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
        for (String packageName : List.of("application", "audit", "common", "config")) {
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

    /**
     * ADR-110: /api/admin/** 下的每个写端点 (POST/PUT/PATCH/DELETE) 必须显式声明再认证
     * ({@code @RequiresStepUp}) 或写明理由的豁免 ({@code @StepUpExempt("...")})。
     * 新增管理端写接口时忘记考虑再认证会直接变红。
     */
    @Test
    void adminWriteEndpointsDeclareStepUpOrReasonedExemption() throws IOException {
        List<String> violations = new ArrayList<>();
        int checked = 0;
        for (Path file : javaFiles(MAIN_SOURCE)) {
            String source = Files.readString(file);
            if (!ADMIN_CONTROLLER.matcher(source).find()) {
                continue;
            }
            String[] lines = source.split("\\R");
            for (int i = 0; i < lines.length; i++) {
                if (!WRITE_MAPPING.matcher(lines[i].strip()).find()) {
                    continue;
                }
                checked++;
                String block = annotationBlock(lines, i);
                Matcher exempt = STEP_UP_EXEMPT.matcher(block);
                boolean reasoned = exempt.find() && !exempt.group(1).isBlank();
                if (!block.contains("@RequiresStepUp") && !reasoned) {
                    violations.add(relative(file) + ":" + (i + 1) + " " + lines[i].strip());
                }
            }
        }
        assertTrue(checked > 0, "没有找到任何 /api/admin 写端点, 扫描规则失效");
        List<String> found = violations;
        assertTrue(found.isEmpty(),
                () -> "/api/admin/** 写端点必须带 @RequiresStepUp 或 @StepUpExempt(\"理由\") (ADR-110):\n"
                        + String.join("\n", found));
    }

    /** ADR-110 点名的高危操作必须要求再认证 (防止有人把注解换成豁免)。 */
    @Test
    void highRiskAuthorizationWritesRequireStepUp() throws IOException {
        Map<String, List<String>> required = Map.of(
                "features/admin/AdminUserController.java", List.of(
                        "\"/users/{id}/reset-password\"", "\"/users/{id}/super-admin\"",
                        "\"/users/{id}/remote-access\"", "\"/users/{id}/permission-overrides\"",
                        "\"/users/{id}/data-scopes\""),
                "features/admin/AdminPermissionController.java", List.of(
                        "\"/departments/{departmentId}/permissions\""),
                "features/admin/impersonation/ImpersonationController.java", List.of("\"/enter\""),
                "features/admin/systemsetting/SystemSettingController.java", List.of("@PutMapping"),
                "features/admin/systemtest/SystemTestController.java", List.of(
                        "\"/business-data/reset\"", "\"/business-data/attachments/prepare\""));
        List<String> missing = new ArrayList<>();
        for (Map.Entry<String, List<String>> entry : required.entrySet()) {
            String[] lines = Files.readString(MAIN_SOURCE.resolve(entry.getKey())).split("\\R");
            for (String marker : entry.getValue()) {
                boolean seen = false;
                for (int i = 0; i < lines.length; i++) {
                    String line = lines[i].strip();
                    boolean matches = WRITE_MAPPING.matcher(line).find()
                            && (line.equals(marker) || line.contains(marker + ")"));
                    if (!matches) {
                        continue;
                    }
                    seen = true;
                    if (!annotationBlock(lines, i).contains("@RequiresStepUp")) {
                        missing.add(entry.getKey() + " " + marker);
                    }
                }
                if (!seen) {
                    missing.add(entry.getKey() + " 找不到 " + marker);
                }
            }
        }
        assertTrue(missing.isEmpty(),
                () -> "以下高危写操作必须 @RequiresStepUp (ADR-110):\n" + String.join("\n", missing));
    }

    /**
     * ADR-110: 响应里带明文临时密码的接口 (重置密码、补开账号、入职开号) 不限于 /api/admin 前缀,
     * 同样必须 {@code @RequiresStepUp} 或写明理由的 {@code @StepUpExempt}。凭据类型按 DTO 源码自动识别
     * (记录组件里有 temporaryPassword), 新增返回明文凭据的接口会直接变红。
     */
    @Test
    void endpointsReturningPlaintextCredentialsDeclareStepUp() throws IOException {
        Pattern credentialRecord = Pattern.compile(
                "(?s)public\\s+record\\s+(\\w+)\\s*\\(([^)]*)\\)");
        Set<String> credentialTypes = new HashSet<>();
        for (Path file : javaFiles(MAIN_SOURCE)) {
            Matcher record = credentialRecord.matcher(Files.readString(file));
            while (record.find()) {
                if (record.group(2).matches("(?s).*\\bString\\s+temporaryPassword\\b.*")) {
                    credentialTypes.add(record.group(1));
                }
            }
        }
        assertTrue(credentialTypes.containsAll(Set.of("TemporaryPasswordResponse", "EmployeeOnboardingResult")),
                () -> "凭据 DTO 识别规则失效: " + credentialTypes);

        List<String> violations = new ArrayList<>();
        int checked = 0;
        for (Path file : javaFiles(MAIN_SOURCE)) {
            if (!file.getFileName().toString().endsWith("Controller.java")) {
                continue;
            }
            String[] lines = Files.readString(file).split("\\R");
            for (int i = 0; i < lines.length; i++) {
                String line = lines[i].strip();
                boolean returnsCredential = credentialTypes.stream().anyMatch(type ->
                        line.startsWith("public " + type + " ")
                                || line.startsWith("public ResponseEntity<" + type + "> "));
                if (!returnsCredential) {
                    continue;
                }
                checked++;
                String annotations = annotationsAbove(lines, i);
                Matcher exempt = STEP_UP_EXEMPT.matcher(annotations);
                boolean reasoned = exempt.find() && !exempt.group(1).isBlank();
                if (!annotations.contains("@RequiresStepUp") && !reasoned) {
                    violations.add(relative(file) + ":" + (i + 1) + " " + line);
                }
            }
        }
        assertTrue(checked >= 3, "没有找到返回明文凭据的接口, 扫描规则失效");
        assertTrue(violations.isEmpty(),
                () -> "返回明文临时密码的接口必须 @RequiresStepUp 或 @StepUpExempt(\"理由\") (ADR-110):\n"
                        + String.join("\n", violations));
    }

    /** 方法签名所在行之上的整组注解 (含跨行的注解参数)。 */
    private static String annotationsAbove(String[] lines, int signatureLine) {
        int start = signatureLine;
        while (start > 0) {
            String previous = lines[start - 1].strip();
            if (previous.startsWith("@") || previous.startsWith("//") || previous.startsWith("+")
                    || previous.startsWith("\"") || previous.startsWith("*") || previous.startsWith("/**")) {
                start--;
            } else {
                break;
            }
        }
        StringBuilder block = new StringBuilder();
        for (int i = start; i <= signatureLine; i++) {
            block.append(lines[i]).append('\n');
        }
        return block.toString();
    }

    /** 从写映射注解所在行向上、向下扩到同一方法的整组注解 (到方法签名为止)。 */
    private static String annotationBlock(String[] lines, int mappingLine) {
        int start = mappingLine;
        while (start > 0) {
            String previous = lines[start - 1].strip();
            if (previous.startsWith("@") || previous.startsWith("//") || previous.startsWith("*")
                    || previous.startsWith("/**") || previous.startsWith("\"")) {
                start--;
            } else {
                break;
            }
        }
        StringBuilder block = new StringBuilder();
        for (int i = start; i < lines.length; i++) {
            block.append(lines[i]).append('\n');
            if (i > mappingLine && lines[i].strip().startsWith("public ")) {
                break;
            }
        }
        return block.toString();
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
