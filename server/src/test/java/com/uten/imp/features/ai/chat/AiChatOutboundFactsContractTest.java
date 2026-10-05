package com.uten.imp.features.ai.chat;

import com.uten.imp.application.port.AiChatToolPort;
import org.junit.jupiter.api.Test;
import org.springframework.context.annotation.ClassPathScanningCandidateComponentProvider;
import org.springframework.core.type.filter.AssignableTypeFilter;

import java.util.Map;
import java.util.Set;
import java.util.TreeSet;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * ADR-150 outbound inventory: only tools registered in 中国大陆部署与兼容性 2.3.1 may project facts to the
 * model. Every AiChatToolPort implementation in the application is scanned (including subclasses of a
 * registered tool); cost, credit, HR and authorization tools keep the empty default, so their results
 * stay local. Registering a new sharing tool means updating 2.3.1 and this list together.
 */
class AiChatOutboundFactsContractTest {
    private static final Set<String> REGISTERED_SHARING_TOOLS = Set.of(
            "com.uten.imp.features.dashboard.DashboardAiChatTool",
            "com.uten.imp.features.workbench.badge.WorkbenchAiChatTool",
            "com.uten.imp.features.production.execution.ProductionAiChatTool",
            "com.uten.imp.features.stock.InventoryAiChatTool");

    @Test void onlyRegisteredToolsProjectModelFacts() throws Exception {
        var scanner = new ClassPathScanningCandidateComponentProvider(false);
        scanner.addIncludeFilter(new AssignableTypeFilter(AiChatToolPort.class));
        Set<String> all = new TreeSet<>();
        Set<String> sharing = new TreeSet<>();
        for (var candidate : scanner.findCandidateComponents("com.uten.imp")) {
            Class<?> type = Class.forName(candidate.getBeanClassName());
            all.add(type.getName());
            if (projectsModelFacts(type)) sharing.add(type.getName());
        }
        assertThat(all).as("the scan sees the local tools too")
                .contains("com.uten.imp.features.master.goods.costing.AiGoodsCostTool",
                        "com.uten.imp.features.master.client.AiClientCreditTool",
                        "com.uten.imp.features.org.hrtask.HrTasksAiChatTool",
                        "com.uten.imp.features.admin.AiPermissionGrantTool");
        assertThat(sharing).isEqualTo(REGISTERED_SHARING_TOOLS);
    }

    /** True when the class or any superclass below the interface overrides modelFacts. */
    private static boolean projectsModelFacts(Class<?> type) {
        for (Class<?> current = type; current != null && current != Object.class; current = current.getSuperclass()) {
            try {
                current.getDeclaredMethod("modelFacts", Map.class);
                return true;
            } catch (NoSuchMethodException absent) {
                // keep walking up
            }
        }
        return false;
    }
}
