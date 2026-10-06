package com.uten.imp.common;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Deque;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.fail;

/**
 * Guards the whole "SQL glued together at a concatenation boundary" bug family in production code.
 *
 * <p>The scanner is a small Java lexer (comments, char/string literals with escapes, text blocks whose
 * value is computed exactly like javac: {@code raw.stripIndent().translateEscapes()}) plus a token-level
 * analysis of every concatenation boundary ({@code +}, {@code +=}, {@code .append(..).append(..)},
 * consecutive {@code sb.append(..);} statements, join delimiters) and of every {@code .formatted(..)} /
 * {@code String.format(..)} / {@code .replace(..)} call.
 *
 * <ul>
 *   <li>R1 a text block followed by {@code +} whose value ends with a token char (text blocks strip
 *       trailing whitespace) while the right operand does not start with whitespace/separator.</li>
 *   <li>R2 {@code +} followed by a text block whose value starts with a token char (incidental
 *       indentation is stripped) while the left operand does not end with whitespace/separator.</li>
 *   <li>R3 plain {@code "..."} SQL literal that ends with a token char before a dynamic operand, or starts
 *       with an SQL keyword after a dynamic operand (also across {@code sb.append(..)} calls and
 *       {@code +=}); and SQL join delimiters ({@code String.join / Collectors.joining / StringJoiner})
 *       without surrounding spaces. "SQL literal" = contains an upper-case SQL keyword delimited by
 *       non-word chars ('-' counts as a word char, so codes like "PREPLAN-MAKE-IN:" are not SQL). With
 *       that gate R3 has no false positives on log/exception messages here, so it is not further
 *       restricted to createNativeQuery/jdbc call sites.</li>
 *   <li>R4 operator precedence: only the LAST literal of a {@code +} chain receives {@code .formatted(..)}
 *       / {@code .replace(..)}; an earlier operand (literal or constant) containing a format specifier /
 *       the placeholder stays verbatim in the SQL.</li>
 *   <li>R5 a formatted literal (directly or through a constant/local) containing a {@code %} that is not a
 *       valid {@link java.util.Formatter} specifier (e.g. {@code LIKE 'A%'}) throws at runtime.</li>
 * </ul>
 *
 * <p>Boundary chars: token chars are {@code [\p{L}\p{N}$?]} and quotes that close a complete quoted
 * value; whitespace and punctuation separate SQL tokens (so {@code IN (""" + inList() + """\n)} is safe).
 * Intentional composition points also count as separators: ':' (named parameter / cast prefix), '_'
 * (identifier affix), a quote that opens/closes a quoted region (the dynamic part lands inside '...'
 * or "..."), and a numeric suffix index on the right ({@code ":goods" + i}).
 *
 * <p>Dynamic operands are resolved before judging, over-approximating every value they can take:
 * locals (definitions textually before the use in the same body, including {@code +=}), fields and
 * {@code Type.CONSTANT} across files, String-returning helper methods (all {@code return}s, overloads),
 * StringBuilders (start = constructor argument or any first append; tail = any final append, unknown
 * when the builder is handed to another method), switch expressions, ternaries, parameters of private /
 * static methods (the argument at every visible call site; unknown when referenced as {@code ::name})
 * and accessors of private records (the argument of every {@code new Record(..)}). Anything that cannot
 * be resolved is treated as able to start/end with a token char.
 *
 * <p>Allowlist only provably intentional joins, with file + snippet + reason (see {@link #ALLOWLIST}).
 */
class NativeSqlTextBlockWhitespaceContractTest {

    // ------------------------------------------------------------------------------------------------
    // Allowlist: only provably intentional joins. file suffix + snippet (must occur on the reported line)
    // ------------------------------------------------------------------------------------------------
    private record Allow(String fileSuffix, String snippet, String reason) {
    }

    private static final List<Allow> ALLOWLIST = List.of(
            new Allow("features/finance/report/FinanceReportService.java",
                    "having + (having.isEmpty() ? \"WHERE\" : \" AND\")",
                    "correlated ternary: \"WHERE\" is only chosen when having is empty (nothing to glue to), "
                            + "otherwise \" AND\" carries its own leading space"));

    private static final Map<String, String> RULE_HINTS = new LinkedHashMap<>();

    static {
        RULE_HINTS.put("R1", "R1: Java text blocks strip trailing whitespace on every line, so '...AND \"\"\" + x' "
                + "glues 'ANDx'. Use one text block with %s and .formatted(x), or move the keyword into a plain "
                + "string with explicit spaces (\"\"\" + \" ORDER BY \" + x), or put \"\"\" on its own line.");
        RULE_HINTS.put("R2", "R2: a text block's value starts right after the opening line with indentation "
                + "stripped, so 'x + \"\"\"\\n  ORDER BY' glues 'xORDER BY'. Inject x via %s/.formatted(x) or "
                + "add an explicit separator (+ \"\\n\" + \"\"\"...).");
        RULE_HINTS.put("R3", "R3: plain SQL string joined without a space ('... AND' + x, x + \"AND ...\", "
                + "sb.append(\"AND x\"), String.join(\"AND\", ..)). Add the space inside the literal.");
        RULE_HINTS.put("R4", "R4: in 'A + B + C.formatted(x)' only C is formatted; A keeps its %s/{X} "
                + "literally. Use one literal with placeholders and pass fragments as format arguments, or "
                + "parenthesize the whole chain.");
        RULE_HINTS.put("R5", "R5: '%' in a formatted literal must be a valid java.util.Formatter specifier; "
                + "write '%%' for a literal percent (e.g. LIKE 'A%%') or bind it as a parameter.");
    }

    // ------------------------------------------------------------------------------------------------
    // Production scan, one test per rule
    // ------------------------------------------------------------------------------------------------

    @Test
    void sqlKeywordsDoNotRelyOnTextBlockTrailingWhitespace() {
        assertNoProductionViolations("R1");
    }

    @Test
    void r2TextBlockStartMustNotGlueToPrecedingOperand() {
        assertNoProductionViolations("R2");
    }

    @Test
    void r3PlainSqlLiteralJoinsNeedExplicitSeparator() {
        assertNoProductionViolations("R3");
    }

    @Test
    void r4FormattedOrReplacedMustCoverEveryPlaceholderOperand() {
        assertNoProductionViolations("R4");
    }

    @Test
    void r5FormattedLiteralsContainOnlyValidFormatSpecifiers() {
        assertNoProductionViolations("R5");
    }

    @Test
    void allowlistEntriesAreStillUsed() {
        List<String> stale = new ArrayList<>();
        for (Allow allow : ALLOWLIST) {
            boolean used = rawProductionViolations().stream().anyMatch(v -> matches(allow, v));
            if (!used) {
                stale.add(allow.fileSuffix() + " :: " + allow.snippet());
            }
        }
        assertThat(stale).as("allowlist entries that no longer match anything; delete them").isEmpty();
    }

    private static void assertNoProductionViolations(String rule) {
        List<String> hits = productionViolations().stream()
                .filter(v -> v.rule().equals(rule))
                .map(Violation::render)
                .toList();
        if (!hits.isEmpty()) {
            fail(RULE_HINTS.get(rule) + "\n" + hits.size() + " violation(s):\n" + String.join("\n", hits));
        }
    }

    private static List<Violation> cachedRaw;

    private static synchronized List<Violation> rawProductionViolations() {
        if (cachedRaw == null) {
            Path root = sourceRoot();
            Index index = new Index();
            List<Scanner> scanners = new ArrayList<>();
            try (Stream<Path> files = Files.walk(root)) {
                files.filter(p -> p.toString().endsWith(".java")).sorted().forEach(p -> {
                    String rel = root.relativize(p).toString().replace('\\', '/');
                    scanners.add(index.add(new Scanner(rel, read(p), index)));
                });
            } catch (IOException error) {
                throw new UncheckedIOException(error);
            }
            List<Violation> all = new ArrayList<>();
            scanners.forEach(s -> all.addAll(s.run()));
            cachedRaw = List.copyOf(all);
        }
        return cachedRaw;
    }

    private static List<Violation> productionViolations() {
        return rawProductionViolations().stream()
                .filter(v -> ALLOWLIST.stream().noneMatch(a -> matches(a, v)))
                .toList();
    }

    private static boolean matches(Allow allow, Violation v) {
        return v.file().endsWith(allow.fileSuffix()) && v.lineText().contains(allow.snippet());
    }

    // ------------------------------------------------------------------------------------------------
    // Self checks: each rule fires on a bad sample and stays silent on good samples
    // ------------------------------------------------------------------------------------------------

    @Test
    void lexerComputesTextBlockValueLikeJavac() {
        String src = """
                String a = \"""
                        SELECT 1
                          FROM t   \\
                        WHERE a = 1 AND\\s\""";
                String b = \"""
                    x
                    \""";
                String c = "q\\"\\n" + 'x';
                """;
        List<Tok> toks = lex(src);
        List<String> values = toks.stream().filter(Tok::lit).map(Tok::value).toList();
        String expectedA = """
                SELECT 1
                  FROM t   \
                WHERE a = 1 AND\s""";
        String expectedB = """
            x
            """;
        assertThat(values).containsExactly(expectedA, expectedB, "q\"\n", "x");
        assertThat(expectedA).isEqualTo("SELECT 1\n  FROM t   WHERE a = 1 AND ");
    }

