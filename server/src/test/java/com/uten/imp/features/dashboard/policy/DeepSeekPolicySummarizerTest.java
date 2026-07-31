package com.uten.imp.features.dashboard.policy;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.config.props.PolicyIntelligenceProperties;
import org.junit.jupiter.api.Test;

import java.time.LocalDate;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class DeepSeekPolicySummarizerTest {

    private final DeepSeekPolicySummarizer summarizer =
            new DeepSeekPolicySummarizer(
                    new PolicyIntelligenceProperties(),
                    new ObjectMapper());

    @Test
    void parsesAndRestrictsStructuredOfficialSummary() {
        DeepSeekPolicySummarizer.Summary result = summarizer.parse("""
                {
                  "relevant": true,
                  "title": "制造业税费支持措施",
                  "summary": "企业需按资格条件逐项核验。",
                  "category": "TAX",
                  "audienceTags": ["FINANCE", "GM", "UNTRUSTED"],
                  "publishedOn": "2026-04-02",
                  "validUntil": null
                }
                """);

        assertThat(result.relevant()).isTrue();
        assertThat(result.category()).isEqualTo("TAX");
        assertThat(result.audienceTags()).containsExactlyInAnyOrder("FINANCE", "GM");
        assertThat(result.publishedOn()).isEqualTo(LocalDate.of(2026, 4, 2));
        assertThat(result.validUntil()).isNull();
    }

    @Test
    void rejectsRelevantSummaryWithoutVerifiablePublicationDate() {
        assertThatThrownBy(() -> summarizer.parse("""
                {
                  "relevant": true,
                  "title": "某政策",
                  "summary": "某摘要",
                  "category": "SUBSIDY",
                  "audienceTags": ["FINANCE"],
                  "publishedOn": "not-a-date"
                }
                """))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("有效 JSON");
    }

    @Test
    void irrelevantDocumentDoesNotCreateAudienceOrFacts() {
        DeepSeekPolicySummarizer.Summary result =
                summarizer.parse("{\"relevant\":false}");

        assertThat(result.relevant()).isFalse();
        assertThat(result.audienceTags()).isEqualTo(Set.of());
        assertThat(result.publishedOn()).isNull();
    }
}
