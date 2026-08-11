package com.uten.imp.features.org.employee.dto;

import java.time.LocalDate;

/** 转正办理（ADR-021）：confirmedDate 为空默认今天；不得晚于今天、早于入职日期。 */
public record ConfirmRequest(LocalDate confirmedDate) {}