    @Test
    void r1SelfCheck() {
        assertThat(fired("""
                String sql = \"""
                        SELECT o.id FROM orders o
                        WHERE o.is_deleted = FALSE AND \""" + " " + scope.predicate();
                """)).as("keyword before \"\"\" + ' '").isEmpty();
        assertThat(fired("""
                String sql = \"""
                        SELECT o.id FROM orders o
                        WHERE o.is_deleted = FALSE AND \""" + scope.predicate();
                """)).containsExactly("R1");
        assertThat(fired("""
                String q = \"""
                    SELECT * FROM t ORDER BY \""" + col;
                """)).containsExactly("R1");
        assertThat(fired("""
                String q = \"""
                    SELECT * FROM t WHERE a = ?\""" + "AND b = 1";
                """)).containsExactly("R1");
        assertThat(fired("""
                String q = \"""
                    SELECT * FROM t WHERE a = 1 \\
                    AND b = 2 AND\""" + x;
                """)).as("\\<newline> joins lines").containsExactly("R1");
        // good samples
        assertThat(fired("""
                String q = \"""
                    SELECT * FROM t
                    WHERE a = 1
                    \""" + x;
                """)).as("closing delimiter on its own line -> value ends with \\n").isEmpty();
        assertThat(fired("""
                String q = \"""
                    SELECT * FROM t\""" + " ORDER BY " + x + " LIMIT :l";
                """)).isEmpty();
        assertThat(fired("""
                String q = \"""
                    SELECT * FROM t o WHERE o.is_deleted = FALSE AND %s
                    \""".formatted(p);
                """)).isEmpty();
        assertThat(fired("""
                String q = \"""
                    SELECT * FROM t WHERE id IN (\""" + inList() + \"""
                    )
                    ORDER BY id
                    \""";
                """)).as("( and ) separate tokens").isEmpty();
        assertThat(fired("""
                String q = \"""
                    SELECT * FROM t WHERE a = 1 AND\\s\""" + x;
                """)).as("\\s escape keeps the trailing space").isEmpty();
        assertThat(fired("""
                String q = \"""
                    SELECT * FROM t WHERE a = 1\""".formatted(x) + (flag ? " AND b" : "");
                """)).isEmpty();
    }

    @Test
    void r2SelfCheck() {
        assertThat(fired("""
                String q = where + \"""
                    ORDER BY id
                    \""";
                """)).containsExactly("R2");
        assertThat(fired("""
                String q = "SELECT * FROM t WHERE a = ?" + \"""
                    ORDER BY id
                    \""";
                """)).containsExactly("R2");
        assertThat(fired("""
                String q = base + (flag ? " AND x = 1" : " AND false") + \"""
                    ORDER BY id
                    \""";
                """)).containsExactly("R2");
        // good samples
        assertThat(fired("""
                String q = "SELECT * FROM t WHERE a = ?\\n" + \"""
                    ORDER BY id
                    \""";
                """)).isEmpty();
        assertThat(fired("""
                String q = where + "\\n" + \"""
                    ORDER BY id
                    \""";
                """)).isEmpty();
        assertThat(fired("""
                String q = \"""
                    SELECT 1
                    \""" + \"""
                    UNION ALL SELECT 2
                    \""";
                """)).isEmpty();
    }

    @Test
    void r3SelfCheck() {
        assertThat(fired("""
                String q = "SELECT * FROM t WHERE a = 1 AND" + cond;
                """)).containsExactly("R3");
        assertThat(fired("""
                String q = base + "AND b = 2";
                """)).containsExactly("R3");
        assertThat(fired("""
                q += "AND b = 2";
                """)).containsExactly("R3");
        assertThat(fired("""
                sql.append(" WHERE a = ?").append("AND b = ?");
                """)).containsExactly("R3");
        assertThat(fired("""
                void m() {
                    StringBuilder sb = new StringBuilder("SELECT * FROM t WHERE 1 = 1");
                    if (x) {
                        sb.append("AND x = 1");
                    }
                }
                """)).containsExactly("R3");
        assertThat(fired("""
                String w = String.join("AND", parts);
                String v = parts.stream().collect(Collectors.joining(" OR"));
                """)).containsExactly("R3", "R3");
        // good samples
        assertThat(fired("""
                String c = "o." + column;
                String q = "SELECT * FROM " + table + " WHERE id = :id";
                log.info("Order " + id + " not found");
                String w = String.join(" AND ", parts);
                StringBuilder sb = new StringBuilder(64).append("SELECT 1");
                sb.append(" WHERE a = ?").append(" AND b = ?");
                String r = "x IN (" + list + ")";
                """)).isEmpty();
        assertThat(fired("""
                void a() { StringBuilder sql = new StringBuilder("SELECT 1 FROM t WHERE x = 1"); }
                void b(StringBuilder sql) { sql.append("AND y = 2"); }
                """)).as("builder state does not leak across method bodies").isEmpty();
    }

    @Test
    void r4SelfCheck() {
        assertThat(fired("""
                String q = \"""
                    SELECT %1$s FROM t
                    \""" + FRAG + "\\n" + \"""
                    WHERE x = %1$s
                    \""".formatted(col);
                """)).containsExactly("R4");
        assertThat(fired("""
                String q = "SELECT {COLS} FROM t " + FRAG + " WHERE {COLS} IS NOT NULL".replace("{COLS}", c);
                """)).containsExactly("R4");
        // good samples
        assertThat(fired("""
                String q = \"""
                    SELECT %1$s FROM t %2$s
                    WHERE x = %1$s
                    \""".formatted(col, FRAG);
                """)).isEmpty();
        assertThat(fired("""
                String q = ("SELECT %s FROM t " + FRAG + " WHERE %s").formatted(a, b);
                String r = "SELECT * FROM t\\n" + FRAG + " WHERE x = %s".formatted(a);
                """)).isEmpty();
    }

    @Test
    void r5SelfCheck() {
        assertThat(fired("""
                String q = \"""
                    SELECT * FROM t WHERE code LIKE 'A%' AND id = %s
                    \""".formatted(id);
                """)).containsExactly("R5");
        assertThat(fired("""
                String m = String.format("rate 100%", x);
                """)).containsExactly("R5");
        // good samples
        assertThat(fired("""
                String q = \"""
                    SELECT %1$s, '%%' FROM t WHERE a = %2$d%n
                    \""".formatted(x, y);
                String m = String.format("%-10s|%05d|%.2f|%,d|%tY", a, b, c, d, e);
                String n = String.format(Locale.ROOT, "%.2f%%", v);
                String o = "LIKE 'A%'" + x;
                """)).isEmpty();
    }

    @Test
    void resolutionSelfCheck() {
        // constants
        assertThat(fired("""
                static final String W = " WHERE a = 1";
                String q = W + \"""
                    ORDER BY id
                    \""";
                """)).as("constant ending in a token char").containsExactly("R2");
        assertThat(fired("""
                static final String CTE = \"""
                    WITH x AS (SELECT 1)
                    \""";
                String q = CTE + \"""
                    SELECT * FROM x
                    \""";
                """)).as("constant text block ending in \\n").isEmpty();
        // locals with flow order, += and builders
        assertThat(fired("""
                String m() {
                    String where = "";
                    where += \"""
                        AND a = 1
                        \""";
                    return "SELECT 1 FROM t WHERE TRUE\\n" + where;
                }
                """)).isEmpty();
        assertThat(fired("""
                String m() {
                    StringBuilder sb = new StringBuilder();
                    sb.append("AND x = 1");
                    return "SELECT 1 FROM t WHERE TRUE" + sb;
                }
                """)).containsExactly("R3");
        assertThat(fired("""
                String m() {
                    StringBuilder sb = new StringBuilder();
                    sb.append(" AND x = 1").append('\\n');
                    return "SELECT 1 FROM t WHERE TRUE" + sb + "ORDER BY 1";
                }
                """)).isEmpty();
        // parameters resolved through every call site of a private method
        assertThat(fired("""
                private static String q(String order) { return "SELECT * FROM t" + order; }
                void a() { q(" ORDER BY id"); q(""); }
                """)).isEmpty();
        assertThat(fired("""
                private static String q(String order) { return "SELECT * FROM t" + order; }
                void a() { q(" ORDER BY id"); q("ORDER BY x"); }
                """)).containsExactly("R3");
        assertThat(fired("""
                public String q(String order) { return "SELECT * FROM t" + order; }
                void a() { q(" ORDER BY id"); }
                """)).as("public instance method: callers unknown").containsExactly("R3");
        // private record accessors
        assertThat(fired("""
                private record F(String sql, int n) {}
                F f() { return new F(" AND a = 1", 1); }
                String q(F f) { return "SELECT 1 FROM t WHERE TRUE" + f.sql(); }
                """)).isEmpty();
        assertThat(fired("""
                private record F(String sql, int n) {}
                F f() { return new F("AND a = 1", 1); }
                String q(F f) { return "SELECT 1 FROM t WHERE TRUE" + f.sql(); }
                """)).containsExactly("R3");
        // switch expressions
        assertThat(fired("""
                String q(String s) {
                    String o = switch (s) { case "a" -> " ORDER BY a"; default -> "ORDER BY b"; };
                    return "SELECT * FROM t" + o;
                }
                """)).containsExactly("R3");
        // quotes, parameter names, identifier affixes
        assertThat(fired("""
                String a = " WHERE kind = '" + kind + "' AND x = 1";
                String b = " AND parent_table='" + parentTable + "'";
                String c = "' AND parent_table='" + parentTable + "'";
                String d = "CAST(:goods" + i + " AS uuid)";
                String e = " IN (:" + name + ")";
                String f = "SELECT public.refresh_" + viewName + "()";
                """)).isEmpty();
        assertThat(fired("""
                String a = " AND r.adj_kind = 'RESIDUAL'" + period;
                """)).as("closed quote then glue").containsExactly("R3");
        // R4 / R5 through constants
        assertThat(fired("""
                static final String HEAD = "SELECT %s FROM t ";
                String q = HEAD + "WHERE x = %s".formatted(a);
                """)).containsExactly("R4");
        assertThat(fired("""
                static final String SQL = "SELECT * FROM t WHERE code LIKE 'A%' AND id = %s";
                String q = SQL.formatted(id);
                """)).containsExactly("R5");
    }

    private static List<String> fired(String source) {
        return scan("Fixture.java", source).stream().map(Violation::rule).toList();
    }

    // ------------------------------------------------------------------------------------------------
    // Lexer
    // ------------------------------------------------------------------------------------------------

    private enum K { STR, TB, CHR, ID, NUM, P, EOF }

    private record Tok(K k, String text, String value, int line, int start, int end) {
        boolean is(String p) {
            return k == K.P && text.equals(p);
        }

        boolean id(String name) {
            return k == K.ID && text.equals(name);
        }

        boolean lit() {
            return k == K.STR || k == K.TB || k == K.CHR;
        }
    }

