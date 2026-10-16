package com.uten.imp.audit;

import org.junit.jupiter.api.Test;
import static org.assertj.core.api.Assertions.*;

class ServerOperationsAuditClassificationTest {
    @Test void smsConfigurationWritesAreHighRiskSystemEvents() {
        var result=AuditClassifier.classify("business","sms_settings.update","sms_gateway_settings",null,"success",200);
        assertThat(result.eventCategory()).isEqualTo("system");assertThat(result.riskLevel()).isEqualTo("high");
    }
    @Test void writesAndCleanupAreHighRiskSystemEventsWhileReadOnlyCheckIsNotDisguisedAsAnInstall() {
        for(String action:java.util.List.of("server_source_save","server_update_start","server_update_cancel","server_cleanup")) {
            var result=AuditClassifier.classify("business",action,"server_operations",null,"success",200);
            assertThat(result.eventCategory()).isEqualTo("system");assertThat(result.riskLevel()).isEqualTo("high");
        }
        var check=AuditClassifier.classify("business","server_update_check","server_operations",null,"success",202);
        assertThat(check.eventCategory()).isEqualTo("system");assertThat(check.riskLevel()).isEqualTo("low");
    }
    @Test void fallbackHttpSemanticEventsKeepSystemRiskEvenWhenExplicitAuditSinkFailed() {
        for(String action:java.util.List.of("server_operations.save","server_operations.start","server_storage.delete")) {
            var result=AuditClassifier.classify("business",action,"server_operations",null,"success",200);
            assertThat(result.eventCategory()).isEqualTo("system");assertThat(result.riskLevel()).isEqualTo("high");
        }
    }
}
