package com.uten.imp.common.finance;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import static org.assertj.core.api.Assertions.*;

class ActualBankBookingPolicyTest {
    private static final Instant NOW=Instant.parse("2026-11-04T12:00:00Z");

    @Test void equalityAndTheSameInstantInAnotherOffsetAreAlreadyOccurred() {
        assertThatCode(()->ActualBankBookingPolicy.requireOccurred(NOW.atOffset(ZoneOffset.UTC),NOW,"实际到账时间")).doesNotThrowAnyException();
        assertThatCode(()->ActualBankBookingPolicy.requireOccurred(NOW.atOffset(ZoneOffset.ofHours(14)),NOW,"实际到账时间")).doesNotThrowAnyException();
    }
    @Test void aLaterLocalCalendarDateCanStillBeAnAlreadyOccurredInstant() {
        var actual=OffsetDateTime.parse("2026-11-05T01:00:00+14:00");
        assertThatCode(()->ActualBankBookingPolicy.requireOccurred(actual,NOW,"实际到账时间")).doesNotThrowAnyException();
    }
    @Test void anEarlierLocalClockValueCannotDisguiseAFutureInstant() {
        var future=OffsetDateTime.parse("2026-11-04T01:00:00-12:00");
        assertThatThrownBy(()->ActualBankBookingPolicy.requireOccurred(future,NOW,"实际扣款时间"))
                .isInstanceOf(ApiException.class).hasMessageContaining("实际扣款时间尚未发生");
        assertThat(future.toString()).isEqualTo("2026-11-04T01:00-12:00");
    }
    @Test void missingActualEvidenceCannotBeInventedAtApproval() {
        assertThatThrownBy(()->ActualBankBookingPolicy.requireOccurred(null,NOW,"实际到账时间"))
                .isInstanceOf(ApiException.class).hasMessageContaining("必须填写");
    }
}