    static List<Tok> lex(String src) {
        List<Tok> out = new ArrayList<>();
        int n = src.length();
        int i = 0;
        int line = 1;
        while (i < n) {
            char c = src.charAt(i);
            if (c == '\n') {
                line++;
                i++;
                continue;
            }
            if (Character.isWhitespace(c) || c == '\uFEFF') {
                i++;
                continue;
            }
            if (c == '/' && i + 1 < n && src.charAt(i + 1) == '/') {
                while (i < n && src.charAt(i) != '\n') {
                    i++;
                }
                continue;
            }
            if (c == '/' && i + 1 < n && src.charAt(i + 1) == '*') {
                int e = src.indexOf("*/", i + 2);
                e = e < 0 ? n : e + 2;
                line += newlines(src, i, e);
                i = e;
                continue;
            }
            int startLine = line;
            if (src.startsWith("\"\"\"", i)) {
                int j = i + 3;
                while (j < n && src.charAt(j) != '\n' && src.charAt(j) != '\r') {
                    j++;
                }
                if (j < n && src.charAt(j) == '\r') {
                    j++;
                }
                if (j < n && src.charAt(j) == '\n') {
                    j++;
                }
                int contentStart = j;
                while (j < n && !src.startsWith("\"\"\"", j)) {
                    j += src.charAt(j) == '\\' ? 2 : 1;
                }
                int contentEnd = Math.min(j, n);
                int e = Math.min(contentEnd + 3, n);
                String raw = src.substring(contentStart, contentEnd).replace("\r\n", "\n").replace('\r', '\n');
                out.add(new Tok(K.TB, src.substring(i, e), unescape(raw.stripIndent()), startLine, i, e));
                line += newlines(src, i, e);
                i = e;
                continue;
            }
            if (c == '"' || c == '\'') {
                int j = i + 1;
                while (j < n && src.charAt(j) != c && src.charAt(j) != '\n') {
                    j += src.charAt(j) == '\\' ? 2 : 1;
                }
                int e = Math.min(j + 1, n);
                String raw = src.substring(i + 1, Math.min(j, n));
                out.add(new Tok(c == '"' ? K.STR : K.CHR, src.substring(i, e), unescape(raw), startLine, i, e));
                i = e;
                continue;
            }
            if (Character.isJavaIdentifierStart(c)) {
                int j = i + 1;
                while (j < n && Character.isJavaIdentifierPart(src.charAt(j))) {
                    j++;
                }
                out.add(new Tok(K.ID, src.substring(i, j), null, startLine, i, j));
                i = j;
                continue;
            }
            if (Character.isDigit(c)) {
                int j = i + 1;
                while (j < n && (Character.isLetterOrDigit(src.charAt(j)) || src.charAt(j) == '_'
                        || (src.charAt(j) == '.' && j + 1 < n && Character.isDigit(src.charAt(j + 1))))) {
                    j++;
                }
                out.add(new Tok(K.NUM, src.substring(i, j), null, startLine, i, j));
                i = j;
                continue;
            }
            String p = String.valueOf(c);
            if (i + 1 < n) {
                String two = src.substring(i, i + 2);
                if (two.equals("++") || two.equals("+=") || two.equals("->") || two.equals("::")) {
                    p = two;
                }
            }
            out.add(new Tok(K.P, p, null, startLine, i, i + p.length()));
            i += p.length();
        }
        return out;
    }

    private static String unescape(String raw) {
        try {
            return raw.translateEscapes();
        } catch (IllegalArgumentException error) {
            return raw;
        }
    }

    private static int newlines(String s, int from, int to) {
        int count = 0;
        for (int k = from; k < to && k < s.length(); k++) {
            if (s.charAt(k) == '\n') {
                count++;
            }
        }
        return count;
    }

    // ------------------------------------------------------------------------------------------------
    // Analysis
    // ------------------------------------------------------------------------------------------------

    record Violation(String rule, String file, int line, String detail, String lineText) {
        String render() {
            return file + ":" + line + " " + rule + " " + detail;
        }
    }

    private enum Edge { SEP, TOKEN, UNKNOWN }

    /** What one side of a join point looks like at the boundary. */
    private record Side(Edge edge, boolean textBlock, boolean plain, boolean plainSql, boolean startsKw,
                        String value, String display, List<String> alts) {
    }

    private static final String SQL_KW = "SELECT|FROM|WHERE|AND|OR|JOIN|ON|GROUP|ORDER|BY|LIMIT|OFFSET|HAVING|UNION"
            + "|SET|VALUES|INTO|RETURNING|CASE|WHEN|THEN|ELSE|END|IN|NOT|EXISTS|AS|DISTINCT";
    /** '-' counts as a word char so business codes like "PREPLAN-MAKE-IN:" are not SQL. */
    private static final Pattern SQL_KEYWORD = Pattern.compile(
            "(?<![A-Za-z0-9_\\-])(?:" + SQL_KW + ")(?![A-Za-z0-9_\\-])");
    private static final Pattern SQL_KEYWORD_START = Pattern.compile("(?:" + SQL_KW + ")(?![A-Za-z0-9_\\-])");
    /** Right operands that append a numeric suffix to a parameter/identifier name (":goods" + i). */
    private static final Pattern INDEX_LIKE = Pattern.compile(
            "\\(?\\s*(?:[ijkn]|idx|index|ordinal|seq|\\w*(?:Index|Idx|Ordinal))(?:\\s*[-+]\\s*\\d+)?\\s*\\)?");
    private static final String SPEC = "%(?:\\d+\\$|<)?[-#+ 0,(]*\\d*(?:\\.\\d+)?"
            + "(?:[bBhHsScCdoxXeEfgGaA%n]|[tT][HIklMSLNpzZsQBbhAaCYyjmdeRTrDFc])";
    private static final Pattern VALID_SPEC = Pattern.compile(SPEC);
    private static final Pattern ENDS_WITH_SPEC = Pattern.compile("(?s).*?(" + SPEC + ")$");
    /** Placeholders that would be substituted by .formatted(); no space flag, so LIKE '% a' is not one. */
    private static final Pattern FORMAT_PLACEHOLDER = Pattern.compile(
            "%(?:\\d+\\$)?[-#+0,(]*\\d*(?:\\.\\d+)?[sSdfxXcbB]");
    private static final Set<String> NON_METHOD_KEYWORDS = Set.of("if", "for", "while", "switch", "catch",
            "synchronized", "return", "throw", "case", "yield", "assert", "else", "do", "try", "new");
    private static final Set<String> CONTROL_KEYWORDS = Set.of("if", "for", "while", "switch", "catch",
            "synchronized", "try");

    static List<Violation> scan(String file, String src) {
        Index index = new Index();
        return index.add(new Scanner(file, src, index)).run();
    }

    /** Cross-file lookup of {@code Type.CONSTANT} and {@code Type.method(..)} by simple class name. */
    private static final class Index {
        private final Map<String, Scanner> byClass = new HashMap<>();
        private final Set<String> ambiguous = new HashSet<>();
        private final Set<String> resolving = new HashSet<>();
        /** Memo of resolved ranges: "file#start#end#first" -> side. */
        private final Map<String, Side> memo = new HashMap<>();

        Scanner add(Scanner scanner) {
            String name = scanner.className;
            if (byClass.containsKey(name)) {
                ambiguous.add(name);
            }
            byClass.put(name, scanner);
            return scanner;
        }

        Scanner of(String className) {
            return ambiguous.contains(className) ? null : byClass.get(className);
        }

        private Map<String, List<CallSite>> calls;

        /** Every {@code name(..)} / {@code Qualifier.name(..)} call in the scanned sources. */
        List<CallSite> callsOf(String name) {
            if (calls == null) {
                calls = new HashMap<>();
                for (Scanner sc : byClass.values()) {
                    sc.collectCalls(calls);
                }
            }
            return calls.getOrDefault(name, List.of());
        }
    }

    /** A call site: scanner, '(' index, qualifier text ("" when unqualified, "this" for this.m()). */
    private record CallSite(Scanner scanner, int open, String qualifier) {
    }

    /** A source range [start, end] in a given scanner. */
    private record Ref(Scanner scanner, int start, int end) {
    }

    private static boolean tokenChar(char c) {
        return Character.isLetterOrDigit(c) || "_$?:'\"".indexOf(c) >= 0;
    }

    private static final class Scanner {
        private final String file;
        private final String src;
        private final String[] lines;
        private final List<Tok> t;
        private final int[] match;
        private final List<Violation> out = new ArrayList<>();
        private final Tok eof = new Tok(K.EOF, "", null, 0, 0, 0);
        private final Index index;
        final String className;
        /** {@code NAME = expr} definitions (possible start of NAME's value). */
        private final Map<String, List<Def>> assigned = new HashMap<>();
        /** {@code NAME += expr} definitions (possible tail of NAME's value). */
        private final Map<String, List<Def>> appended = new HashMap<>();
        /** String-returning method name -> return expression ranges. */
        private final Map<String, List<int[]>> returns = new HashMap<>();
        /** Method/constructor bodies with their parameter names. */
        private final List<Body> bodies = new ArrayList<>();
        /** Lambda / for / catch variable positions: values unknown. */
        private final Map<String, List<Integer>> binders = new HashMap<>();
        /** {@code NAME.append(a).append(b)} arguments of each statement-level append chain. */
        private final Map<String, List<BuilderArg>> builderAppends = new HashMap<>();
        /** Positions where NAME is passed as a call argument (a builder may be mutated there). */
        private final Map<String, List<Integer>> passedAsArgument = new HashMap<>();
        /** Records declared in this file and the '(' of every {@code new Name(..)}. */
        private final Map<String, RecordInfo> records = new HashMap<>();
        private final Map<String, List<Integer>> newSites = new HashMap<>();
        private int[] braceDepth;

        Scanner(String file, String src, Index index) {
            this.index = index;
            String base = file.substring(file.lastIndexOf('/') + 1);
            this.className = base.endsWith(".java") ? base.substring(0, base.length() - 5) : base;
            this.file = file;
            this.src = src;
            this.lines = src.split("\r?\n", -1);
            this.t = lex(src);
            this.match = new int[t.size()];
            java.util.Arrays.fill(match, -1);
            Deque<Integer> stack = new ArrayDeque<>();
            for (int i = 0; i < t.size(); i++) {
                Tok tok = t.get(i);
                if (tok.is("(") || tok.is("[") || tok.is("{")) {
                    stack.push(i);
                } else if (tok.is(")") || tok.is("]") || tok.is("}")) {
                    if (!stack.isEmpty()) {
                        int o = stack.pop();
                        match[o] = i;
                        match[i] = o;
                    }
                }
            }
            braceDepth = new int[t.size()];
            int depth = 0;
            for (int i = 0; i < t.size(); i++) {
                if (t.get(i).is("}")) {
                    depth--;
                }
                braceDepth[i] = depth;
                if (t.get(i).is("{")) {
                    depth++;
                }
            }
            collectDeclarations();
        }

