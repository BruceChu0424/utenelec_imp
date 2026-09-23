package com.uten.imp.security;

import org.flywaydb.core.Flyway;
import org.springframework.core.annotation.AnnotatedElementUtils;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestMethod;
import org.springframework.web.bind.annotation.RestController;
import org.testcontainers.containers.PostgreSQLContainer;

import java.io.IOException;
import java.lang.reflect.Method;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Stream;

/**
 * 权限目录契约测试共用：一个迁移到当前头版本的全新库(整个 JVM 只起一次)+ 从编译产物里
 * 反射出的全部 {@code @PreAuthorize} 码 + 主代码里的权限码字面量(ADR-109 单一事实源的锁)。
 */
final class PermissionCatalogTestSupport {

    /** 权限码命名规范(与数据库 permissions_code_format_chk 同一口径)。 */
    static final Pattern CODE = Pattern.compile("^[a-z][a-z_]*(:[a-z][a-z_]*){1,2}$");
    private static final Pattern AUTHORITY = Pattern.compile("has(?:Any)?Authority\\(([^)]*)\\)");
    private static final Pattern QUOTED = Pattern.compile("'([^']+)'");
    private static final Pattern JAVA_LITERAL = Pattern.compile("\"([a-z][a-z_]*(?::[a-z][a-z_]*){1,2})\"");
    private static final Pattern DART_CONST = Pattern.compile("static const \\w+\\s*=\\s*'([^']+)';");

    private static PostgreSQLContainer<?> postgres;
    private static JdbcTemplate jdbc;

    private PermissionCatalogTestSupport() {
    }

    static synchronized JdbcTemplate database() {
        if (jdbc == null) {
            postgres = new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten-test-only");
            postgres.start();
            Flyway.configure()
                    .dataSource(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())
                    .locations("classpath:db/migration")
                    .load()
                    .migrate();
            jdbc = new JdbcTemplate(new DriverManagerDataSource(
                    postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword()));
            Runtime.getRuntime().addShutdownHook(new Thread(postgres::stop));
        }
        return jdbc;
    }

    static Set<String> catalogCodes() {
        return new LinkedHashSet<>(database().queryForList("SELECT code FROM permissions ORDER BY code", String.class));
    }

    /** 一个处理方法(或类)上的 @PreAuthorize 码 + 它是不是非 GET 写端点。 */
    record Guard(Class<?> type, Method method, Set<String> codes, boolean write) {
        String where() {
            return type.getSimpleName() + (method == null ? "" : "#" + method.getName());
        }
    }

    /** 扫描编译产物中的全部主代码类，读取类级与方法级 @PreAuthorize(常量拼接在编译期已内联)。 */
    static List<Guard> guards() throws IOException {
        Path classes = Path.of("target", "classes");
        List<Guard> result = new ArrayList<>();
        try (Stream<Path> files = Files.walk(classes.resolve("com/uten/imp"))) {
            for (Path file : files.filter(p -> p.toString().endsWith(".class")).toList()) {
                String name = classes.relativize(file).toString()
                        .replace('\\', '/').replace('/', '.').replaceAll("\\.class$", "");
                Class<?> type;
                try {
                    type = Class.forName(name, false, PermissionCatalogTestSupport.class.getClassLoader());
                } catch (Throwable ignored) {
                    continue;
                }
                PreAuthorize classGuard = type.getAnnotation(PreAuthorize.class);
                boolean controller = type.isAnnotationPresent(RestController.class);
                if (classGuard != null) {
                    result.add(new Guard(type, null, codes(classGuard.value()), false));
                }
                Method[] methods;
                try {
                    methods = type.getDeclaredMethods();
                } catch (Throwable ignored) {
                    continue;
                }
                for (Method method : methods) {
                    PreAuthorize methodGuard = method.getAnnotation(PreAuthorize.class);
                    boolean write = controller && isWriteMapping(method);
                    if (methodGuard != null) {
                        result.add(new Guard(type, method, codes(methodGuard.value()), write));
                    } else if (write && classGuard != null) {
                        result.add(new Guard(type, method, codes(classGuard.value()), true));
                    }
                }
            }
        }
        return result;
    }

    static Set<String> codes(String expression) {
        Set<String> codes = new LinkedHashSet<>();
        Matcher call = AUTHORITY.matcher(expression);
        while (call.find()) {
            Matcher quoted = QUOTED.matcher(call.group(1));
            while (quoted.find()) {
                codes.add(quoted.group(1));
            }
        }
        return codes;
    }

    private static boolean isWriteMapping(Method method) {
        if (method.isAnnotationPresent(PostMapping.class)
                || method.isAnnotationPresent(PutMapping.class)
                || method.isAnnotationPresent(PatchMapping.class)
                || method.isAnnotationPresent(DeleteMapping.class)) {
            return true;
        }
        if (method.isAnnotationPresent(GetMapping.class)) {
            return false;
        }
        RequestMapping mapping = AnnotatedElementUtils.findMergedAnnotation(method, RequestMapping.class);
        return mapping != null && Arrays.stream(mapping.method()).anyMatch(m -> m != RequestMethod.GET);
    }

    /** 主代码里所有「长得像权限码」的字符串字面量(按文件分组前先去重)。 */
    static Set<String> javaLiterals() throws IOException {
        Set<String> literals = new LinkedHashSet<>();
        try (Stream<Path> files = Files.walk(Path.of("src", "main", "java"))) {
            for (Path file : files.filter(p -> p.toString().endsWith(".java")).toList()) {
                Matcher matcher = JAVA_LITERAL.matcher(Files.readString(file));
                while (matcher.find()) {
                    literals.add(matcher.group(1));
                }
            }
        }
        return literals;
    }

    /** 前端 Perm 常量(lib/shared/auth/permissions.dart)。 */
    static Set<String> frontendPermConstants() throws IOException {
        Path path = Files.exists(Path.of("..", "lib", "shared", "auth", "permissions.dart"))
                ? Path.of("..", "lib", "shared", "auth", "permissions.dart")
                : Path.of("lib", "shared", "auth", "permissions.dart");
        Set<String> codes = new LinkedHashSet<>();
        Matcher matcher = DART_CONST.matcher(Files.readString(path));
        while (matcher.find()) {
            if (CODE.matcher(matcher.group(1)).matches()) {
                codes.add(matcher.group(1));
            }
        }
        return codes;
    }
}
