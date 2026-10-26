package com.uten.imp.features.sales.order.dto;

import jakarta.validation.constraints.Size;
import java.util.UUID;

/** Read-only filters shared by paged browsing and complete, bounded selection. */
public record ShippableLineFilter(@Size(max = 200) String keyword, UUID clientId) { }