        void collectCalls(Map<String, List<CallSite>> into) {
            for (int i = 1; i < t.size(); i++) {
                Tok x = t.get(i);
                if (x.k() == K.ID && tok(i - 1).is("::")) {
                    // Type::name passes arguments we cannot see
                    into.computeIfAbsent(x.text(), k -> new ArrayList<>()).add(new CallSite(this, -1, tok(i - 2).text()));
                    continue;
                }
                if (x.k() != K.ID || !tok(i + 1).is("(") || match[i + 1] < 0 || NON_METHOD_KEYWORDS.contains(x.text())
                        || tok(i - 1).id("new")) {
                    continue;
                }
                Tok before = tok(i - 1);
                boolean declaration = (before.k() == K.ID && !before.id("return")) || before.is(">") || before.is("]");
                if (declaration) {
                    continue;
                }
                String qualifier = before.is(".") ? tok(i - 2).text() : "";
                into.computeIfAbsent(x.text(), k -> new ArrayList<>()).add(new CallSite(this, i + 1, qualifier));
            }
        }

        /** Argument ranges of the call whose '(' is at {@code open}. */
        private List<int[]> arguments(int open) {
            List<int[]> args = new ArrayList<>();
            int close = match[open];
            if (close <= open + 1) {
                return args;
            }
            int a = open + 1;
            while (a < close) {
                int end = topLevelComma(a, close - 1);
                args.add(new int[] {a, end});
                a = end + 2;
            }
            return args;
        }

        // ------------------------- declarations for constant/method resolution -------------------------

        private void collectDeclarations() {
            for (int i = 0; i < t.size(); i++) {
                Tok x = t.get(i);
                if (x.k() == K.ID && tok(i + 1).is("=") && !tok(i + 2).is("=") && !tok(i - 1).is(".")
                        && !tok(i - 1).is("!") && !tok(i - 1).is("<") && !tok(i - 1).is(">")) {
                    Tok before = tok(i - 1);
                    boolean decl = before.k() == K.ID && !before.id("return") || before.is(">") || before.is("]");
                    assigned.computeIfAbsent(x.text(), k -> new ArrayList<>())
                            .add(new Def(i + 2, expressionEnd(i + 2), i, decl, false));
                } else if (x.id("this") && tok(i + 1).is(".") && tok(i + 2).k() == K.ID && tok(i + 3).is("=")
                        && !tok(i + 4).is("=")) {
                    assigned.computeIfAbsent(tok(i + 2).text(), k -> new ArrayList<>())
                            .add(new Def(i + 4, expressionEnd(i + 4), i + 2, false, true));
                } else if (x.k() == K.ID && tok(i + 1).is("+=")) {
                    appended.computeIfAbsent(x.text(), k -> new ArrayList<>())
                            .add(new Def(i + 2, expressionEnd(i + 2), i, false, tok(i - 2).id("this")));
                } else if (x.is("(") && match[i] > i) {
                    collectParameters(i);
                }
                if (x.k() == K.ID && tok(i + 1).is(".") && tok(i + 2).id("append") && tok(i + 3).is("(")
                        && match[i + 3] > i + 3 && !tok(i - 1).is(".")) {
                    List<int[]> args = new ArrayList<>();
                    int open = i + 3;
                    while (true) {
                        int close = match[open];
                        args.add(new int[] {open + 1, close - 1});
                        if (tok(close + 1).is(".") && tok(close + 2).id("append") && tok(close + 3).is("(")
                                && match[close + 3] > close + 3) {
                            open = close + 3;
                        } else {
                            break;
                        }
                    }
                    // an earlier argument can only end the value if every later one may be empty
                    boolean[] tail = new boolean[args.size()];
                    for (int k = args.size() - 1; k >= 0; k--) {
                        tail[k] = true;
                        int[] r = args.get(k);
                        if (r[0] == r[1] && tok(r[0]).lit() && !tok(r[0]).value().isEmpty()) {
                            break;
                        }
                    }
                    for (int k = 0; k < args.size(); k++) {
                        builderAppends.computeIfAbsent(x.text(), key -> new ArrayList<>())
                                .add(new BuilderArg(args.get(k)[0], args.get(k)[1], i, k == 0, tail[k]));
                    }
                }
                if (x.id("new") && tok(i + 1).k() == K.ID && tok(i + 2).is("(") && match[i + 2] > i) {
                    newSites.computeIfAbsent(tok(i + 1).text(), k -> new ArrayList<>()).add(i + 2);
                }
                if (x.k() == K.ID && (tok(i - 1).is("(") || tok(i - 1).is(","))
                        && (tok(i + 1).is(")") || tok(i + 1).is(",")) && !enclosingCall(i).equals("append")) {
                    passedAsArgument.computeIfAbsent(x.text(), k -> new ArrayList<>()).add(i);
                }
                if (x.is("->") && tok(i - 1).k() == K.ID) {
                    binders.computeIfAbsent(tok(i - 1).text(), k -> new ArrayList<>()).add(i - 1);
                }
            }
        }

        /** Name of the method whose argument list encloses token {@code i}, or "". */
        private String enclosingCall(int i) {
            int depth = 0;
            for (int k = i - 1; k >= 0; k--) {
                Tok x = tok(k);
                if (x.is(")") || x.is("]") || x.is("}")) {
                    depth++;
                } else if (x.is("(") || x.is("[") || x.is("{")) {
                    if (depth == 0) {
                        return x.is("(") && tok(k - 1).k() == K.ID ? tok(k - 1).text() : "";
                    }
                    depth--;
                }
            }
            return "";
        }

        private boolean isBuilderCtor(int s) {
            return tok(s).id("new") && (tok(s + 1).id("StringBuilder") || tok(s + 1).id("StringBuffer"))
                    && tok(s + 2).is("(") && match[s + 2] > s;
        }

        private void collectParameters(int open) {
            int close = match[open];
            Tok name = tok(open - 1);
            Tok before = tok(open - 2);
            boolean declaration = name.k() == K.ID && !NON_METHOD_KEYWORDS.contains(name.text())
                    && ((before.k() == K.ID && !before.id("new") && !before.id("return")) || before.is(">")
                    || before.is("]"))
                    && (tok(close + 1).is("{") || tok(close + 1).id("throws") || tok(close + 1).is(";"));
            boolean lambda = tok(close + 1).is("->");
            boolean control = name.id("catch") || name.id("for");
            if (!(declaration || lambda || control)) {
                return;
            }
            Set<String> params = new HashSet<>();
            List<String> paramList = new ArrayList<>();
            int angle = 0;
            for (int k = open + 1; k < close; k++) {
                if (tok(k).is("(") && match[k] > k) {
                    k = match[k];
                    continue;
                }
                if (tok(k).is("<")) {
                    angle++;
                } else if (tok(k).is(">")) {
                    angle--;
                }
                if (angle == 0 && tok(k).k() == K.ID && (tok(k + 1).is(",") || tok(k + 1).is(")") || tok(k + 1).is(":")
                        || tok(k + 1).is("="))) {
                    params.add(tok(k).text());
                    paramList.add(tok(k).text());
                    if (!declaration) {
                        binders.computeIfAbsent(tok(k).text(), key -> new ArrayList<>()).add(k);
                    }
                }
            }
            if (!declaration) {
                return;
            }
            Set<String> modifiers = new HashSet<>();
            for (int k = open - 2; k >= 0 && k > open - 20; k--) {
                Tok m = tok(k);
                if (m.is(";") || m.is("{") || m.is("}")) {
                    break;
                }
                if (m.k() == K.ID) {
                    modifiers.add(m.text());
                }
            }
            if (before.id("record")) {
                records.put(name.text(), new RecordInfo(paramList, modifiers.contains("private")));
            }
            int body = close + 1;
            while (body < t.size() && !tok(body).is("{") && !tok(body).is(";")) {
                body++;
            }
            if (tok(body).is("{") && match[body] > body) {
                bodies.add(new Body(body, match[body], params, paramList, name.text(),
                        modifiers.contains("private"), modifiers.contains("static"), braceDepth[open - 1] <= 1));
                if (before.id("String") || before.id("StringBuilder") || before.id("StringBuffer")) {
                    List<int[]> list = returns.computeIfAbsent(name.text(), k -> new ArrayList<>());
                    collectReturns(body + 1, match[body] - 1, list);
                }
            }
        }

        private void collectReturns(int a, int b, List<int[]> list) {
            for (int k = a; k <= b; k++) {
                if (tok(k).is("{") && tok(k - 1).is("->") && match[k] > k) {
                    k = match[k]; // lambda body
                } else if (tok(k).id("return") && !tok(k + 1).is(";")) {
                    list.add(new int[] {k + 1, expressionEnd(k + 1)});
                }
            }
        }

        /** Last token index of the expression starting at {@code a} (stops at top-level ; , ) } ]). */
        private int expressionEnd(int a) {
            int k = a;
            while (k < t.size()) {
                Tok x = tok(k);
                if ((x.is("(") || x.is("[") || x.is("{")) && match[k] > k) {
                    k = match[k] + 1;
                    continue;
                }
                if (x.is(";") || x.is(",") || x.is(")") || x.is("}") || x.is("]")) {
                    break;
                }
                k++;
            }
            return k - 1;
        }

