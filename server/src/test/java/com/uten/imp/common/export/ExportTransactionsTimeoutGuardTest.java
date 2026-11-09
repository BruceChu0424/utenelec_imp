package com.uten.imp.common.export;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * 同步导出事务时限单一入口守卫(2026-11-08)。
 *
 * <p>所有返回导出产物(ExportPayload / ExportDocument / 导出文件)的事务方法, 以及类级事务的
 * 导出服务, 都必须引用 {@link ExportTransactions#TIMEOUT_SECONDS}: 漏写会落回 40 秒默认事务
 * 时限——货品资料全量导出就是这样被截断、报出误导性的 BadJpqlGrammarException 的。</p>
 */
class ExportTransactionsTimeoutGuardTest {
    private static final Pattern EXPORT_METHOD = Pattern.compile(
            "\\b(?:ExportPayload|ExportDocument|byte\\[]|Download)\\s+(export\\w*|document|build)\\s*\\(");
    private static final Pattern EXPORT_CLASS = Pattern.compile("\\bclass\\s+(\\w*Export\\w*)");

    @Test void everySynchronousExportTransactionUsesTheSharedTimeout() throws IOException {
        List<String> missing = new ArrayList<>();
        int checked = 0;
        try (Stream<Path> files = Files.walk(Path.of("src/main/java/com/uten/imp"))) {
            for (Path file : files.filter(p -> p.toString().endsWith(".java")).toList()) {
                String source = Files.readString(file);
                int from = 0;
                while ((from = source.indexOf("@Transactional(", from)) >= 0) {
                    int open = from + "@Transactional".length();
                    int close = matchingParen(source, open);
                    String arguments = source.substring(open + 1, close);
                    // 注解后到第一个方法体/类体为止: 中间可夹 @PreAuthorize 等任意注解。
                    int body = source.indexOf('{', close);
                    String target = source.substring(close + 1, body < 0 ? source.length() : body);
                    Matcher method = EXPORT_METHOD.matcher(target);
                    Matcher type = EXPORT_CLASS.matcher(target);
                    String name = method.find() ? method.group(1) : type.find() ? type.group(1) : null;
                    if (name != null) {
                        checked++;
                        if (!arguments.contains("ExportTransactions.TIMEOUT_SECONDS"))
                            missing.add(file.getFileName() + "#" + name);
                    }
                    from = close;
                }
            }
        }
        assertEquals(List.of(), missing, "这些导出事务没有引用 ExportTransactions.TIMEOUT_SECONDS");
        assertTrue(checked >= 28, "守卫应覆盖全部同步导出事务, 实际只匹配到 " + checked);
    }

    @Test void theSharedBudgetIsTwoMinutes() {
        assertEquals(120, ExportTransactions.TIMEOUT_SECONDS);
    }

    private static int matchingParen(String source, int open) {
        int depth = 0;
        boolean quoted = false;
        for (int i = open; i < source.length(); i++) {
            char c = source.charAt(i);
            if (c == '"' && source.charAt(i - 1) != '\\') quoted = !quoted;
            if (quoted) continue;
            if (c == '(') depth++;
            else if (c == ')' && --depth == 0) return i;
        }
        throw new IllegalStateException("Unbalanced @Transactional arguments");
    }
}
