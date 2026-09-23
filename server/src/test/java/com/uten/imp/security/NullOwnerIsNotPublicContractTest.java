package com.uten.imp.security;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * permissions-10 / ADR-109：「没有负责人就全员可读」只在 {@link DocumentAccessPolicy} 里删掉还不够，
 * 手写 SQL 或私有可见性判断里的同款旁路也必须一起消失。本测试扫描主代码：
 * <ul>
 *   <li>SQL 片段里的 {@code maker_id IS NULL} / {@code owner_employee_id IS NULL}(按旧工号补姓名的
 *       {@code ... IS NULL AND xx.legacy_id = ...} 联表除外，那是显示姓名不是读范围)；</li>
 *   <li>Java 里「全量 或 负责人为空 或 在可见集合里」这类可见性短路，例如
 *       {@code scope.seeAll() || ownerEmployeeId == null || ...}。</li>
 * </ul>
 * 主档(客户 / 供应商 / 货品)的「公共池」是有意的业务语义，按主档包整体放行。
 */
class NullOwnerIsNotPublicContractTest {

    private static final Path MAIN = Path.of("src", "main", "java");

    /** 主档公共池：未指定负责人的客户 / 供应商 / 货品本来就是全员共享的主档。 */
    private static final String MASTER_DATA_PUBLIC_POOL = "com/uten/imp/features/master/";

    private static final Pattern SQL_NULL_OWNER = Pattern.compile(
            "(?i)\\b(?:maker_id|owner_employee_id)\\s+IS\\s+NULL\\b(?!\\s+AND\\s+\\w+\\.legacy_id)");

    private static final Pattern JAVA_NULL_OWNER_SHORT_CIRCUIT = Pattern.compile(
            "seeAll\\(\\)\\s*\\|\\|\\s*[\\w.]*(?:[oO]wner|[mM]aker)\\w*(?:\\(\\))?\\s*==\\s*null"
                    + "|(?:[oO]wner|[mM]aker)\\w*(?:\\(\\))?\\s*==\\s*null\\s*\\|\\|\\s*[\\w.()]*visibleOwners\\(\\)");

    @Test
    void noDocumentReadScopeTreatsAMissingOwnerAsPublic() throws IOException {
        List<String> violations = new ArrayList<>();
        try (Stream<Path> files = Files.walk(MAIN)) {
            for (Path file : files.filter(path -> path.toString().endsWith(".java")).sorted().toList()) {
                String relative = MAIN.relativize(file).toString().replace('\\', '/');
                if (relative.startsWith(MASTER_DATA_PUBLIC_POOL)) {
                    continue;
                }
                String source = Files.readString(file, StandardCharsets.UTF_8);
                collect(relative, source, SQL_NULL_OWNER, violations);
                collect(relative, source, JAVA_NULL_OWNER_SHORT_CIRCUIT, violations);
            }
        }
        assertThat(violations)
                .as("单据读范围不得把「没有负责人」当成全员可见；系统单据请显式声明系统池或记业务负责人")
                .isEmpty();
    }

    @Test
    void theScannerStillRecognisesTheLeakShapesButNotFailClosedChecks() {
        List<String> hits = new ArrayList<>();
        collect("sample", "String p = \"(p.maker_id IS NULL OR p.maker_id IN (?))\";",
                SQL_NULL_OWNER, hits);
        collect("sample", "return scope.seeAll() || ownerEmployeeId == null\n || x;",
                JAVA_NULL_OWNER_SHORT_CIRCUIT, hits);
        collect("sample", "return ownerId == null || scope.visibleOwners().contains(ownerId);",
                JAVA_NULL_OWNER_SHORT_CIRCUIT, hits);
        // 以下都不是读范围旁路：按旧工号补姓名的联表、失败关闭的归属校验。
        collect("sample", "OR (t.maker_id IS NULL\n AND em_mk.legacy_id=t.maker_legacy_id)",
                SQL_NULL_OWNER, hits);
        collect("sample", "if (ownerUser == null || ownerEmployee == null || !ownerUser.equals(me))",
                JAVA_NULL_OWNER_SHORT_CIRCUIT, hits);
        assertThat(hits).hasSize(3);
    }

    private static void collect(String file, String source, Pattern pattern, List<String> sink) {
        Matcher matcher = pattern.matcher(source);
        while (matcher.find()) {
            int line = 1;
            for (int index = 0; index < matcher.start(); index++) {
                if (source.charAt(index) == '\n') {
                    line++;
                }
            }
            sink.add(file + ":" + line + " -> " + matcher.group().strip());
        }
    }
}
