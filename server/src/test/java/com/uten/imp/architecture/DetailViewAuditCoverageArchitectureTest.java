package com.uten.imp.architecture;

import com.uten.imp.audit.AuditEventInterpreter;
import com.uten.imp.audit.AuditLog;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
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
    void everyExplicitDetailActionHasSpecificChineseCurrentAndHistoryLabels()
            throws Exception {
        Set<String> actions = new LinkedHashSet<>();
        for (Path controller : controllerSources()) {
            String source = Files.readString(controller, StandardCharsets.UTF_8);
            Matcher matcher = DETAIL_ACTION.matcher(source);
            while (matcher.find()) {
                actions.add(matcher.group(1));
            }
        }
        assertTrue(actions.size() >= 58, "detail action inventory unexpectedly shrank");

        AuditEventInterpreter interpreter = new AuditEventInterpreter();
        for (String action : actions) {
            String current = actionLabel(interpreter, action);
            assertFalse("其他操作".equals(current), action);
            assertFalse("查看详情".equals(current),
                    action + " must have a specific Chinese subject");
            assertFalse(current.contains("_"), action);

            String history = actionLabel(interpreter, action + "_history");
            assertFalse("查看历史资料".equals(history),
                    action + " history must have a specific Chinese subject");
            assertFalse(history.contains("_"), action);
        }
    }

    private String actionLabel(AuditEventInterpreter interpreter, String action) {
        AuditLog value = new AuditLog();
        value.setAction(action);
        value.setTargetType("coverage_target");
        value.setEventSource("business");
        value.setResult("success");
        return interpreter.interpret(value).actionLabel();
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
