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
     * ADR-105: 审计日志只是留痕, 不是业务事实源(保留期到了会归档/删除, UPDATE 只存变化键)。
     * 业务代码不得读 audit_log / audit_log_archive; 只有审计包自己和清空业务数据的回执例外。
     */
    @Test
    void businessCodeNeverReadsTheAuditLog() throws IOException {
        Pattern auditRead = Pattern.compile("(?i)\\b(?:from|join)\\s+(?:public\\.)?audit_log(?:_archive)?\\b");
        Set<String> allowed = Set.of(
                "features/admin/systemtest/BusinessDataResetService.java",
                // 并发工作流改为只按 xmin 判断「本事务新建」后删除本条(createdHere 不再查审计)。
                "application/concurrency/FulfillmentMutationLocks.java");
        List<String> violations = new ArrayList<>();
        for (Path file : javaFiles(MAIN_SOURCE)) {
            String relative = relative(file);
            if (relative.startsWith("audit/") || allowed.contains(relative)) {
                continue;
            }
            if (auditRead.matcher(Files.readString(file)).find()) {
                violations.add(relative);
            }
        }
        assertTrue(violations.isEmpty(),
                () -> "业务逻辑不得读取审计日志, 需要的业务时间点请落在单据自己的列上:\n"
                        + String.join("\n", violations));
    }

    /**
     * 金额口径锁边(ADR-112)的扫描范围: 单据金额所在模块, 以及会切金额的仓库(IQC 放行/到货超量)、
     * 库存与生产模块。只切数量的类在下面显式豁免并写明理由。
     */
    private static final List<Path> MONEY_SCOPES = List.of(
            FEATURE_SOURCE.resolve("sales"), FEATURE_SOURCE.resolve("purchase"),
            FEATURE_SOURCE.resolve("subcontract"), FEATURE_SOURCE.resolve("finance"),
            FEATURE_SOURCE.resolve("warehouse"), FEATURE_SOURCE.resolve("stock"),
            FEATURE_SOURCE.resolve("production"), MAIN_SOURCE.resolve("common/finance"));
    private static final Pattern HALF_UP = Pattern.compile("RoundingMode\\.HALF_UP|\\bHALF_UP\\b");

    /**
     * 显式豁免(相对 MAIN_SOURCE 的路径前缀 → 理由)。只放「不是金额」或「另有已确认口径」的地方;
     * 金额舍入一律走 MoneyPolicy。工资/报销是用户确认的 2 位 UNNECESSARY(不舍入), 不在扫描范围内。
     */
    private static final Map<String, String> HALF_UP_EXEMPTIONS = Map.ofEntries(
            Map.entry("common/finance/MoneyPolicy.java",
                    "唯一的金额口径类: 累计份额取位、数量 4 位存储、报表占比 2 位都在这里集中定义"),
            Map.entry("features/finance/asset/",
                    "固定资产/待摊: 按月等额 4 位 + 末期吸收全部尾差(守恒已成立), 子账列为 NUMERIC(18,4); 改按累计份额需同步放宽子账列, 另立项"),
            Map.entry("features/subcontract/plan/SubcontractMaterialPlanService.java",
                    "BOM 子件用量(数量, 非金额); 用量公式统一见 dup-backend-split-05"),
            Map.entry("features/subcontract/short_delivery/",
                    "委外短交容差的数量与百分比(非金额)"),
            Map.entry("features/subcontract/waste/SubcontractWasteService.java",
                    "废料补料的 BOM 用量换算(数量, 非金额), 随 BOM 用量统一"),
            Map.entry("features/stock/valuation/",
                    "库存估值: 价值切片 ROUND(来源 × 区间 / 基数, 4) 与 V517 库级守卫同式(4 位兼容投影), "
                            + "4 位来源上与 MoneyPolicy.cumulativeShare 逐位一致; 库存估值精确化随仓库/估值重构另立项"),
            Map.entry("features/stock/CustomerShipmentInventoryService.java",
                    "发货基本单位数量取 4 位(数量, 非金额)"),
            Map.entry("features/stock/StockDocService.java",
                    "成品点收按比例拆分重量/赠品数量与领料比例(数量, 非金额)"),
            Map.entry("features/production/dailyreport/ProductionFqcFinishedInboundService.java",
                    "FQC 放行按累计切片分摊实际重量(重量是数量口径, 非金额)"),
            Map.entry("features/production/directtransfer/ProductionWorkshopDirectTransferService.java",
                    "车间直送基本单位数量取 4 位(数量, 非金额)"),
            Map.entry("features/production/fulfillment/ProcurementOrderSourceRevisionService.java",
                    "改量时的基本单位数量换算(数量, 非金额)"),
            Map.entry("features/production/mrp/MrpService.java",
                    "齐套进度比例(展示用比例, 非金额)"),
            Map.entry("features/production/plan/ProductionPlanService.java",
                    "生产进度比例(展示用比例, 非金额)"));

    @Test
    void moneyRoundingOnlyLivesInMoneyPolicy() throws IOException {
        List<String> violations = new ArrayList<>();
        for (Path scope : MONEY_SCOPES) {
            if (!Files.exists(scope)) continue;
            for (Path file : javaFiles(scope)) {
                String path = relative(file);
                if (HALF_UP_EXEMPTIONS.keySet().stream().anyMatch(path::startsWith)) continue;
                String code = stripComments(Files.readString(file));
                if (HALF_UP.matcher(code).find()) violations.add(path);
            }
        }
        assertTrue(violations.isEmpty(),
                () -> "金额只按 MoneyPolicy 的精确乘积与累计分摊计算, 禁止各自 setScale/divide(.., HALF_UP)"
                        + "(数量取整用 MoneyPolicy.quantity*):\n" + String.join("\n", violations));
    }

    @Test
    void privateMethodsDoNotCarryTransactional() throws IOException {
        Pattern privateTransactional = Pattern.compile(
                "@Transactional(?:\\([^)]*\\))?\\s*(?:@\\w+(?:\\([^)]*\\))?\\s*)*private\\s");
        List<String> violations = new ArrayList<>();
        for (Path file : javaFiles(MAIN_SOURCE)) {
            if (privateTransactional.matcher(stripComments(Files.readString(file))).find()) {
                violations.add(relative(file));
            }
        }
        assertTrue(violations.isEmpty(),
                () -> "private 方法上的 @Transactional 不会被 Spring 代理拦截, 事务由公共入口负责:\n"
                        + String.join("\n", violations));
    }

    private static String stripComments(String source) {
        return source.replaceAll("(?s)/\\*.*?\\*/", "").replaceAll("(?m)//.*$", "");
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
                        "\"/users/{id}/permission-overrides/grant-all\"",
                        "\"/users/{id}/data-scopes\""),
                "features/admin/AdminPermissionController.java", List.of(
                        "\"/departments/{departmentId}/permissions\"",
                        "\"/departments/{departmentId}/permissions/grant-all\"",
                        "\"/permission-baseline\""),
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
