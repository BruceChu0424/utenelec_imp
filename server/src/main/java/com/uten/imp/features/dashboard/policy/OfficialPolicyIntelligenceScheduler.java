package com.uten.imp.features.dashboard.policy;

import lombok.RequiredArgsConstructor;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Component
@RequiredArgsConstructor
@ConditionalOnProperty(
        name = "uten.policy-intelligence.enabled",
        havingValue = "true")
public class OfficialPolicyIntelligenceScheduler {

    private final OfficialPolicyIntelligenceService service;

    @Scheduled(
            cron = "${uten.policy-intelligence.refresh-cron:0 15 6 * * *}",
            zone = "Asia/Shanghai")
    public void refresh() {
        service.refresh();
    }
}
