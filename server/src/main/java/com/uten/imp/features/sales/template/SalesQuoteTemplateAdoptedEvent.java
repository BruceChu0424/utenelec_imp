package com.uten.imp.features.sales.template;

import java.util.UUID;

/** A separately confirmed customer layout. This event must never trigger master-data learning. */
public record SalesQuoteTemplateAdoptedEvent(UUID jobId, UUID actorId, UUID quoteId, UUID clientId) { }
