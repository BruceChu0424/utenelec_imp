package com.uten.imp.features.production.dailyreport.dto;

import com.fasterxml.jackson.annotation.JsonInclude;
import java.util.UUID;

/** Exact draft reservation evidence, without loading a report's full detail. */
@JsonInclude(JsonInclude.Include.ALWAYS)
public record DailyReportDraftClaim(UUID executionSegmentId, String qty, boolean actualSurplus) { }
