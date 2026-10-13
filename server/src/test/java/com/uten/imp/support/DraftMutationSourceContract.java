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

/** Exact AST checks for native maker saves and source-preserving mutation boundaries. */
public final class DraftMutationSourceContract {
    private DraftMutationSourceContract() { }

    public static String ordinaryUpdateBody(String source) {
        String entry = method(source, "update");
        assertThat(entry).contains("access.requireWritable(").doesNotContain("requireReviewer(");
        assertThat(parse(source).methods().stream().map(method -> method.getName().toString()))
                .doesNotContain("updateReviewed", "saveReviewedDraft");
        return entry;
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