        /** Resolve an operand [a, b] that is a local/field/constant or a String helper method, or null. */
        private Side resolveOperand(int a, int b, boolean first) {
            if (index == null) {
                return null;
            }
            Scanner owner = this;
            String name;
            boolean method = false;
            boolean fieldOnly = false;
            if (a == b && tok(a).k() == K.ID) {
                if (tok(a).id("null")) {
                    return sep("null");
                }
                name = tok(a).text();
            } else if (b >= a + 2 && tok(b - 1).is(".") && tok(b).k() == K.ID && isQualifier(a, b - 2)) {
                owner = tok(b - 2).id("this") ? this : index.of(tok(b - 2).text());
                name = tok(b).text();
                fieldOnly = true;
            } else if (tok(b).is(")") && match[b] == b - 1 && tok(b - 2).id("toString") && tok(b - 3).is(".")
                    && b - 4 >= a) {
                return resolveOperand(a, b - 4, first);
            } else if (b == a + 4 && tok(a).k() == K.ID && tok(a + 1).is(".") && tok(a + 2).k() == K.ID
                    && tok(a + 3).is("(") && tok(b).is(")") && !isQualifier(a, a)) {
                List<Ref> refs = recordComponent(tok(a + 2).text());
                return refs == null ? null : resolveRefs(refs, first, text(a, b));
            } else if (tok(b).is(")") && match[b] > 0 && tok(match[b] - 1).k() == K.ID) {
                int nameIdx = match[b] - 1;
                if (nameIdx == a) {
                    owner = this;
                } else if (nameIdx >= a + 2 && tok(nameIdx - 1).is(".") && isQualifier(a, nameIdx - 2)) {
                    owner = tok(nameIdx - 2).id("this") ? this : index.of(tok(nameIdx - 2).text());
                } else {
                    return null;
                }
                name = tok(nameIdx).text();
                method = true;
            } else {
                return null;
            }
            if (owner == null) {
                return null;
            }
            Scanner sc = owner;
            List<Ref> refs = method
                    ? owner.returns.getOrDefault(name, List.of()).stream().map(r -> new Ref(sc, r[0], r[1])).toList()
                    : owner.definitions(name, first, fieldOnly || owner != this ? -1 : a);
            if (refs == null) {
                return null;
            }
            return resolveRefs(refs, first, text(a, b));
        }

        /** {@code x.comp()} on a private record of this file: the matching argument of every construction. */
        private List<Ref> recordComponent(String component) {
            List<Ref> refs = new ArrayList<>();
            boolean found = false;
            for (Map.Entry<String, RecordInfo> e : records.entrySet()) {
                int pos = e.getValue().components().indexOf(component);
                if (pos < 0) {
                    continue;
                }
                if (!e.getValue().isPrivate()) {
                    return null;
                }
                found = true;
                for (int open : newSites.getOrDefault(e.getKey(), List.of())) {
                    List<int[]> args = arguments(open);
                    if (args.size() != e.getValue().components().size()) {
                        return null;
                    }
                    refs.add(new Ref(this, args.get(pos)[0], args.get(pos)[1]));
                }
            }
            return found && !refs.isEmpty() ? refs : null;
        }

        /** Values a parameter receives: the matching argument of every call site we can see. */
        private List<Ref> parameterArguments(Body body, String name) {
            int pos = body.paramList().indexOf(name);
            if (pos < 0 || !body.topLevel() || !(body.isPrivate() || body.isStatic())) {
                return null; // instance methods visible elsewhere can be called with anything
            }
            List<Ref> refs = new ArrayList<>();
            for (CallSite call : index.callsOf(body.name())) {
                if (call.open() < 0) {
                    if (call.qualifier().equals(className) || call.qualifier().equals("this")) {
                        return null;
                    }
                    continue;
                }
                boolean sameFile = call.scanner() == this;
                boolean visible = sameFile ? (call.qualifier().isEmpty() || call.qualifier().equals("this")
                        || call.qualifier().equals(className))
                        : !body.isPrivate() && call.qualifier().equals(className);
                if (!visible) {
                    continue;
                }
                List<int[]> args = call.scanner().arguments(call.open());
                if (args.size() != body.paramList().size()) {
                    continue; // another overload
                }
                refs.add(new Ref(call.scanner(), args.get(pos)[0], args.get(pos)[1]));
            }
            return refs.isEmpty() ? null : refs;
        }

        /** [a, b] is {@code this} or a (package-qualified) type name such as {@code com.x.Type}. */
        private boolean isQualifier(int a, int b) {
            if (a == b && tok(a).id("this")) {
                return true;
            }
            for (int k = a; k <= b; k++) {
                boolean idSlot = (k - a) % 2 == 0;
                if (idSlot ? tok(k).k() != K.ID : !tok(k).is(".")) {
                    return false;
                }
            }
            return (b - a) % 2 == 0 && Character.isUpperCase(tok(b).text().charAt(0));
        }

        /**
         * Possible value ranges of variable {@code name} used at token {@code at} (-1 = field access).
         * Locals: definitions inside the enclosing body; fields: definitions outside bodies, via this.x,
         * or in bodies that do not declare a local of that name. Null when the value is unknowable
         * (parameter, lambda/for/catch variable, builder tail).
         */
        private List<Ref> definitions(String name, boolean first, int at) {
            Body body = null;
            if (at >= 0) {
                for (Body b : bodies) {
                    if (b.contains(at) && (body == null || b.open() > body.open())) {
                        body = b;
                    }
                }
            }
            List<Def> all = new ArrayList<>(assigned.getOrDefault(name, List.of()));
            if (!first) {
                all.addAll(appended.getOrDefault(name, List.of()));
            }
            List<Def> chosen = new ArrayList<>();
            if (body != null) {
                Body scope = body;
                if (binders.getOrDefault(name, List.of()).stream().anyMatch(scope::contains)) {
                    return null;
                }
                if (scope.params().contains(name)) {
                    boolean reassigned = all.stream().anyMatch(d -> scope.contains(d.at()));
                    return reassigned ? null : parameterArguments(scope, name);
                }
                boolean local = all.stream().anyMatch(d -> d.decl() && !d.viaThis() && scope.contains(d.at()));
                if (local) {
                    // flow approximation: only definitions textually before the use site
                    all.stream().filter(d -> !d.viaThis() && scope.contains(d.at()) && d.at() < at)
                            .forEach(chosen::add);
                    if (chosen.isEmpty()) {
                        return null;
                    }
                    return localBuilderAware(name, first, at, scope, chosen);
                }
            }
            if (chosen.isEmpty()) {
                for (Def d : all) {
                    Body owner = innermost(d.at());
                    boolean ownerDeclaresLocal = owner != null && !d.viaThis() && (owner.params().contains(name)
                            || all.stream().anyMatch(o -> o.decl() && owner.contains(o.at())
                            && innermost(o.at()) == owner));
                    if (!ownerDeclaresLocal) {
                        chosen.add(d);
                    }
                }
            }
            if (chosen.isEmpty()) {
                return null;
            }
            if (!first && chosen.stream().anyMatch(d -> tok(d.start()).id("new"))) {
                return null; // a builder's tail depends on appends (possibly in helper methods)
            }
            return chosen.stream().map(d -> new Ref(this, d.start(), d.end())).toList();
        }

        /**
         * Local variable ranges; when the variable is a StringBuilder its start is the constructor argument
         * (or, for an empty builder, any statement's first append) and its tail is any append argument.
         */
        private List<Ref> localBuilderAware(String name, boolean first, int at, Body scope, List<Def> chosen) {
            List<BuilderArg> appends = builderAppends.getOrDefault(name, List.of()).stream()
                    .filter(d -> scope.contains(d.at()) && d.at() < at).toList();
            boolean builder = !appends.isEmpty() || chosen.stream().anyMatch(d -> isBuilderCtor(d.start()));
            List<int[]> ranges = new ArrayList<>();
            if (!builder) {
                return chosen.stream().map(d -> new Ref(this, d.start(), d.end())).toList();
            }
            boolean escapes = passedAsArgument.getOrDefault(name, List.of()).stream().anyMatch(scope::contains);
            boolean needFirstAppend = false;
            for (Def d : chosen) {
                if (isBuilderCtor(d.start())) {
                    int open = d.start() + 2;
                    int close = match[open];
                    if (close > open + 1 && tok(open + 1).k() != K.NUM) {
                        ranges.add(new int[] {open + 1, close - 1});
                    } else if (first) {
                        needFirstAppend = true;
                    }
                } else {
                    ranges.add(new int[] {d.start(), d.end()});
                }
            }
            if ((!first || needFirstAppend) && escapes) {
                return null; // mutated by a helper we do not follow
            }
            if (!first) {
                appends.stream().filter(BuilderArg::tail).forEach(d -> ranges.add(new int[] {d.start(), d.end()}));
            } else if (needFirstAppend) {
                List<BuilderArg> heads = appends.stream().filter(BuilderArg::head).toList();
                if (heads.isEmpty()) {
                    return null;
                }
                heads.forEach(d -> ranges.add(new int[] {d.start(), d.end()}));
            }
            return ranges.isEmpty() ? null : ranges.stream().map(r -> new Ref(this, r[0], r[1])).toList();
        }

        private Body innermost(int at) {
            Body found = null;
            for (Body b : bodies) {
                if (b.contains(at) && (found == null || b.open() > found.open())) {
                    found = b;
                }
            }
            return found;
        }

        private Side resolveRefs(List<Ref> refs, boolean first, String disp) {
            if (refs.isEmpty() || index.resolving.size() > 12) {
                return null;
            }
            Side result = null;
            for (Ref r : refs) {
                if (r.end() < r.start()) {
                    return null;
                }
                String key = r.scanner().file + "#" + r.start() + "#" + r.end() + "#" + first;
                Side s = index.memo.get(key);
                if (s == null) {
                    if (!index.resolving.add(key)) {
                        continue; // recursive reference (e.g. overload delegating to itself): no new information
                    }
                    try {
                        s = first ? r.scanner().exprFirst(r.start(), r.end()) : r.scanner().exprLast(r.start(), r.end());
                    } finally {
                        index.resolving.remove(key);
                    }
                    index.memo.put(key, s);
                }
                result = result == null ? s : combine(result, s, disp);
            }
            if (result == null || result.edge() == Edge.UNKNOWN) {
                return null;
            }
            String shown = compact(disp) + "{" + result.display() + "}";
            return new Side(result.edge(), result.textBlock(), result.plain(), result.plainSql(),
                    result.startsKw(), result.value(), shown, result.alts());
        }

        /** Result expressions of a switch expression whose body braces are [open, close]. */
        private List<int[]> switchResults(int open, int close) {
            List<int[]> results = new ArrayList<>();
            for (int k = open + 1; k < close; k++) {
                Tok x = tok(k);
                if ((x.is("(") || x.is("[")) && match[k] > k) {
                    k = match[k];
                } else if (x.is("->")) {
                    if (tok(k + 1).is("{") && match[k + 1] > k) {
                        int end = match[k + 1];
                        for (int y = k + 2; y < end; y++) {
                            if (tok(y).id("yield")) {
                                results.add(new int[] {y + 1, expressionEnd(y + 1)});
                            }
                        }
                        k = end;
                    } else if (!tok(k + 1).id("throw")) {
                        results.add(new int[] {k + 1, expressionEnd(k + 1)});
                    }
                } else if (x.id("yield")) {
                    results.add(new int[] {k + 1, expressionEnd(k + 1)});
                }
            }
            return results;
        }

