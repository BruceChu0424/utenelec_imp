package com.uten.imp.features.production.dailyreport.dto;

import java.util.List;
import java.util.UUID;

/** A bounded selection of accepted task identities; never a reporting-eligibility query. */
public record DailyReportDraftClaimsQuery(List<UUID> executionSegmentIds, Integer page, Integer size) { }
