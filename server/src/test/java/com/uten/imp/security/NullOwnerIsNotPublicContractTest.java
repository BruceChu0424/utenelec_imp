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
 *       {@code ... IS NULL AND xx.legacy_id = ...} 联表除外，那是显示姓名不是读范围)；
 *       对整族做 {@code NOT EXISTS} 拒绝检查的必要空归属分支，按完整布尔结构证明后保留；</li>
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

    private static final Pattern TEXT_BLOCK = Pattern.compile("(?s)\"\"\"(.*?)\"\"\"");
    private static final Pattern SQL_NON_CODE = Pattern.compile(
            "(?s)'(?:''|[^'])*'|\"(?:\"\"|[^\"])*\"|--[^\\r\\n]*|/\\*.*?\\*/");
    private static final Pattern OWNER_EXCLUSION = Pattern.compile(
            "(?is)([\\w.]+\\b(?:maker_id|owner_employee_id)|maker_id|owner_employee_id)"
                    + "\\s+IS\\s+NULL\\s+OR\\s+\\1\\s+NOT\\s+IN\\s*\\(\\s*:\\w+\\s*\\)");
    private static final Pattern ANTI_JOIN_GUARD = Pattern.compile(
            "(?i)\\bAND\\s*\\(\\s*:\\w+\\s+OR\\s+NOT\\s+EXISTS\\s*\\(");

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

    @Test
    void aRequiredAntiJoinRejectsNullOwnersInsteadOfMakingThemPublic() {
        for (String predicate : List.of(
                "plan.maker_id IS NULL OR plan.maker_id NOT IN (:owners)",
                "owner_report.status IN (0, 1) AND (owner_report.maker_id IS NULL"
                        + " OR owner_report.maker_id NOT IN (:owners))")) {
            assertThat(sqlHits(guardedQuery(predicate))).isEmpty();
        }
    }

    @Test
    void negatedOptionalOrChangedExclusionsStillFailTheGuard() {
        String safe = guardedQuery("plan.maker_id IS NULL OR plan.maker_id NOT IN (:owners)");
        for (String unsafe : List.of(
                safe.replace("NOT EXISTS", "EXISTS"),
                safe.replace("NOT EXISTS", "NOT NOT EXISTS"),
                safe.replace("AND (:seeAll", "AND NOT (:seeAll"),
                safe.replace("WHERE doc.status=1", "WHERE NOT (doc.status=1")
                        .replace("ORDER BY", ") ORDER BY"),
                safe.replace("WHERE plan.maker_id", "WHERE NOT (plan.maker_id")
                        .replace(":owners)))", ":owners))))"),
                safe.replace("IS NULL OR", "IS NULL AND"),
                safe.replace("plan.maker_id NOT IN", "plan.maker_id IN"),
                safe.replace("plan.maker_id NOT IN", "other.maker_id NOT IN"),
                safe.replace("AND (:seeAll", "OR (:seeAll"),
                safe.replace("WHERE doc.status=1", "WHERE doc.status=1 OR doc.id IS NOT NULL"),
                safe.replace("ORDER BY", "= FALSE ORDER BY"))) {
            assertThat(sqlHits(unsafe)).as("仍须拒绝: %s", unsafe).hasSize(1);
        }
    }

    @Test
    void anApprovedAntiJoinDoesNotExemptAnotherNullOwnerInTheSameQuery() {
        String query = guardedQuery("plan.maker_id IS NULL OR plan.maker_id NOT IN (:owners)")
                .replace("ORDER BY", "AND (doc.maker_id IS NULL OR doc.maker_id IN (:owners)) ORDER BY");
        assertThat(sqlHits(query)).singleElement().asString().contains("maker_id IS NULL");
    }

    private static String guardedQuery(String predicate) {
        return "SELECT doc.id FROM documents doc WHERE doc.status=1 "
                + "AND (:seeAll OR NOT EXISTS (SELECT 1 FROM plans plan WHERE " + predicate + ")) "
                + "ORDER BY doc.id";
    }

    private static List<String> sqlHits(String sql) {
        List<String> hits = new ArrayList<>();
        collect("sample", "String sql = \"\"\"\n" + sql + "\n\"\"\";", SQL_NULL_OWNER, hits);
        return hits;
    }

    private static void collect(String file, String source, Pattern pattern, List<String> sink) {
        Matcher matcher = pattern.matcher(source);
        while (matcher.find()) {
            if (pattern == SQL_NULL_OWNER && isRequiredOwnerExclusion(source, matcher.start())) {
                continue;
            }
            int line = 1;
            for (int index = 0; index < matcher.start(); index++) {
                if (source.charAt(index) == '\n') {
                    line++;
                }
            }
            sink.add(file + ":" + line + " -> " + matcher.group().strip());
        }
    }

    /**
     * Recognise only a top-level AND (:bypass OR NOT EXISTS (... WHERE rejection)).
     * The null-owner branch must be a required positive conjunct of the rejection,
     * paired with NOT IN for the same column. Unknown SQL shapes keep failing closed;
     * a containing NOT EXISTS, file name or comment alone is never an exemption.
     */
    private static boolean isRequiredOwnerExclusion(String source, int ownerOffset) {
        Matcher blocks = TEXT_BLOCK.matcher(source);
        while (blocks.find()) {
            if (ownerOffset < blocks.start(1) || ownerOffset >= blocks.end(1)) continue;
            String sql = maskNonCode(blocks.group(1));
            int localOwner = ownerOffset - blocks.start(1);
            int outerWhere = topLevelKeyword(sql, "WHERE", 0);
            if (outerWhere < 0 || topLevelKeyword(sql, "OR", outerWhere) >= 0) return false;
            Matcher guards = ANTI_JOIN_GUARD.matcher(sql);
            while (guards.find()) {
                if (guards.start() < outerWhere || depthAt(sql, guards.start()) != 0) continue;
                int queryOpen = guards.end() - 1;
                int queryClose = closingParenthesis(sql, queryOpen);
                if (localOwner <= queryOpen || localOwner >= queryClose) continue;
                int guardClose = skipWhitespace(sql, queryClose + 1);
                if (guardClose >= sql.length() || sql.charAt(guardClose) != ')') continue;
                String following = sql.substring(guardClose + 1).stripLeading();
                if (!following.matches("(?is)(?:AND\\b.*|ORDER\\s+BY\\b.*|GROUP\\s+BY\\b.*"
                        + "|LIMIT\\b.*|OFFSET\\b.*|FETCH\\b.*|)")) continue;
                String subquery = sql.substring(queryOpen + 1, queryClose);
                if (!subquery.stripLeading().matches("(?is)SELECT\\s+1\\s+FROM\\b.*")) continue;
                int where = topLevelKeyword(subquery, "WHERE", 0);
                if (where >= 0 && requiredRejection(subquery.substring(where + 5),
                        localOwner - queryOpen - 1 - where - 5)) return true;
            }
        }
        return false;
    }

    private static boolean requiredRejection(String expression, int ownerOffset) {
        int start = skipWhitespace(expression, 0);
        String trimmed = expression.substring(start).stripTrailing();
        int owner = ownerOffset - start;
        if (owner < 0 || owner >= trimmed.length()) return false;
        if (trimmed.charAt(0) == '(' && closingParenthesis(trimmed, 0) == trimmed.length() - 1) {
            return requiredRejection(trimmed.substring(1, trimmed.length() - 1), owner - 1);
        }
        if (OWNER_EXCLUSION.matcher(trimmed).matches()) return true;
        if (topLevelKeyword(trimmed, "OR", 0) >= 0) return false;
        int previous = 0;
        for (int and = topLevelKeyword(trimmed, "AND", 0); and >= 0;
                and = topLevelKeyword(trimmed, "AND", previous)) {
            if (owner < and) return requiredRejection(trimmed.substring(previous, and), owner - previous);
            previous = and + 3;
        }
        return previous > 0 && requiredRejection(trimmed.substring(previous), owner - previous);
    }

    private static String maskNonCode(String sql) {
        StringBuilder masked = new StringBuilder(sql);
        Matcher literals = SQL_NON_CODE.matcher(sql);
        while (literals.find()) {
            for (int index = literals.start(); index < literals.end(); index++) masked.setCharAt(index, ' ');
        }
        return masked.toString();
    }

    private static int topLevelKeyword(String sql, String keyword, int from) {
        Matcher words = Pattern.compile("(?i)\\b" + keyword + "\\b").matcher(sql);
        while (words.find()) {
            if (words.start() >= from && depthAt(sql, words.start()) == 0) return words.start();
        }
        return -1;
    }

    private static int depthAt(String sql, int end) {
        int depth = 0;
        for (int index = 0; index < end; index++) {
            if (sql.charAt(index) == '(') depth++;
            if (sql.charAt(index) == ')') depth--;
        }
        return depth;
    }

    private static int closingParenthesis(String sql, int open) {
        int depth = 0;
        for (int index = open; index < sql.length(); index++) {
            if (sql.charAt(index) == '(') depth++;
            if (sql.charAt(index) == ')' && --depth == 0) return index;
        }
        return -1;
    }

    private static int skipWhitespace(String value, int from) {
        int index = from;
        while (index < value.length() && Character.isWhitespace(value.charAt(index))) index++;
        return index;
    }
}
