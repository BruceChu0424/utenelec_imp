package com.uten.imp.features.admin.serverstatus;

import ch.qos.logback.classic.Level;
import ch.qos.logback.classic.LoggerContext;
import ch.qos.logback.classic.spi.ILoggingEvent;
import ch.qos.logback.core.AppenderBase;
import io.micrometer.core.instrument.Counter;
import io.micrometer.core.instrument.MeterRegistry;
import org.slf4j.LoggerFactory;

import java.util.concurrent.atomic.AtomicLong;
import java.util.function.DoubleSupplier;

/**
 * Cumulative count of ERROR log events since JVM start.
 *
 * <p>Prefers the Micrometer {@code logback.events{level=error}} counter that Boot's
 * {@code LogbackMetricsAutoConfiguration} registers; if that meter is absent a private
 * counting appender is attached to the Logback root logger once. Returns NaN when neither
 * source exists so the probe reports UNKNOWN instead of a false zero.</p>
 */
final class ErrorLogEventCounter implements DoubleSupplier {
    private static final String APPENDER_NAME = "server-status-error-counter";
    private final MeterRegistry meters;
    private volatile CountingAppender fallback;
    private volatile boolean fallbackUnavailable;

    ErrorLogEventCounter(MeterRegistry meters) { this.meters = meters; }

    @Override public double getAsDouble() {
        Counter counter = meters == null ? null : meters.find("logback.events").tag("level", "error").counter();
        if (counter != null) return counter.count();
        CountingAppender appender = fallback();
        return appender == null ? Double.NaN : appender.errors.get();
    }

    private CountingAppender fallback() {
        CountingAppender current = fallback;
        if (current != null || fallbackUnavailable) return current;
        synchronized (this) {
            if (fallback != null || fallbackUnavailable) return fallback;
            try {
                if (LoggerFactory.getILoggerFactory() instanceof LoggerContext context) {
                    CountingAppender appender = new CountingAppender();
                    appender.setContext(context);
                    appender.setName(APPENDER_NAME);
                    appender.start();
                    context.getLogger(org.slf4j.Logger.ROOT_LOGGER_NAME).addAppender(appender);
                    fallback = appender;
                } else {
                    fallbackUnavailable = true;
                }
            } catch (RuntimeException | LinkageError unavailable) {
                fallbackUnavailable = true;
            }
            return fallback;
        }
    }

    private static final class CountingAppender extends AppenderBase<ILoggingEvent> {
        private final AtomicLong errors = new AtomicLong();
        @Override protected void append(ILoggingEvent event) {
            if (event.getLevel() != null && event.getLevel().isGreaterOrEqual(Level.ERROR)) errors.incrementAndGet();
        }
    }
}
