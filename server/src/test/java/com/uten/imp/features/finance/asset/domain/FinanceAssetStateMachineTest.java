package com.uten.imp.features.finance.asset.domain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class FinanceAssetStateMachineTest {

    @Test
    void acceptsOnlyTheExplicitObjectWorkflow() {
        assertThatCode(() -> FinanceAssetStateMachine.requireObjectTransition("DRAFT", "PENDING_APPROVAL"))
                .doesNotThrowAnyException();
        assertThatCode(() -> FinanceAssetStateMachine.requireObjectTransition("PENDING_APPROVAL", "APPROVED"))
                .doesNotThrowAnyException();
        assertThatCode(() -> FinanceAssetStateMachine.requireObjectTransition("APPROVED", "ACTIVE"))
                .doesNotThrowAnyException();
    }

    @Test
    void activeObjectCannotReturnToEditableDraft() {
        assertConflict(() -> FinanceAssetStateMachine.requireObjectTransition("ACTIVE", "DRAFT"));
        assertConflict(() -> FinanceAssetStateMachine.requireDraft("ACTIVE"));
    }

    @Test
    void disposalAndTerminationAreExplicitTwoStepWorkflows() {
        assertThatCode(() -> FinanceAssetStateMachine.requireObjectTransition("ACTIVE", "DISPOSAL_PENDING"))
                .doesNotThrowAnyException();
        assertThatCode(() -> FinanceAssetStateMachine.requireObjectTransition("DISPOSAL_PENDING", "DISPOSED"))
                .doesNotThrowAnyException();
        assertThatCode(() -> FinanceAssetStateMachine.requireObjectTransition("ACTIVE", "TERMINATION_PENDING"))
                .doesNotThrowAnyException();
        assertThatCode(() -> FinanceAssetStateMachine.requireObjectTransition("TERMINATION_PENDING", "TERMINATED"))
                .doesNotThrowAnyException();
        assertThatCode(() -> FinanceAssetStateMachine.requireObjectTransition("TERMINATION_PENDING", "COMPLETED"))
                .doesNotThrowAnyException();
    }

    @Test
    void postedRunCanOnlyBeReversedNeverRebuilt() {
        assertThatCode(() -> FinanceAssetStateMachine.requireRunTransition("POSTED", "REVERSED"))
                .doesNotThrowAnyException();
        assertConflict(() -> FinanceAssetStateMachine.requireRunTransition("POSTED", "PREVIEWED"));
    }

    private static void assertConflict(org.assertj.core.api.ThrowableAssert.ThrowingCallable call) {
        assertThatThrownBy(call)
                .isInstanceOfSatisfying(ApiException.class,
                        exception -> assertThat(exception.getCode()).isEqualTo(ErrorCode.CONFLICT));
    }
}
