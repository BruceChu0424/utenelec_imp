package com.uten.imp.features.webinquiry.dto;

import java.time.Instant;
import java.util.UUID;

public record InquiryTimelineEntry(UUID id,String kind,String note,String actorName,
                                   String actorEmployeeCode,Instant createdAt) {}
