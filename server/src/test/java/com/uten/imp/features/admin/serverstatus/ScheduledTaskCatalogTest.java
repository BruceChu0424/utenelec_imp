package com.uten.imp.features.admin.serverstatus;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Set;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 后台任务人话名称目录与源码双向对账 (2026-09-20)。
 *
 * <p>用户看到「定时任务 InventoryValueWorkScheduler.scheduled 接近预警值」时的原话:
 * 「不要用代号, 用实际的文字明确表达」「我没有设置过定时任务啊」。目录漏登记一项, 状态页和
 * 通知就会又冒出类名.方法名, 所以这里扫源码钉死: 每个 {@code @Scheduled} 方法都登记, 登记项
 * 也不能指向已删除的方法, 名称与用途里不得出现程序标识或全角括号。</p>
 */
class ScheduledTaskCatalogTest {

    private static final Path MAIN_SOURCE = Path.of("src/main/java/com/uten/imp");

    /** 行首的 @Scheduled(...), 允许中间夹别的注解, 抓紧随后的方法名; 注释里的 {@code @Scheduled} 不在行首后直接接方法, 不会误抓。 */
    private static final Pattern SCHEDULED_METHOD = Pattern.compile(
            "(?ms)^[ \\t]*@Scheduled\\s*(?:\\([^)]*\\))?\\s*(?:@\\w+(?:\\([^)]*\\))?\\s*)*"
            + "(?:(?:public|protected|private|synchronized|final|static)\\s+)*[\\w<>\\[\\],.?]+\\s+(\\w+)\\s*\\(");

    static Set<String> scheduledMethodsInSource() throws IOException {
        Set<String> names = new TreeSet<>();
        try (Stream<Path> files = Files.walk(MAIN_SOURCE)) {
            for (Path file : files.filter(path -> path.toString().endsWith(".java")).toList()) {
                String text = Files.readString(file);
                if (!text.contains("@Scheduled")) continue;
                String simpleClass = file.getFileName().toString().replace(".java", "");
                Matcher matcher = SCHEDULED_METHOD.matcher(text);
                while (matcher.find()) names.add(simpleClass + "." + matcher.group(1));
            }
        }
        return names;
    }

    @Test
    void everyScheduledMethodHasAPlainLanguageEntryAndNoEntryIsOrphaned() throws IOException {
        Set<String> inSource = scheduledMethodsInSource();
        assertThat(inSource).as("扫描到的 @Scheduled 方法 (为空说明扫描器坏了)").isNotEmpty();
        assertThat(ScheduledTaskCatalog.names())
                .as("目录必须与源码一一对应: 少了会在状态页和通知里漏成类名, 多了是死条目")
                .containsExactlyInAnyOrderElementsOf(inSource);
    }

    @Test
    void entriesSpeakPlainChineseWithoutCodeNamesOrFullWidthParentheses() {
        for (String name : ScheduledTaskCatalog.names()) {
            String declaringClass = name.substring(0, name.indexOf('.'));
            var entry = ScheduledTaskCatalog.describe(name).orElseThrow();
            assertThat(entry.label()).as(name).isNotBlank().matches(".*\\p{IsHan}.*")
                    .doesNotContain(".").doesNotContain(declaringClass)
                    .doesNotContainIgnoringCase("scheduler").doesNotContainIgnoringCase("reconciler");
            assertThat(entry.label().length()).as(name + " 的名称要放得进通知标题").isLessThanOrEqualTo(12);
            assertThat(entry.purpose()).as(name).isNotBlank().endsWith("。")
                    .doesNotContain(declaringClass).doesNotContain("\uFF08").doesNotContain("\uFF09");
        }
    }

    @Test
    void unknownNamesFallBackToThemselvesInsteadOfCrashing() {
        assertThat(ScheduledTaskCatalog.describe("Nope.run")).isEmpty();
        assertThat(ScheduledTaskCatalog.describe(null)).isEmpty();
        assertThat(ScheduledTaskCatalog.labelOf("Nope.run")).isEqualTo("Nope.run");
        assertThat(ScheduledTaskCatalog.labelOf(null)).isEmpty();
    }
}