        private Side switchSide(int switchIdx, boolean first) {
            int open = match[switchIdx + 1] + 1;
            if (!tok(open).is("{") || match[open] < open) {
                return null;
            }
            List<int[]> results = switchResults(open, match[open]);
            if (results.isEmpty()) {
                return null;
            }
            Side combined = null;
            String disp = "switch(" + text(switchIdx + 2, match[switchIdx + 1] - 1) + ")";
            for (int[] r : results) {
                Side s = first ? exprFirst(r[0], r[1]) : exprLast(r[0], r[1]);
                combined = combined == null ? s : combine(combined, s, disp);
            }
            return combined;
        }

        Tok tok(int i) {
            return i >= 0 && i < t.size() ? t.get(i) : eof;
        }

        /** One assignment: value range [start, end], name token at {@code at}, decl = local declaration. */
        private record Def(int start, int end, int at, boolean decl, boolean viaThis) {
        }

        /** head = first append of a chain (can start the value); tail = can end the value. */
        private record BuilderArg(int start, int end, int at, boolean head, boolean tail) {
        }

        /** Method/constructor body with its ordered parameters and enough modifiers to find callers. */
        private record Body(int open, int close, Set<String> params, List<String> paramList, String name,
                            boolean isPrivate, boolean isStatic, boolean topLevel) {
            boolean contains(int i) {
                return i > open && i < close;
            }
        }

        private record RecordInfo(List<String> components, boolean isPrivate) {
        }

        List<Violation> run() {
            Map<String, Side> builderTail = new HashMap<>();
            for (int i = 0; i < t.size(); i++) {
                Tok cur = t.get(i);
                if (cur.is("{") && isMethodBodyStart(i)) {
                    builderTail.clear();
                }
                if (cur.is("+")) {
                    plusBoundary(i);
                } else if (cur.is("+=")) {
                    Side left = resolvedOrUnknown(operandStart(i - 1), i - 1);
                    check(left, exprFirst(i + 1, expressionEnd(i + 1)), cur.line(), " += ");
                } else if (cur.is(".") && tok(i + 1).id("append") && tok(i + 2).is("(") && match[i + 2] > 0) {
                    appendBoundary(i, builderTail);
                } else if (cur.k() == K.ID && tok(i + 1).is("=") && tok(i + 2).id("new")
                        && (tok(i + 3).id("StringBuilder") || tok(i + 3).id("StringBuffer")) && tok(i + 4).is("(")
                        && match[i + 4] > 0) {
                    builderTail.put(cur.text(), ctorSide(i + 4));
                } else if (cur.k() == K.ID && tok(i + 1).is(".") && tok(i + 2).id("setLength")) {
                    builderTail.put(cur.text(), sep("<empty builder>"));
                }
                if (cur.lit() && tok(i + 1).is(".") && tok(i + 3).is("(")
                        && (tok(i + 2).id("formatted") || tok(i + 2).id("replace"))) {
                    precedence(i);
                }
                if (cur.is(".") && tok(i + 1).id("formatted") && tok(i + 2).is("(")) {
                    formattedReceiver(i);
                }
                if (cur.id("String") && tok(i + 1).is(".") && tok(i + 2).id("format") && tok(i + 3).is("(")) {
                    stringFormat(i + 3);
                }
                joinDelimiter(i);
            }
            return out;
        }

        // ------------------------- boundaries -------------------------

        private void plusBoundary(int i) {
            Tok prev = tok(i - 1);
            if (!(prev.lit() || prev.k() == K.ID || prev.k() == K.NUM || prev.is(")") || prev.is("]"))) {
                return; // unary plus
            }
            check(lastSide(i - 1), firstSide(i + 1), t.get(i).line(), " + ");
        }

        private void appendBoundary(int dot, Map<String, Side> builderTail) {
            int open = dot + 2;
            int close = match[open];
            Side right = close > open + 1 ? exprFirst(open + 1, close - 1) : sep("<nothing>");
            Side left = null;
            Tok prev = tok(dot - 1);
            if (prev.is(")") && match[dot - 1] >= 0) {
                int o = match[dot - 1];
                if (tok(o - 1).id("append") && tok(o - 2).is(".")) {
                    left = o + 1 <= dot - 2 ? exprLast(o + 1, dot - 2) : sep("<nothing>");
                } else if ((tok(o - 1).id("StringBuilder") || tok(o - 1).id("StringBuffer")) && tok(o - 2).id("new")) {
                    left = ctorSide(o);
                }
            } else if (prev.k() == K.ID && isStatementStart(dot - 2)) {
                left = builderTail.get(prev.text());
            }
            if (left != null) {
                check(left, right, t.get(dot).line(), " .append ");
            }
            String owner = chainRootVariable(dot);
            if (owner != null && !(tok(close + 1).is(".") && tok(close + 2).id("append"))) {
                builderTail.put(owner, close > open + 1 ? exprLast(open + 1, close - 1) : sep("<nothing>"));
            }
        }

        /** Variable that owns an {@code x.append(..).append(..)} chain, or null. */
        private String chainRootVariable(int dot) {
            int k = dot;
            while (tok(k - 1).is(")") && match[k - 1] >= 0) {
                int o = match[k - 1];
                if (tok(o - 1).id("append") && tok(o - 2).is(".")) {
                    k = o - 2;
                    continue;
                }
                if ((tok(o - 1).id("StringBuilder") || tok(o - 1).id("StringBuffer")) && tok(o - 2).id("new")
                        && tok(o - 3).is("=") && tok(o - 4).k() == K.ID) {
                    return tok(o - 4).text();
                }
                return null;
            }
            if (tok(k - 1).k() == K.ID && isStatementStart(k - 2)) {
                return tok(k - 1).text();
            }
            return null;
        }

        private boolean isStatementStart(int i) {
            Tok p = tok(i);
            return p.is(";") || p.is("{") || p.is("}") || p.is(")") || p.is("->") || p.id("else");
        }

        private Side ctorSide(int open) {
            int close = match[open];
            if (close == open + 1 || tok(open + 1).k() == K.NUM) {
                return sep("<empty builder>");
            }
            return exprLast(open + 1, close - 1);
        }

        private boolean isMethodBodyStart(int brace) {
            int k = brace - 1;
            int w = k;
            while (tok(w).k() == K.ID || tok(w).is(".") || tok(w).is(",")) {
                if (tok(w).id("throws")) {
                    k = w - 1;
                    break;
                }
                w--;
            }
            if (!tok(k).is(")") || match[k] < 0) {
                return false;
            }
            int o = match[k];
            Tok name = tok(o - 1);
            Tok before = tok(o - 2);
            return name.k() == K.ID && !CONTROL_KEYWORDS.contains(name.text()) && !NON_METHOD_KEYWORDS.contains(name.text())
                    && ((before.k() == K.ID && !before.id("new")) || before.is(">") || before.is("]"));
        }

        private void check(Side l, Side r, int line, String joiner) {
            String debug = System.getProperty("nsql.debug", "");
            if (!debug.isEmpty() && java.util.Arrays.stream(debug.split(",")).anyMatch(d -> (file + ":" + line).endsWith(d))) {
                System.out.println("DEBUG " + file + ":" + line + " L=" + l.edge() + " " + l.display() + joiner
                        + "R=" + r.edge() + " " + r.display());
            }
            String rule = null;
            if (l.textBlock() && l.edge() == Edge.TOKEN && r.edge() != Edge.SEP) {
                rule = "R1";
            } else if (r.textBlock() && r.edge() == Edge.TOKEN && l.edge() != Edge.SEP) {
                rule = "R2";
            } else if (l.plainSql() && l.edge() == Edge.TOKEN && r.edge() != Edge.SEP) {
                rule = "R3";
            } else if (r.plainSql() && r.startsKw() && l.edge() != Edge.SEP) {
                rule = "R3";
            }
            if (rule != null && r.edge() == Edge.UNKNOWN && INDEX_LIKE.matcher(r.display()).matches()) {
                rule = null; // ":goods" + i builds a numbered parameter name
            }
            if (rule != null) {
                report(rule, line, "boundary=" + l.display() + joiner + r.display());
            }
        }

        private void report(String rule, int line, String detail) {
            String lineText = line >= 1 && line <= lines.length ? lines[line - 1] : "";
            out.add(new Violation(rule, file, line, detail, lineText));
        }

        // ------------------------- operand sides -------------------------

        private Side firstSide(int s) {
            Tok tk = tok(s);
            Side base;
            int after;
            if (tk.lit()) {
                base = litSide(tk, true);
                after = s;
            } else if (tk.is("(") && match[s] > s) {
                int c = match[s];
                if (isCast(s, c)) {
                    return firstSide(c + 1);
                }
                base = c > s + 1 ? exprFirst(s + 1, c - 1) : unknown("()");
                base = withDisplay(base, text(s, c));
                after = c;
            } else if (tk.id("new") && (tok(s + 1).id("StringBuilder") || tok(s + 1).id("StringBuffer"))
                    && tok(s + 2).is("(") && match[s + 2] > s) {
                int close = match[s + 2];
                // a builder's value starts with its constructor argument; appends only change the tail
                return close > s + 3 && tok(s + 3).k() != K.NUM ? exprFirst(s + 3, close - 1)
                        : unknown(text(s, operandEnd(s)));
            } else if (tk.id("switch") && tok(s + 1).is("(") && match[s + 1] > s) {
                Side sw = switchSide(s, true);
                return sw != null ? sw : unknown(text(s, operandEnd(s)));
            } else {
                int prim = primaryEnd(s);
                int end = operandEnd(s);
                Side resolved = prim >= s ? resolveOperand(s, prim, true) : null;
                after = prim;
                if (resolved == null) {
                    resolved = resolveOperand(s, end, true); // e.g. record accessor filter.where()
                    after = end;
                }
                if (resolved == null) {
                    return unknown(text(s, end));
                }
                base = resolved;
            }
            return postfix(base, after, true);
        }

