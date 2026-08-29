package com.uten.imp.features.master.account.dto;

import jakarta.validation.constraints.Digits;

import java.math.BigDecimal;

/** Updates the optional warning floor; {@code null} explicitly clears it. */
public record AccountWarningUpdateRequest(
        @Digits(integer = 14, fraction = 4) BigDecimal balanceFloor) {
}
