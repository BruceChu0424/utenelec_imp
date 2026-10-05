package com.uten.imp.architecture;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * ADR-131 §3.6: "线边仓"面向员工一律改叫"内料仓" (界面、服务端提示、通知)。内部类名、列名、方法名、
 * 注释不改, 所以这里只扫服务端源码里的字符串字面量与文本块 (剥掉 Java 注释; 文本块里的 SQL 行注释
 * {@code --} 不是给员工看的, 一并剥掉)。
 */
class LineSideWordingContractTest {

    private static final Path MAIN_SOURCE = Path.of("src/main/java");
    private static final String OLD_WORD = "线边仓";

    @Test
    void serverStringLiteralsNoLongerSayLineSideWarehouse() throws IOException {
        List<String> violations = new ArrayList<>();
        try (Stream<Path> files = Files.walk(MAIN_SOURCE)) {
            for (Path file : files.filter(path -> path.toString().endsWith(".java")).sorted().toList()) {
                for (Literal literal : literals(Files.readString(file))) {
                    if (literal.text().contains(OLD_WORD)) {
                        violations.add(MAIN_SOURCE.relativize(file).toString().replace('\\', '/') + ":"
                                + literal.line() + "  " + abbreviate(literal.text()));
                    }
                }
            }
        }
        assertTrue(violations.isEmpty(), () -> "面向员工的文字请把「线边仓」改叫「内料仓」(ADR-131 §3.6):\n"
                + String.join("\n", violations));
    }

    @Test
    void openedStoreIsNamedWorkshopMaterialStore() throws IOException {
        // ADR-147: 内料仓只由「车间内料仓」开通命令建出(WorkshopBinService), 不再自动配置。
        Path service = MAIN_SOURCE.resolve("com/uten/imp/features/warehouse/materialbin/WorkshopBinService.java");
        List<String> texts = literals(Files.readString(service)).stream().map(Literal::text).toList();
        assertTrue(texts.contains("内料仓"), "开通建出的仓名是「{车间名}内料仓」");
        // ADR-145 单主仓: 一个车间只有一个内料仓, 不再追加「 (主仓名)」造同名变体, 重名直接拒绝。
        assertTrue(texts.stream().noneMatch(text -> text.equals(" (")),
                "不再生成 \" ({主仓})\" 后缀");
    }

    /** 扫描器自检: 注释里的字不算, 字符串、文本块里的算, 文本块里的 SQL 行注释不算。 */
    @Test
    void scannerSkipsCommentsButReadsLiteralsAndTextBlocks() {
        String source = """
                class Sample {
                    // 线边仓 in a line comment
                    /* 线边仓 in a block comment */
                    String a = "内料仓 \\"quoted\\" text";
                    char c = '"';
                    String b = \"""
                            SELECT 1 -- 线边仓 in an SQL comment
                            FROM t WHERE name = '甲'
                            \""";
                    String d = "x" + "线边仓";
                }
                """;
        List<Literal> literals = literals(source);
        assertEquals(4, literals.size(), literals::toString);
        assertEquals("内料仓 \\\"quoted\\\" text", literals.get(0).text());
        assertEquals(4, literals.get(0).line());
        assertTrue(literals.get(1).text().contains("FROM t WHERE name = '甲'"));
        assertTrue(!literals.get(1).text().contains(OLD_WORD), "文本块里的 SQL 行注释要剥掉");
        assertEquals("x", literals.get(2).text());
        assertEquals(OLD_WORD, literals.get(3).text());
        assertEquals(10, literals.get(3).line());
        assertEquals(1, literals.stream().filter(literal -> literal.text().contains(OLD_WORD)).count());
    }

    record Literal(int line, String text) {}

    /** 取出 Java 源码里的字符串字面量与文本块 (原样, 不解转义); 跳过注释与字符字面量。 */
    static List<Literal> literals(String source) {
        List<Literal> out = new ArrayList<>();
        int line = 1;
        int i = 0;
        int n = source.length();
        while (i < n) {
            char c = source.charAt(i);
            if (c == '\n') {
                line++;
                i++;
            } else if (c == '/' && i + 1 < n && source.charAt(i + 1) == '/') {
                while (i < n && source.charAt(i) != '\n') i++;
            } else if (c == '/' && i + 1 < n && source.charAt(i + 1) == '*') {
                int end = source.indexOf("*/", i + 2);
                end = end < 0 ? n : end + 2;
                line += count(source, i, end);
                i = end;
            } else if (c == '\'') {
                int j = i + 1;
                while (j < n && source.charAt(j) != '\'') j += source.charAt(j) == '\\' ? 2 : 1;
                i = Math.min(n, j + 1);
            } else if (source.startsWith("\"\"\"", i)) {
                int start = i + 3;
                int j = start;
                while (j < n && !source.startsWith("\"\"\"", j)) j += source.charAt(j) == '\\' ? 2 : 1;
                int end = Math.min(n, j);
                out.add(new Literal(line, stripSqlLineComments(source.substring(start, end))));
                line += count(source, i, end);
                i = Math.min(n, end + 3);
            } else if (c == '"') {
                int j = i + 1;
                while (j < n && source.charAt(j) != '"' && source.charAt(j) != '\n') {
                    j += source.charAt(j) == '\\' ? 2 : 1;
                }
                int end = Math.min(n, j);
                out.add(new Literal(line, source.substring(i + 1, end)));
                i = Math.min(n, end + 1);
            } else {
                i++;
            }
        }
        return out;
    }

    private static String stripSqlLineComments(String block) {
        StringBuilder out = new StringBuilder();
        for (String row : block.split("\n", -1)) {
            int comment = row.indexOf("--");
            out.append(comment < 0 ? row : row.substring(0, comment)).append('\n');
        }
        return out.toString();
    }

    private static int count(String source, int from, int to) {
        int lines = 0;
        for (int k = from; k < to && k < source.length(); k++) {
            if (source.charAt(k) == '\n') lines++;
        }
        return lines;
    }

    private static String abbreviate(String text) {
        String flat = text.replace('\n', ' ').strip();
        return flat.length() > 80 ? flat.substring(0, 80) + "..." : flat;
    }
}