        private Side lastSide(int e) {
            Tok tk = tok(e);
            if (tk.lit()) {
                return litSide(tk, false);
            }
            if (tk.is(")") && match[e] >= 0) {
                int o = match[e];
                Tok name = tok(o - 1);
                if (name.k() == K.ID && !NON_METHOD_KEYWORDS.contains(name.text())) {
                    if (tok(o - 2).is(".")) {
                        Side recv = lastSide(o - 3);
                        if (recv.alts() != null) {
                            return method(recv, name.text(), o, false);
                        }
                    }
                    return resolvedOrUnknown(operandStart(e), e);
                }
                Side inner = e > o + 1 ? exprLast(o + 1, e - 1) : unknown("()");
                return withDisplay(inner, text(o, e));
            }
            if (tk.is("}") && match[e] >= 0 && tok(match[e] - 1).is(")") && match[match[e] - 1] >= 0
                    && tok(match[match[e] - 1] - 1).id("switch")) {
                Side sw = switchSide(match[match[e] - 1] - 1, false);
                if (sw != null) {
                    return sw;
                }
            }
            return resolvedOrUnknown(operandStart(e), e);
        }

        /** End of a resolvable primary at s: NAME, Type.NAME, a.b.Type.NAME, name(..), Type.name(..). */
        private int primaryEnd(int s) {
            if (tok(s).k() != K.ID) {
                return -1;
            }
            if (tok(s + 1).is("(") && match[s + 1] > s) {
                return match[s + 1];
            }
            int k = s;
            while (tok(k + 1).is(".") && tok(k + 2).k() == K.ID && !tok(k + 3).is("(")) {
                k += 2;
            }
            if (tok(k + 1).is(".") && tok(k + 2).k() == K.ID && tok(k + 3).is("(") && match[k + 3] > k
                    && isQualifier(s, k)) {
                return match[k + 3];
            }
            return k;
        }

        private Side resolvedOrUnknown(int a, int b) {
            Side resolved = resolveOperand(a, b, false);
            return resolved != null ? resolved : unknown(text(a, b));
        }

        private Side postfix(Side base, int after, boolean first) {
            int k = after + 1;
            Side cur = base;
            while (tok(k).is(".") && tok(k + 1).k() == K.ID && tok(k + 2).is("(") && match[k + 2] > 0) {
                if (cur.alts() == null) {
                    return unknown(cur.display() + "." + tok(k + 1).text() + "(..)");
                }
                cur = method(cur, tok(k + 1).text(), k + 2, first);
                k = match[k + 2] + 1;
            }
            if (tok(k).is(".") || tok(k).is("[")) {
                return unknown(cur.display() + "...");
            }
            return cur;
        }

        private Side method(Side base, String m, int open, boolean first) {
            if (base.value() == null) {
                Side result = null;
                for (String alt : base.alts()) {
                    Side one = method(side(alt, base.textBlock(), base.plain(), first, base.display()), m, open, first);
                    result = result == null ? one : combine(result, one, base.display() + "." + m + "(..)");
                }
                return result == null ? unknown(base.display()) : withDisplay(result, base.display() + "." + m + "(..)");
            }
            String v = base.value();
            String disp = base.display() + "." + m + "(..)";
            switch (m) {
                case "formatted" -> {
                    if (first) {
                        Matcher mm = VALID_SPEC.matcher(v);
                        if (v.startsWith("%") && mm.lookingAt()) {
                            if (mm.group().equals("%n")) {
                                v = "\n" + v.substring(2);
                            } else {
                                return unknown(disp);
                            }
                        }
                    } else {
                        Matcher mm = ENDS_WITH_SPEC.matcher(v);
                        if (mm.matches()) {
                            if (mm.group(1).equals("%n")) {
                                v = v.substring(0, v.length() - 2) + "\n";
                            } else if (!mm.group(1).equals("%%")) {
                                return unknown(disp);
                            }
                        }
                    }
                }
                case "replace" -> {
                    Tok target = tok(open + 1);
                    if (!target.lit() || target.value().isEmpty()) {
                        return unknown(disp);
                    }
                    if (first ? v.startsWith(target.value()) : v.endsWith(target.value())) {
                        return unknown(disp);
                    }
                }
                case "substring" -> {
                    if (first || match[open] < 0 || topLevelComma(open + 1, match[open] - 1) != match[open] - 1) {
                        return unknown(disp); // substring(begin) keeps the tail; anything else is unknown
                    }
                }
                case "strip", "trim" -> v = v.strip();
                case "stripLeading" -> v = v.stripLeading();
                case "stripTrailing" -> v = v.stripTrailing();
                case "stripIndent" -> v = v.stripIndent();
                case "toUpperCase", "toLowerCase", "intern", "toString" -> {
                }
                default -> {
                    return unknown(disp);
                }
            }
            return side(v, base.textBlock(), base.plain(), first, disp);
        }

        private boolean isCast(int open, int close) {
            if (close <= open + 1) {
                return false;
            }
            for (int k = open + 1; k < close; k++) {
                Tok x = tok(k);
                if (!(x.k() == K.ID || x.is(".") || x.is("<") || x.is(">") || x.is(",") || x.is("?")
                        || x.is("[") || x.is("]"))) {
                    return false;
                }
            }
            Tok first = tok(open + 1);
            Tok next = tok(close + 1);
            boolean typeLike = first.k() == K.ID
                    && (Character.isUpperCase(first.text().charAt(0)) || Set.of("int", "long", "double", "float",
                    "char", "short", "byte", "boolean").contains(first.text()));
            return typeLike && (next.lit() || next.k() == K.ID || next.k() == K.NUM || next.is("("));
        }

        private Side exprFirst(int a, int b) {
            int[] qc = ternary(a, b);
            if (qc != null) {
                return combine(exprFirst(qc[0] + 1, qc[1] - 1), exprFirst(qc[1] + 1, b), text(a, b));
            }
            return firstSide(a);
        }

        private Side exprLast(int a, int b) {
            int[] qc = ternary(a, b);
            if (qc != null) {
                return combine(exprLast(qc[0] + 1, qc[1] - 1), exprLast(qc[1] + 1, b), text(a, b));
            }
            return lastSide(b);
        }

        /** Top-level '?' and its ':' inside [a, b], or null. */
        private int[] ternary(int a, int b) {
            int q = -1;
            int depth = 0;
            for (int k = a; k <= b; k++) {
                Tok x = tok(k);
                if ((x.is("(") || x.is("[") || x.is("{")) && match[k] > k) {
                    k = match[k];
                    continue;
                }
                if (x.is("?") && !(tok(k - 1).is("<") || tok(k - 1).is(","))) {
                    if (q < 0) {
                        q = k;
                    }
                    depth++;
                } else if (x.is(":") && q >= 0) {
                    depth--;
                    if (depth == 0) {
                        return new int[] {q, k};
                    }
                }
            }
            return null;
        }

        private Side combine(Side x, Side y, String disp) {
            Edge edge = x.edge() == Edge.UNKNOWN || y.edge() == Edge.UNKNOWN ? Edge.UNKNOWN
                    : x.edge() == Edge.TOKEN || y.edge() == Edge.TOKEN ? Edge.TOKEN : Edge.SEP;
            boolean tb = (x.textBlock() && x.edge() != Edge.SEP) || (y.textBlock() && y.edge() != Edge.SEP);
            boolean sql = (x.plainSql() && x.edge() != Edge.SEP) || (y.plainSql() && y.edge() != Edge.SEP);
            boolean kw = (x.plainSql() && x.startsKw()) || (y.plainSql() && y.startsKw());
            List<String> alts = x.alts() != null && y.alts() != null
                    ? Stream.concat(x.alts().stream(), y.alts().stream()).toList() : null;
            return new Side(edge, tb, false, sql, kw, null, "(" + compact(disp) + ")", alts);
        }

        private Side litSide(Tok tk, boolean first) {
            String disp = first ? "'|" + head(tk.value()) + "'" : "'" + tail(tk.value()) + "|'";
            return side(tk.value(), tk.k() == K.TB, tk.k() == K.STR, first, disp);
        }

        private Side side(String v, boolean tb, boolean plain, boolean first, String disp) {
            Edge edge = v.isEmpty() ? Edge.SEP : edgeOf(v, first ? v.charAt(0) : v.charAt(v.length() - 1), first);
            boolean sql = plain && SQL_KEYWORD.matcher(v).find();
            boolean kw = SQL_KEYWORD_START.matcher(v).lookingAt();
            return new Side(edge, tb, plain, sql, kw, v, disp, List.of(v));
        }

        /**
         * Boundary classification. Besides whitespace/punctuation these intentional composition points count
         * as separators: a quote that opens/closes a quoted region (odd count in the literal, so the dynamic
         * part lands inside '...' or "..."), ':' (named parameter / cast prefix) and '_' (identifier affix).
         */
        private Edge edgeOf(String v, char c, boolean first) {
            if (c == '\'' || c == '"') {
                long count = v.chars().filter(ch -> ch == c).count();
                // "' AND t = '": the leading quote closes an earlier one, so the trailing quote opens
                boolean otherEndQuote = v.length() > 1 && (first ? v.charAt(v.length() - 1) : v.charAt(0)) == c;
                return (count % 2 == 1) != otherEndQuote ? Edge.SEP : Edge.TOKEN;
            }
            if (c == ':' || c == '_') {
                return Edge.SEP;
            }
            return tokenChar(c) ? Edge.TOKEN : Edge.SEP;
        }

        private Side unknown(String disp) {
            return new Side(Edge.UNKNOWN, false, false, false, false, null, compact(disp), null);
        }

        private Side sep(String disp) {
            return new Side(Edge.SEP, false, false, false, false, null, disp, disp.equals("null") ? List.of("") : null);
        }

        private Side withDisplay(Side s, String disp) {
            if (s.value() != null) {
                return s;
            }
            return new Side(s.edge(), s.textBlock(), s.plain(), s.plainSql(), s.startsKw(), null, compact(disp),
                    s.alts());
        }

