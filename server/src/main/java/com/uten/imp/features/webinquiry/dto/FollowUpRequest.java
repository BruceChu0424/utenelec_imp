package com.uten.imp.features.webinquiry.dto;

import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record FollowUpRequest(@NotBlank @Size(max=1000) String note) {}
