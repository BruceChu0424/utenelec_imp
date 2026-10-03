package com.uten.imp.features.ai.chat;

import com.uten.imp.application.port.AiChatToolPort;
import com.uten.imp.security.AiChatAccessPolicy;
import org.springframework.stereotype.Component;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

@Component
public class AiChatToolRegistry {
    private final Map<String, AiChatToolPort> tools = new LinkedHashMap<>();
    private final AiChatAccessPolicy access;
    public AiChatToolRegistry(List<AiChatToolPort> ports, AiChatAccessPolicy access) {
        this.access = access;
        for (AiChatToolPort tool : ports) {
            if (!tool.name().matches("[A-Za-z][A-Za-z0-9_]{1,47}") || tools.putIfAbsent(tool.name(), tool) != null)
                throw new IllegalStateException("Invalid or duplicate chat tool");
        }
    }
    public List<AiChatToolPort> available() {
        Set<String> domains = access.domains();
        return tools.values().stream().filter(tool -> domains.contains(tool.domain()) && tool.available()).toList();
    }
    public Optional<AiChatToolPort> available(String name) { return available().stream().filter(tool -> tool.name().equals(name)).findFirst(); }
}
