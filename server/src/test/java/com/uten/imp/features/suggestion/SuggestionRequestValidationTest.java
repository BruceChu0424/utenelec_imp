package com.uten.imp.features.suggestion;

import com.uten.imp.features.suggestion.dto.SuggestionReplyRequest;
import com.uten.imp.features.suggestion.dto.SuggestionSubmitRequest;
import jakarta.validation.Validation;
import jakarta.validation.Validator;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class SuggestionRequestValidationTest {

    private final Validator validator = Validation.buildDefaultValidatorFactory().getValidator();

    @Test
    void acceptsDocumentedSuggestionAndReplyPayloads() {
        assertTrue(validator.validate(new SuggestionSubmitRequest(
                "process", "优化审批流程", "建议减少重复录入并保留完整审批记录。", false)).isEmpty());
        assertTrue(validator.validate(new SuggestionReplyRequest(
                "已安排流程负责人评估。", "reviewing")).isEmpty());
        assertTrue(validator.validate(new SuggestionReplyRequest(
                "补充当前处理进度。", null)).isEmpty());
    }

    @Test
    void rejectsShortSuggestionAndUnsupportedReplyState() {
        assertFalse(validator.validate(new SuggestionSubmitRequest(
                "process", "优化审批流程", "内容太短", false)).isEmpty());
        assertFalse(validator.validate(new SuggestionReplyRequest(
                "回复内容", "submitted")).isEmpty());
    }

    @Test
    void rejectsOversizedUntrustedText() {
        assertFalse(validator.validate(new SuggestionSubmitRequest(
                "other", "x".repeat(201), "y".repeat(10), false)).isEmpty());
        assertFalse(validator.validate(new SuggestionReplyRequest(
                "x".repeat(5_001), "resolved")).isEmpty());
    }
}