        private int operandStart(int e) {
            int i = e;
            for (int guard = 0; guard < 10_000; guard++) {
                Tok x = tok(i);
                if (x.is(")") && match[i] >= 0) {
                    int o = match[i];
                    i = tok(o - 1).k() == K.ID && !NON_METHOD_KEYWORDS.contains(tok(o - 1).text()) ? o - 1 : o;
                } else if (x.is("]") && match[i] >= 0) {
                    i = match[i] - 1;
                    continue;
                }
                if (tok(i - 1).is(".") && i - 2 >= 0) {
                    i -= 2;
                    continue;
                }
                if (tok(i - 1).id("new")) {
                    i--;
                }
                return Math.max(i, 0);
            }
            return e;
        }

        private int operandEnd(int s) {
            int i = s;
            if (tok(i).id("new")) {
                i++;
                while (tok(i + 1).k() == K.ID || tok(i + 1).is(".") || tok(i + 1).is("<") || tok(i + 1).is(">")) {
                    i++;
                }
            }
            if (tok(i).is("(") && match[i] > i) {
                i = match[i];
            }
            for (int guard = 0; guard < 10_000; guard++) {
                if (tok(i + 1).is("(") && match[i + 1] > i) {
                    i = match[i + 1];
                } else if (tok(i + 1).is("[") && match[i + 1] > i) {
                    i = match[i + 1];
                } else if (tok(i + 1).is(".") && tok(i + 2).k() == K.ID) {
                    i += 2;
                } else {
                    break;
                }
            }
            return Math.min(i, t.size() - 1);
        }

        private String text(int a, int b) {
            if (a < 0 || b >= t.size() || a > b) {
                return "?";
            }
            return compact(src.substring(t.get(a).start(), t.get(b).end()));
        }

        // ------------------------- R4 / R5 / delimiters -------------------------

        private void precedence(int li) {
            boolean replace = tok(li + 2).id("replace");
            String target = null;
            if (replace) {
                Tok arg = tok(li + 4);
                if (!arg.lit() || !tok(li + 5).is(",") || !looksLikePlaceholder(arg.value())) {
                    return;
                }
                target = arg.value();
            }
            int p = li - 1;
            while (tok(p).is("+")) {
                int e = p - 1;
                int s = operandStart(e);
                Tok operand = tok(e);
                if (s == e && operand.lit()) {
                    String v = operand.value();
                    String found = null;
                    if (replace) {
                        if (v.contains(target)) {
                            found = target;
                        }
                    } else {
                        Matcher m = FORMAT_PLACEHOLDER.matcher(v);
                        if (m.find()) {
                            found = m.group();
                        }
                    }
                    if (found != null) {
                        report("R4", operand.line(), "operand " + "'" + head(v) + "' contains '" + found
                                + "' but only the last literal (line " + tok(li).line() + ") receives ."
                                + tok(li + 2).text() + "(..)");
                    }
                } else {
                    for (Ref ref : valueRefs(s, e)) {
                        for (Tok piece : ref.scanner().topLevelLiterals(ref.start(), ref.end())) {
                            String v = piece.value();
                            String found = replace ? (v.contains(target) ? target : null)
                                    : FORMAT_PLACEHOLDER.matcher(v).find() ? "%" : null;
                            if (found != null) {
                                report("R4", tok(e).line(), "operand " + text(s, e) + " (='" + head(v)
                                        + "') contains a placeholder but only the last literal (line "
                                        + tok(li).line() + ") receives ." + tok(li + 2).text() + "(..)");
                            }
                        }
                    }
                }
                p = s - 1;
            }
        }

        private boolean looksLikePlaceholder(String v) {
            return v.length() >= 3 && v.chars().anyMatch(ch -> "{}<>$%#@:[]".indexOf(ch) >= 0 || ch == '_')
                    && v.chars().noneMatch(Character::isWhitespace);
        }

        private void formattedReceiver(int dot) {
            Tok recv = tok(dot - 1);
            if (recv.lit()) {
                validateSpecifiers(recv);
                return;
            }
            if (recv.k() == K.ID) {
                int start = operandStart(dot - 1);
                for (Ref ref : valueRefs(start, dot - 1)) {
                    for (Tok piece : ref.scanner().topLevelLiterals(ref.start(), ref.end())) {
                        validateValue(piece.value(), t.get(dot).line(), "via " + text(start, dot - 1) + " ");
                    }
                }
                return;
            }
            if (recv.is(")") && match[dot - 1] >= 0) {
                int o = match[dot - 1];
                if (tok(o - 1).k() == K.ID && !NON_METHOD_KEYWORDS.contains(tok(o - 1).text())) {
                    return; // receiver is a method call result
                }
                topLevelLiterals(o + 1, dot - 2).forEach(this::validateSpecifiers);
            }
        }

        private void stringFormat(int open) {
            int close = match[open];
            if (close < 0) {
                return;
            }
            int argStart = open + 1;
            int argEnd = topLevelComma(argStart, close - 1);
            if (!(tok(argStart).lit() || tok(argStart).is("("))) {
                argStart = argEnd + 1; // String.format(Locale, fmt, ...)
                if (argStart >= close) {
                    return;
                }
                argEnd = topLevelComma(argStart, close - 1);
            }
            topLevelLiterals(argStart, argEnd).forEach(this::validateSpecifiers);
        }

        private int topLevelComma(int a, int b) {
            for (int k = a; k <= b; k++) {
                if ((tok(k).is("(") || tok(k).is("[") || tok(k).is("{")) && match[k] > k) {
                    k = match[k];
                } else if (tok(k).is(",")) {
                    return k - 1;
                }
            }
            return b;
        }

        /** Literal '+' operands at the top level of [a, b] (not receivers of a method call). */
        private List<Tok> topLevelLiterals(int a, int b) {
            List<Tok> lits = new ArrayList<>();
            for (int k = a; k <= b; k++) {
                Tok x = tok(k);
                if (x.is("(") && match[k] > k) {
                    k = match[k];
                } else if (x.k() == K.STR || x.k() == K.TB) {
                    if (!tok(k + 1).is(".")) {
                        lits.add(x);
                    }
                }
            }
            return lits;
        }

        /** Definition ranges of a plain variable or Type.CONSTANT operand (empty when unknown). */
        private List<Ref> valueRefs(int a, int b) {
            if (index == null) {
                return List.of();
            }
            List<Ref> refs = null;
            if (a == b && tok(a).k() == K.ID) {
                refs = definitions(tok(a).text(), false, a);
            } else if (b >= a + 2 && tok(b - 1).is(".") && tok(b).k() == K.ID && isQualifier(a, b - 2)) {
                Scanner owner = tok(b - 2).id("this") ? this : index.of(tok(b - 2).text());
                refs = owner == null ? null : owner.definitions(tok(b).text(), false, -1);
            }
            return refs == null ? List.of() : refs;
        }

        private void validateValue(String v, int line, String via) {
            int pos = 0;
            while (true) {
                int idx = v.indexOf('%', pos);
                if (idx < 0) {
                    return;
                }
                Matcher m = VALID_SPEC.matcher(v).region(idx, v.length());
                if (!m.lookingAt()) {
                    int from = Math.max(0, idx - 20);
                    int to = Math.min(v.length(), idx + 10);
                    report("R5", line, via + "invalid format specifier at '"
                            + esc(v.substring(from, idx)) + ">>%<<" + esc(v.substring(idx + 1, to)) + "'");
                    pos = idx + 1;
                } else {
                    pos = m.end();
                }
            }
        }

        private void validateSpecifiers(Tok lit) {
            if (lit.k() != K.STR && lit.k() != K.TB) {
                return;
            }
            String v = lit.value();
            int pos = 0;
            while (true) {
                int idx = v.indexOf('%', pos);
                if (idx < 0) {
                    return;
                }
                Matcher m = VALID_SPEC.matcher(v).region(idx, v.length());
                if (!m.lookingAt()) {
                    int from = Math.max(0, idx - 20);
                    int to = Math.min(v.length(), idx + 10);
                    report("R5", lineOf(lit, idx), "invalid format specifier at '"
                            + esc(v.substring(from, idx)) + ">>%<<" + esc(v.substring(idx + 1, to)) + "'");
                    pos = idx + 1;
                } else {
                    pos = m.end();
                }
            }
        }

        private int lineOf(Tok lit, int valueIndex) {
            if (lit.k() != K.TB) {
                return lit.line();
            }
            // first content line is the line after the opening delimiter; value lines map 1:1 unless \<newline>
            return lit.line() + 1 + newlines(lit.value(), 0, valueIndex);
        }

        private void joinDelimiter(int i) {
            Tok x = tok(i);
            int open = -1;
            if (x.id("String") && tok(i + 1).is(".") && tok(i + 2).id("join") && tok(i + 3).is("(")) {
                open = i + 3;
            } else if (x.id("joining") && tok(i + 1).is("(")) {
                open = i + 1;
            } else if (x.id("new") && tok(i + 1).id("StringJoiner") && tok(i + 2).is("(")) {
                open = i + 2;
            }
            if (open < 0) {
                return;
            }
            Tok delim = tok(open + 1);
            if (delim.k() != K.STR || !(tok(open + 2).is(",") || tok(open + 2).is(")"))) {
                return;
            }
            String v = delim.value();
            if (!v.isEmpty() && SQL_KEYWORD.matcher(v).find()
                    && (!Character.isWhitespace(v.charAt(0)) || !Character.isWhitespace(v.charAt(v.length() - 1)))) {
                report("R3", delim.line(), "join delimiter '" + esc(v) + "' needs whitespace on both sides");
            }
        }
    }

    // ------------------------------------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------------------------------------

    private static String head(String v) {
        String e = esc(v);
        return e.length() <= 28 ? e : e.substring(0, 28) + "...";
    }

    private static String tail(String v) {
        String e = esc(v);
        return e.length() <= 28 ? e : "..." + e.substring(e.length() - 28);
    }

    private static String esc(String v) {
        return v.replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r");
    }

    private static String compact(String s) {
        String c = s.replaceAll("\\s+", " ").trim();
        return c.length() <= 60 ? c : c.substring(0, 57) + "...";
    }

    private static String read(Path path) {
        try {
            return Files.readString(path, StandardCharsets.UTF_8);
        } catch (IOException error) {
            throw new UncheckedIOException(error);
        }
    }

    private static Path sourceRoot() {
        Path moduleRelative = Path.of("src", "main", "java");
        if (Files.isDirectory(moduleRelative)) {
            return moduleRelative;
        }
        return Path.of("server", "src", "main", "java");
    }
}
