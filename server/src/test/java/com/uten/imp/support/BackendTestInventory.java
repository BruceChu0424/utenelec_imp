package com.uten.imp.support;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.platform.commons.support.AnnotationSupport;
import org.junit.platform.engine.discovery.ClassNameFilter;
import org.junit.platform.engine.discovery.DiscoverySelectors;
import org.junit.platform.engine.support.descriptor.ClassSource;
import org.junit.platform.engine.support.descriptor.MethodSource;
import org.junit.platform.launcher.TestIdentifier;
import org.junit.platform.launcher.TestPlan;
import org.junit.platform.launcher.core.LauncherDiscoveryRequestBuilder;
import org.junit.platform.launcher.core.LauncherFactory;

import java.lang.reflect.AnnotatedElement;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** Discovers compiled tests without running constructors, fixtures, conditions, or databases. */
public final class BackendTestInventory {
    private BackendTestInventory() {}

    public static void main(String[] args) throws Exception {
        if (args.length != 2) throw new IllegalArgumentException("test-classes directory and JSON output required");
        var classes = new ArrayList<Map<String, Object>>();
        // Match Maven's default top-level class includes; nested tests follow their enclosing class.
        discover(Path.of(args[0]), "surefire", "^(?:.*\\.)?(?:Test[^.$]*|[^.$]*Test|[^.$]*Tests|[^.$]*TestCase)$", classes);
        discover(Path.of(args[0]), "failsafe", "^(?:.*\\.)?(?:IT[^.$]*|[^.$]*IT|[^.$]*ITCase)$", classes);
        classes.sort(Comparator.comparing(row -> row.get("name").toString()));
        var output = Path.of(args[1]);
        Files.createDirectories(output.toAbsolutePath().getParent());
        new ObjectMapper().writerWithDefaultPrettyPrinter().writeValue(output.toFile(), Map.of("classes", classes));
    }

    private static void discover(Path root, String phase, String pattern, List<Map<String, Object>> result) {
        var request = LauncherDiscoveryRequestBuilder.request()
                .selectors(DiscoverySelectors.selectClasspathRoots(Set.of(root.toAbsolutePath())))
                .filters(ClassNameFilter.includeClassNamePatterns(pattern))
                .configurationParameter("junit.jupiter.execution.parallel.enabled", "false")
                .build();
        result.addAll(describe(LauncherFactory.create().discover(request), phase));
    }

    static List<Map<String, Object>> describe(TestPlan plan, String phase) {
        var result = new ArrayList<Map<String, Object>>();
        Map<String, List<Map<String, Object>>> byClass = new LinkedHashMap<>();
        for (var engine : plan.getRoots()) {
            if (!engine.getUniqueId().equals("[engine:junit-jupiter]")) {
                throw new IllegalStateException("Inventory support required for engine: " + engine.getUniqueId());
            }
            for (var id : plan.getDescendants(engine)) {
                if (!(id.getSource().orElse(null) instanceof MethodSource source)) continue;
                // A template/factory is a method container, populated only during execution.
                // Keep it in the inventory so a missing parameterized/factory method cannot go green.
                String owner = null;
                String actualClass = null;
                var parent = plan.getParent(id);
                while (parent.isPresent()) {
                    if (parent.get().getSource().orElse(null) instanceof ClassSource classSource) {
                        owner = classSource.getClassName();
                        if (actualClass == null) actualClass = owner;
                    }
                    parent = plan.getParent(parent.get());
                }
                if (owner == null || actualClass == null) throw new IllegalStateException("No owning class: " + id);
                var gates = new LinkedHashSet<String>();
                addGate(source.getJavaMethod(), gates);
                for (Class<?> current = source.getJavaMethod().getDeclaringClass(); current != null; current = current.getEnclosingClass()) {
                    addGate(current, gates);
                }
                try {
                    for (Class<?> current = Class.forName(actualClass, false, Thread.currentThread().getContextClassLoader());
                            current != null; current = current.getEnclosingClass()) addGate(current, gates);
                } catch (ClassNotFoundException exception) {
                    throw new IllegalStateException(exception);
                }
                var method = new LinkedHashMap<String, Object>();
                method.put("id", actualClass + "#" + source.getMethodName());
                method.put("class", actualClass);
                method.put("method", source.getMethodName());
                method.put("parameters", source.getMethodParameterTypes());
                method.put("kind", id.isTest() ? "test" : "template");
                method.put("unique_id", id.getUniqueId());
                method.put("environment_gates", gates.stream().sorted().toList());
                byClass.computeIfAbsent(owner, ignored -> new ArrayList<>()).add(method);
            }
        }
        byClass.forEach((name, methods) -> {
            methods.sort(Comparator.comparing(row -> row.get("id").toString()));
            result.add(Map.of("name", name, "phase", phase, "methods", methods));
        });
        return result;
    }

    private static void addGate(AnnotatedElement element, Set<String> gates) {
        AnnotationSupport.findRepeatableAnnotations(element, EnabledIfEnvironmentVariable.class)
                .forEach(annotation -> gates.add(annotation.named()));
    }
}
