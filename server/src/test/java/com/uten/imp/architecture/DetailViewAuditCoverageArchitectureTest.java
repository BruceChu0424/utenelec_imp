package com.uten.imp.architecture;

import com.uten.imp.audit.AuditEventInterpreter;
import com.uten.imp.audit.AuditLog;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class DetailViewAuditCoverageArchitectureTest {

    private static final Path FEATURES =
            Path.of("src/main/java/com/uten/imp/features");
    private static final Pattern TERMINAL_ID_GET = Pattern.compile(
            "@GetMapping\\(\\\"[^\\\"]*\\{id}\\\"\\)");
    private static final Pattern DETAIL_ACTION = Pattern.compile(
            "\\\"(view_[a-z0-9_]+_detail)\\\"");
    private static final Pattern DETAIL_RECORD = Pattern.compile(
            "\\.record\\(\\s*\\\"(view_[a-z0-9_]+_detail)\\\""
                    + "\\s*,\\s*\\\"([a-z0-9_]+)\\\"",
            Pattern.DOTALL);

    @Test
    void everyTerminalUuidDetailGetHasExplicitAuditOrReviewedSemanticReplacement()
            throws Exception {
        List<Path> controllers = controllerSources();
        int terminalEndpointCount = 0;
        int explicitlyAuditedCount = 0;

        for (Path controller : controllers) {
            String source = Files.readString(controller, StandardCharsets.UTF_8);
            Matcher endpoints = TERMINAL_ID_GET.matcher(source);
            int inFile = 0;
            while (endpoints.find()) {
                inFile++;
            }
            if (inFile == 0) {
                continue;
            }
            terminalEndpointCount += inFile;
            String normalizedPath = controller.toString().replace('\\', '/');
            if (normalizedPath.endsWith("/notice/NoticeController.java")) {
                assertFalse(source.contains("AuditDetailViewRecorder"),
                        "notification detail must keep one view_notice semantic event");
                continue;
            }
            assertTrue(source.contains("AuditDetailViewRecorder"),
                    () -> "missing explicit detail-view audit dependency: " + controller);
            assertTrue(DETAIL_ACTION.matcher(source).find(),
                    () -> "missing stable view_*_detail action: " + controller);
            explicitlyAuditedCount += inFile;
        }

        assertTrue(terminalEndpointCount >= 60,
                "terminal detail endpoint inventory unexpectedly shrank");
        assertTrue(explicitlyAuditedCount >= 59,
                "explicit detail-view coverage unexpectedly shrank");

        String noticeService = Files.readString(
                FEATURES.resolve("notice/NoticeService.java"),
                StandardCharsets.UTF_8);
        assertTrue(noticeService.contains("auditExplicit(\"view_notice\""),
                "NoticeController exemption requires the existing view_notice event");
    }

    @Test
    void everyExplicitDetailRecordHasSpecificChineseObjectActionAndReferenceSummary()
            throws Exception {
        Map<String, String> actionTargets = new LinkedHashMap<>();
        for (Path controller : controllerSources()) {
            String source = Files.readString(controller, StandardCharsets.UTF_8);
            Matcher matcher = DETAIL_RECORD.matcher(source);
            while (matcher.find()) {
                String action = matcher.group(1);
                String targetType = matcher.group(2);
                String previous = actionTargets.putIfAbsent(action, targetType);
                assertTrue(previous == null || previous.equals(targetType),
                        () -> action + " uses conflicting target types: "
                                + previous + " / " + targetType);
            }
        }
        assertTrue(actionTargets.size() >= 58,
                "detail action/target inventory unexpectedly shrank");

        AuditEventInterpreter interpreter = new AuditEventInterpreter();
        for (Map.Entry<String, String> entry : actionTargets.entrySet()) {
            String action = entry.getKey();
            String targetType = entry.getValue();
            AuditEventInterpreter.InterpretedEvent current = interpretDetail(
                    interpreter, action, targetType, "业务编号 TEST-001");
            assertFalse("其他操作".equals(current.actionLabel()), action);
            assertFalse("查看详情".equals(current.actionLabel()),
                    action + " must have a specific Chinese subject");
            assertFalse(current.actionLabel().contains("_"), action);
            assertFalse(current.objectLabel().isBlank(),
                    action + " / " + targetType + " has no Chinese object label");
            assertFalse("其他业务对象".equals(current.objectLabel()),
                    action + " / " + targetType);
            assertFalse(current.objectLabel().contains("_"), targetType);
            assertTrue(current.summary().contains("业务编号 TEST-001"),
                    () -> action + " summary lost the business reference: "
                            + current.summary());
            assertFalse(current.summary().contains("其他业务对象"), current.summary());

            AuditEventInterpreter.InterpretedEvent history = interpretDetail(
                    interpreter,
                    action + "_history",
                    targetType,
                    "业务编号 TEST-001(旧系统编号 88)");
            assertFalse("查看历史资料".equals(history.actionLabel()),
                    action + " history must have a specific Chinese subject");
            assertFalse(history.actionLabel().contains("_"), action);
            assertTrue(history.actionLabel().contains("历史"), history.actionLabel());
            assertTrue(history.summary().contains("业务编号 TEST-001"),
                    history.summary());
            assertTrue(history.summary().contains("旧系统编号 88"),
                    history.summary());
            assertFalse(history.summary().contains("其他业务对象"), history.summary());
        }
    }

    private AuditEventInterpreter.InterpretedEvent interpretDetail(
            AuditEventInterpreter interpreter,
            String action,
            String targetType,
            String displayName) {
        AuditLog value = new AuditLog();
        value.setAction(action);
        value.setTargetType(targetType);
        value.setEventSource("business");
        value.setResult("success");
        value.setAfter("{\"view_metadata_kind\":\"business_detail_view\","
                + "\"view_display_name\":\"" + displayName + "\"}");
        return interpreter.interpret(value);
    }

    private List<Path> controllerSources() throws IOException {
        try (var stream = Files.walk(FEATURES)) {
            return stream
                    .filter(Files::isRegularFile)
                    .filter(path -> path.getFileName().toString().endsWith("Controller.java"))
                    .sorted()
                    .toList();
        }
    }
}
