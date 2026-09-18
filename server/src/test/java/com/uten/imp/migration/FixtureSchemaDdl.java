package com.uten.imp.migration;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Stream;

/**
 * 手写 fixture DDL 的静态解析器（无 JDBC、无执行）：把测试源码里的字符串字面量
 * 重组成 SQL 文本，提取每条建表语句的表名与列清单（列 -> 归一化类型族）。
 * 供 {@link FixtureSchemaDriftGuardPostgresTest} 与真实迁移后的 schema 对账。
 *
 * <p>已知边界（与守卫测试的 javadoc 一致）：只解析建表语句（fixture 把真实视图
 * 建成 TABLE 桩也算）；TEMP/UNLOGGED 是测试内部暂存，跳过；表名来自 Java 变量
 * 拼接、静态不可解析的语句按「动态建表」上报，由守卫按文件级棘轮处理。
 */
final class FixtureSchemaDdl {

    private static final Pattern CREATE_TABLE = Pattern.compile(
            "(?i)create\\s+(?:(temp|temporary|global|local|unlogged)\\s+)?table\\s+(if\\s+not\\s+exists\\s+)?");
    private static final Pattern IDENTIFIER = Pattern.compile("[A-Za-z_][A-Za-z0-9_]*");
    private static final Pattern WORD = Pattern.compile("[a-z][a-z0-9_]*");

    /** 列级约束关键字（首个 token 是它们的是表约束，不是列定义）。 */
    private static final Set<String> TABLE_CONSTRAINT_KEYWORDS = Set.of(
            "constraint", "primary", "foreign", "unique", "check", "exclude",
            "like", "inherits", "period");

    /** 类型声明里可能跟在首个词后面的续词（多词类型）。 */
    private static final Set<String> TYPE_CONTINUATION_WORDS = Set.of(
            "with", "without", "time", "zone", "precision", "varying");

    /** 一条被解析出来的 fixture 建表语句。 */
    record FixtureTable(String file, String table, Map<String, String> columns) {
    }

    /** 扫描结果：可对账的建表语句 + 动态建表文件 + 解析失败明细。 */
    record Scan(List<FixtureTable> tables, Set<String> dynamicDdlFiles, List<String> parseFailures) {
    }

    private FixtureSchemaDdl() {
    }

    /** 扫描测试源码目录下全部 .java（跳过指定文件，如守卫与基线冒烟自身）。 */
    static Scan scan(Path testSources, Set<String> skipFileNames) throws IOException {
        List<FixtureTable> tables = new ArrayList<>();
        Set<String> dynamicDdlFiles = new TreeSet<>();
        List<String> parseFailures = new ArrayList<>();
        try (Stream<Path> files = Files.walk(testSources)) {
            for (Path file : files.filter(Files::isRegularFile)
                    .filter(path -> path.getFileName().toString().endsWith(".java"))
                    .sorted().toList()) {
                if (skipFileNames.contains(file.getFileName().toString())) {
                    continue;
                }
                String relative = testSources.relativize(file.toAbsolutePath()).normalize()
                        .toString().replace('\\', '/');
                String sql = stringLiteralContents(file);
                Matcher create = CREATE_TABLE.matcher(sql);
                while (create.find()) {
                    if (create.group(1) != null) {
                        continue; // TEMP/UNLOGGED：测试内部暂存，故意少列影射，不参与对账
                    }
                    int cursor = skipWhitespace(sql, create.end());
                    Name name = readIdentifier(sql, cursor);
                    cursor = skipWhitespace(sql, name.end());
                    // 表名来自 Java 变量拼接（或拼出了 _xxx 这种残名）时静态不可解析。
                    if (name.text().isEmpty() || name.text().startsWith("_")
                            || !startsWithParen(sql, cursor)) {
                        dynamicDdlFiles.add(relative);
                        continue;
                    }
                    String body = balancedBody(sql, cursor);
                    if (body == null || body.contains("+")) {
                        dynamicDdlFiles.add(relative);
                        continue;
                    }
                    tables.add(new FixtureTable(
                            relative, name.text(), parseColumns(body, parseFailures, relative)));
                }
            }
        }
        return new Scan(tables, dynamicDdlFiles, parseFailures);
    }

    // ------------------------------------------------------------------
    // Java 字面量提取：把字符串拼接/文本块重组成 SQL 文本
    // ------------------------------------------------------------------

