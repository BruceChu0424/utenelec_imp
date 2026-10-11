package com.uten.imp.features.production.dailyreport.dto;

import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import java.util.UUID;

/** One reviewed demand, not a client-supplied quantity or stock source. */
public record DailyReportMaterialDecision(
        @NotNull UUID demandId,
        @NotNull @Pattern(regexp = "KEEP|RETURN") String action) { }
