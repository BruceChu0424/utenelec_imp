package com.uten.imp.features.production.mrp;

import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;

import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * security-07：{@code /api/production/plans/{id}/mrp/**} 每个处理方法入口先过
 * {@link ProductionPlanResourceGuard}——读方法 requireReadable，写方法 requireWritable 且带的动作码
 * 与方法上的 {@code @PreAuthorize} 同一个；新增方法忘了过守卫，这里第一个红。
 * 旧的「按计划一键生成采购 / 委外申请」与「整树展开」入口已删除，不能回来。
 * 没有调用方的订单物料分析(order-preview)已删除，同样不能回来。
 */
class ProductionPlanSubresourceScopeContractTest {

    private static final Path CONTROLLER =
            Path.of("src/main/java/com/uten/imp/features/production/mrp/MrpController.java");
    private static final Path SERVICE =
            Path.of("src/main/java/com/uten/imp/features/production/mrp/MrpService.java");

    @Test
    void everyPlanSubresourceHandlerStartsWithTheObjectScopeGuard() throws Exception {
        String source = Files.readString(CONTROLLER, StandardCharsets.UTF_8);
        List<Method> handlers = Arrays.stream(MrpController.class.getDeclaredMethods())
                .filter(method -> method.isAnnotationPresent(GetMapping.class)
                        || method.isAnnotationPresent(PostMapping.class)
                        || method.isAnnotationPresent(PutMapping.class))
                .toList();
        assertThat(handlers).hasSizeGreaterThanOrEqualTo(9);

        for (Method handler : handlers) {
            String body = bodyOf(source, handler.getName());
            String firstStatement = body.strip().split(";", 2)[0].strip();
            boolean write = !handler.isAnnotationPresent(GetMapping.class);
            if (write) {
                String authority = singleAuthority(handler.getAnnotation(PreAuthorize.class).value());
                assertThat(firstStatement)
                        .as(handler.getName() + " 写方法入口必须先 requireWritable 且动作码与 @PreAuthorize 一致")
                        .isEqualTo("planGuard.requireWritable(id, \"" + authority + "\")");
            } else {
                assertThat(firstStatement)
                        .as(handler.getName() + " 读方法入口必须先 requireReadable")
                        .isEqualTo("planGuard.requireReadable(id)");
            }
        }
    }

    @Test
    void retiredGenerateAndFullTreeEntriesStayDeleted() throws Exception {
        String controller = Files.readString(CONTROLLER, StandardCharsets.UTF_8);
        assertThat(controller)
                .doesNotContain("/mrp/generate\"")
                .doesNotContain("full-tree");
        assertThat(Files.readString(SERVICE, StandardCharsets.UTF_8))
                .doesNotContain("public MrpGenerateResult generate(");
    }

    @Test
    void orphanOrderPreviewEntryStaysDeleted() throws Exception {
        // 订单物料分析(order-preview)没有任何调用方，随 ADR-109 删除；现行入口是持久物料分析。
        assertThat(Files.exists(CONTROLLER.resolveSibling("MrpOrderController.java"))).isFalse();
        assertThat(Files.readString(SERVICE, StandardCharsets.UTF_8))
                .doesNotContain("previewOrder(")
                .doesNotContain("explodeOrder(");
    }

    private static String singleAuthority(String expression) {
        Matcher matcher = Pattern.compile("hasAuthority\\('([^']+)'\\)").matcher(expression);
        assertThat(matcher.find()).as(expression).isTrue();
        String authority = matcher.group(1);
        assertThat(matcher.find()).as("写方法只挂一个动作码: " + expression).isFalse();
        return authority;
    }

    private static String bodyOf(String source, String methodName) {
        Matcher matcher = Pattern.compile("\\s" + Pattern.quote(methodName) + "\\(").matcher(source);
        int signature = -1;
        while (matcher.find()) {
            int brace = source.indexOf('{', matcher.end());
            int semicolon = source.indexOf(';', matcher.end());
            if (brace >= 0 && (semicolon < 0 || brace < semicolon)) {
                signature = matcher.start();
                break;
            }
        }
        assertThat(signature).as("找不到方法 " + methodName).isGreaterThanOrEqualTo(0);
        int open = source.indexOf('{', signature);
        int depth = 0;
        for (int index = open; index < source.length(); index++) {
            char character = source.charAt(index);
            if (character == '{') depth++;
            if (character == '}' && --depth == 0) {
                return source.substring(open + 1, index);
            }
        }
        throw new AssertionError("方法体未闭合: " + methodName);
    }
}