    private static String stringLiteralContents(Path file) throws IOException {
        String source = Files.readString(file, StandardCharsets.UTF_8);
        StringBuilder out = new StringBuilder(source.length());
        int i = 0;
        int length = source.length();
        while (i < length) {
            char ch = source.charAt(i);
            if (ch == '/' && i + 1 < length && source.charAt(i + 1) == '/') {
                while (i < length && source.charAt(i) != '\n') {
                    i++;
                }
            } else if (ch == '/' && i + 1 < length && source.charAt(i + 1) == '*') {
                i += 2;
                while (i + 1 < length && !(source.charAt(i) == '*' && source.charAt(i + 1) == '/')) {
                    i++;
                }
                i = Math.min(i + 2, length);
            } else if (ch == '"') {
                if (source.startsWith("\"\"\"", i)) {
                    int close = source.indexOf("\"\"\"", i + 3);
                    if (close < 0) {
                        break; // 源码不完整（不该发生），停止提取
                    }
                    out.append(source, i + 3, close);
                    i = close + 3;
                } else {
                    i++;
                    while (i < length && source.charAt(i) != '"') {
                        if (source.charAt(i) == '\\' && i + 1 < length) {
                            out.append(unescape(source.charAt(i + 1)));
                            i += 2;
                        } else {
                            out.append(source.charAt(i));
                            i++;
                        }
                    }
                    i++;
                    out.append(' ');
                }
            } else if (ch == '\'') {
                i++;
                while (i < length && source.charAt(i) != '\'') {
                    i += source.charAt(i) == '\\' && i + 1 < length ? 2 : 1;
                }
                i++;
            } else {
                i++;
            }
        }
        return out.toString();
    }

    private static char unescape(char escaped) {
        return switch (escaped) {
            case 'n' -> '\n';
            case 't' -> '\t';
            case 'r' -> '\r';
            default -> escaped;
        };
    }

    // ------------------------------------------------------------------
    // SQL 解析：建表名 + 括号平衡体 + 列定义
    // ------------------------------------------------------------------

    private static int skipWhitespace(String sql, int position) {
        while (position < sql.length() && Character.isWhitespace(sql.charAt(position))) {
            position++;
        }
        return position;
    }

    private record Name(String text, int end) {
    }

    private static Name readIdentifier(String sql, int position) {
        if (position < sql.length() && sql.charAt(position) == '"') {
            int close = sql.indexOf('"', position + 1);
            if (close > position) {
                return new Name(sql.substring(position + 1, close), close + 1);
            }
        }
        Matcher identifier = IDENTIFIER.matcher(sql).region(position, sql.length());
        if (identifier.lookingAt()) {
            return new Name(identifier.group(), identifier.end());
        }
        return new Name("", position);
    }

    /** 从 {@code openParen} 处的左括号开始取括号平衡的体；不闭合返回 {@code null}。 */
    private static String balancedBody(String sql, int openParen) {
        int depth = 0;
        boolean inSingleQuote = false;
        for (int i = openParen; i < sql.length(); i++) {
            char ch = sql.charAt(i);
            if (inSingleQuote) {
                if (ch == '\'') {
                    inSingleQuote = false;
                }
                continue;
            }
            if (ch == '\'') {
                inSingleQuote = true;
            } else if (ch == '(') {
                depth++;
            } else if (ch == ')') {
                depth--;
                if (depth == 0) {
                    return sql.substring(openParen + 1, i);
                }
            }
        }
        return null;
    }

    private static boolean startsWithParen(String sql, int position) {
        return position < sql.length() && sql.charAt(position) == '(';
    }

    private static Map<String, String> parseColumns(
            String body, List<String> parseFailures, String where) {
        Map<String, String> columns = new LinkedHashMap<>();
        for (String item : splitTopLevel(body)) {
            String definition = stripLineComments(item).trim();
            if (definition.isEmpty()) {
                continue;
            }
            String first = firstToken(definition);
            if (TABLE_CONSTRAINT_KEYWORDS.contains(first.toLowerCase())) {
                continue;
            }
            Name name = readIdentifier(definition, 0);
            if (name.text().isEmpty()) {
                parseFailures.add("列定义解析失败于 %s [%s]——先修本解析器。"
                        .formatted(where, truncate(definition)));
                continue;
            }
            columns.put(name.text().toLowerCase(), fixtureFamily(definition.substring(name.end())));
        }
        return columns;
    }

