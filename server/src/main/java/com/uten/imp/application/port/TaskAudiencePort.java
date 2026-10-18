package com.uten.imp.application.port;

import java.util.function.Supplier;

/**
 * Runs a business-task read with actually granted authority and responsibility scope.
 * Administrative capability is deliberately not a subscription to every business task.
 */
public interface TaskAudiencePort {
    <T> T read(Supplier<T> work);
}
