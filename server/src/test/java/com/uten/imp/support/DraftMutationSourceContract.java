package com.uten.imp.support;

import com.sun.source.tree.IfTree;
import com.sun.source.tree.MethodTree;
import com.sun.source.tree.MethodInvocationTree;
import com.sun.source.util.JavacTask;
import com.sun.source.util.TreeScanner;
import com.sun.source.util.Trees;

import javax.tools.SimpleJavaFileObject;
import javax.tools.ToolProvider;
import java.net.URI;
import java.util.ArrayList;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/** Checks the two authorization paths after a public update delegates to its draft kernel. */
public final class DraftMutationSourceContract {
    private DraftMutationSourceContract() { }

    public static String ordinaryUpdateBody(String source) {
        String entry = method(source, "update");
        assertThat(entry).contains("return updateDraft(id, req, false, null);");
        assertOrdinaryAndReviewedBranches(source);
        return method(source, "updateDraft");
    }

    public static void assertOrdinaryAndReviewedBranches(String source) {
        Parsed parsed = parse(source);
        MethodTree kernel = parsed.methods().stream()
                .filter(method -> method.getName().contentEquals("updateDraft"))
                .findFirst().orElseThrow();
        List<IfTree> switches = new ArrayList<>();
        new TreeScanner<Void, Void>() {
            @Override public Void visitIf(IfTree node, Void unused) {
                String condition = node.getCondition().toString();
                // The daily-report kernel also uses this flag to protect its worker
                // identity and editable fields. Select the authorization split only.
                if ((condition.equals("(review)") || condition.equals("(reviewed)"))
                        && invokes(node.getThenStatement(), "requireReviewer")) switches.add(node);
                return super.visitIf(node, unused);
            }
        }.scan(kernel.getBody(), null);
        assertThat(switches).as("explicit internal review flag, never a caller-controlled OR shortcut").hasSize(1);
        IfTree branch = switches.getFirst();
        assertThat(branch.getElseStatement()).as("ordinary draft path must retain its owner write guard").isNotNull();
        assertThat(branch.getElseStatement().toString())
                .contains("access.requireWritable(")
                .doesNotContain("requireReviewer", "requireScopedOperationWritable");
        assertThat(branch.getThenStatement().toString())
                .contains("requireReviewer(", "requireCurrent(", "expectedSnapshot");
        MethodTree reviewed = parsed.methods().stream()
                .filter(method -> method.getName().contentEquals("saveReviewedDraft")).findFirst().orElseThrow();
        assertThat(parsed.text(reviewed)).contains(":view", ":approve");
        List<MethodInvocationTree> dispatches = new ArrayList<>();
        new TreeScanner<Void, Void>() {
            @Override public Void visitMethodInvocation(MethodInvocationTree node, Void unused) {
                if (node.getMethodSelect().toString().equals("updateDraft")) dispatches.add(node);
                return super.visitMethodInvocation(node, unused);
            }
        }.scan(reviewed.getBody(), null);
        assertThat(dispatches).as("the protected review endpoint dispatches once to the same kernel").hasSize(1);
        assertThat(dispatches.getFirst().getArguments().stream().map(Object::toString).toList())
                .containsExactly(reviewed.getParameters().get(0).getName().toString(),
                        reviewed.getParameters().get(1).getName().toString(), "true",
                        reviewed.getParameters().get(2).getName().toString());
    }

    private static boolean invokes(com.sun.source.tree.Tree tree, String name) {
        boolean[] result = {false};
        new TreeScanner<Void, Void>() {
            @Override public Void visitMethodInvocation(MethodInvocationTree node, Void unused) {
                String selected = node.getMethodSelect().toString();
                if (selected.equals(name) || selected.endsWith("." + name)) result[0] = true;
                return super.visitMethodInvocation(node, unused);
            }
        }.scan(tree, null);
        return result[0];
    }

    public static String method(String source, String name) {
        Parsed parsed = parse(source);
        MethodTree method = parsed.methods().stream().filter(item -> item.getName().contentEquals(name))
                .findFirst().orElseThrow(() -> new AssertionError("Missing declaration: " + name));
        return parsed.text(method);
    }

    public static String methodContaining(String source, String name, String requiredText) {
        Parsed parsed = parse(source);
        return parsed.methods().stream().filter(method -> method.getName().contentEquals(name))
                .map(parsed::text).filter(text -> text.contains(requiredText)).findFirst()
                .orElseThrow(() -> new AssertionError("Missing declaration/body: " + name + ": " + requiredText));
    }

    public static String expandUnapprovalAuthorization(String source, String command) {
        // Follow these exact guarded reversal calls, rather than accepting a helper name
        // as evidence of authorization. The guard body is checked at its call position.
        for (String guard : List.of("requireUnapprovalHeader", "requireInquiryReversible", "requireIssueReversible")) {
            var invocation = java.util.regex.Pattern.compile(guard + "\\([a-zA-Z]+(?:\\s*,\\s*[a-zA-Z]+)?\\);").matcher(command);
            if (invocation.find()) return command.substring(0, invocation.start()) + method(source, guard)
                    + command.substring(invocation.end());
        }
        return command;
    }

    public static List<String> methodNamesCalling(String source, String invocation) {
        Parsed parsed = parse(source);
        return parsed.methods().stream().filter(method -> parsed.text(method).contains(invocation))
                .map(method -> method.getName().toString()).toList();
    }

    public static List<String> methodNamesInvoking(String source, String invocation) {
        Parsed parsed = parse(source);
        List<String> result = new ArrayList<>();
        for (MethodTree method : parsed.methods()) {
            boolean[] calls = {false};
            new TreeScanner<Void, Void>() {
                @Override public Void visitMethodInvocation(MethodInvocationTree node, Void unused) {
                    String selected = node.getMethodSelect().toString();
                    if (selected.equals(invocation) || selected.endsWith("." + invocation)) calls[0] = true;
                    return super.visitMethodInvocation(node, unused);
                }
            }.scan(method.getBody(), null);
            if (calls[0]) result.add(method.getName().toString());
        }
        return result;
    }

    private static Parsed parse(String source) {
        var compiler = ToolProvider.getSystemJavaCompiler();
        assertThat(compiler).as("source contracts require the configured JDK, not a JRE").isNotNull();
        var file = new SimpleJavaFileObject(URI.create("string:///Contract.java"), javax.tools.JavaFileObject.Kind.SOURCE) {
            @Override public CharSequence getCharContent(boolean ignoreErrors) { return source; }
        };
        try {
            var task = (JavacTask) compiler.getTask(null, null, null, List.of("-proc:none"), null, List.of(file));
            var unit = task.parse().iterator().next();
            var positions = Trees.instance(task).getSourcePositions();
            List<MethodTree> methods = new ArrayList<>();
            new TreeScanner<Void, Void>() {
                @Override public Void visitMethod(MethodTree method, Void unused) {
                    if (method.getBody() != null) methods.add(method);
                    return super.visitMethod(method, unused);
                }
            }.scan(unit, null);
            return new Parsed(source, unit, positions, methods);
        } catch (java.io.IOException exception) {
            throw new IllegalStateException("Could not parse source contract", exception);
        }
    }

    private record Parsed(String source, com.sun.source.tree.CompilationUnitTree unit,
                          com.sun.source.util.SourcePositions positions, List<MethodTree> methods) {
        String text(MethodTree method) {
            return source.substring((int) positions.getStartPosition(unit, method),
                    (int) positions.getEndPosition(unit, method));
        }
    }
}