    private static List<String> splitTopLevel(String body) {
        List<String> items = new ArrayList<>();
        StringBuilder current = new StringBuilder();
        int depth = 0;
        boolean inSingleQuote = false;
        boolean inDoubleQuote = false;
        for (int i = 0; i < body.length(); i++) {
            char ch = body.charAt(i);
            if (inSingleQuote) {
                current.append(ch);
                if (ch == '\'') {
                    inSingleQuote = false;
                }
                continue;
            }
            if (inDoubleQuote) {
                current.append(ch);
                if (ch == '"') {
                    inDoubleQuote = false;
                }
                continue;
            }
            if (ch == '\'') {
                inSingleQuote = true;
                current.append(ch);
            } else if (ch == '"') {
                inDoubleQuote = true;
                current.append(ch);
            } else if (ch == '(') {
                depth++;
                current.append(ch);
            } else if (ch == ')') {
                depth--;
                current.append(ch);
            } else if (ch == ',' && depth == 0) {
                items.add(current.toString());
                current.setLength(0);
            } else {
                current.append(ch);
            }
        }
        items.add(current.toString());
        return items;
    }

    private static String stripLineComments(String item) {
        return item.replaceAll("(?m)(^|\\s)--[^\\n]*", " ");
    }

    private static String firstToken(String definition) {
        Matcher token = IDENTIFIER.matcher(definition);
        return token.lookingAt() ? token.group() : "";
    }

    /**
     * fixture 侧类型声明 -> 归一化类型族；解析不出来保留原词
     * （与真实族比对后按漂移报出，逼着人来收敛口径）。
     */
    static String fixtureFamily(String typeAndConstraints) {
        String text = typeAndConstraints.trim().toLowerCase();
        int cut = text.length();
        Matcher words = WORD.matcher(text);
        List<int[]> spans = new ArrayList<>();
        while (words.find()) {
            spans.add(new int[]{words.start(), words.end()});
        }
        for (int index = 0; index < spans.size(); index++) {
            String word = text.substring(spans.get(index)[0], spans.get(index)[1]);
            boolean partOfType = index == 0 || TYPE_CONTINUATION_WORDS.contains(word);
            if (!partOfType) {
                cut = spans.get(index)[0];
                break;
            }
        }
        String type = text.substring(0, cut).trim();
        boolean array = type.endsWith("[]");
        while (type.endsWith("[]")) {
            type = type.substring(0, type.length() - 2).trim();
        }
        // 摘掉长度/精度修饰 (n[,m])
        type = type.replaceFirst("\\s*\\([^()]*\\)\\s*$", "").trim();
        String family = switch (type) {
            case "varchar", "character", "char", "bpchar", "character varying" -> "text";
            case "timestamptz", "timestamp with time zone", "timestamp without time zone" -> "timestamp";
            case "decimal" -> "numeric";
            case "int8", "bigserial" -> "bigint";
            // int/smallint 同族宽松：fixture 常把 smallint 状态码简化写成 integer，
            // 取值域兼容；bigint（乐观锁/大 id）保持单独一族不放水。
            case "int", "integer", "int4", "serial", "serial4", "smallint", "int2",
                    "smallserial", "serial2" -> "int";
            case "boolean" -> "bool";
            case "double", "double precision" -> "float8";
            case "real" -> "float4";
            default -> type;
        };
        return array ? "_%s".formatted(family) : family;
    }

    /** pg udt_name -> 归一化类型族（与 fixtureFamily 同一坐标系）。 */
    static String realFamily(String udtName) {
        String udt = udtName.toLowerCase();
        boolean array = udt.startsWith("_");
        String base = array ? udt.substring(1) : udt;
        String family = switch (base) {
            case "int8" -> "bigint";
            // int/smallint 同族宽松（与 fixtureFamily 一致，见那边的说明）。
            case "int4", "int2" -> "int";
            case "varchar", "bpchar" -> "text";
            case "timestamptz", "timestamp" -> "timestamp";
            case "numeric" -> "numeric";
            case "bool" -> "bool";
            case "float8" -> "float8";
            case "float4" -> "float4";
            default -> base;
        };
        return array ? "_%s".formatted(family) : family;
    }

    private static String truncate(String text) {
        return text.length() <= 80 ? text : "%s…".formatted(text.substring(0, 80));
    }
}
