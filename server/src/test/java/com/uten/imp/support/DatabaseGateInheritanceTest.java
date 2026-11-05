package com.uten.imp.support;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.platform.commons.support.AnnotationSupport;

import java.lang.reflect.Modifier;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;

class DatabaseGateInheritanceTest {
    private static final Pattern MAVEN_TEST_CLASS = Pattern.compile("Test.*|.*Test|.*Tests|.*TestCase");

    @Test
    void everyConcreteDatabaseFixtureKeepsTheOptInConditionOnItsActualTestClass() throws Exception {
        Path classes = Path.of(DatabaseGateInheritanceTest.class.getProtectionDomain()
                .getCodeSource().getLocation().toURI());
        var missing = new ArrayList<String>();
        int checked = 0;
        try (var paths = Files.walk(classes)) {
            for (Path path : paths.filter(p -> p.toString().endsWith(".class")).toList()) {
                String relative = classes.relativize(path).toString();
                if (relative.contains("$")) continue;
                String name = relative.substring(0, relative.length() - 6).replace('\\', '.').replace('/', '.');
                Class<?> type = Class.forName(name, false, getClass().getClassLoader());
                if (Modifier.isAbstract(type.getModifiers())
                        || !MAVEN_TEST_CLASS.matcher(type.getSimpleName()).matches()) continue;
                Class<?> ancestor = type.getSuperclass();
                while (ancestor != null && !hasDatabaseGate(ancestor)) ancestor = ancestor.getSuperclass();
                if (ancestor == null) continue;
                checked++;
                // JUnit's environment condition is not @Inherited. Spring's fixture annotations
                // can still inherit, so a missing condition accidentally starts a database in fast CI.
                if (!hasDatabaseGate(type)) missing.add(type.getName() + " extends " + ancestor.getName());
            }
        }
        assertThat(checked).as("database inheritance inventory").isGreaterThanOrEqualTo(60);
        assertThat(missing).as("concrete database tests must opt in before Spring fixtures start").isEmpty();
    }

    private static boolean hasDatabaseGate(Class<?> type) {
        return AnnotationSupport.findRepeatableAnnotations(type, EnabledIfEnvironmentVariable.class).stream()
                .anyMatch(gate -> gate.named().equals("UTEN_RUN_DB_TESTS")
                        && "true".matches(gate.matches()) && "TRUE".matches(gate.matches())
                        && !"false".matches(gate.matches()) && !"".matches(gate.matches()));
    }
}
