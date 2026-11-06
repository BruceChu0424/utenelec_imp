package com.uten.imp.features.finance.statement;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.finance.FinancialJsonResults;
import com.uten.imp.common.read.VersionedReadSnapshotCache;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.TxSessionVars;
import jakarta.annotation.PreDestroy;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Component;

import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Supplier;

/** Immutable original facts only. The caller MUST freshly authorize and read
 * current public review/confirmation metadata before every call, including hits.
 * No permission, mutable footer, command outcome or plaintext file is cached. */
@Component
public final class FinanceStatementOriginalSnapshotReader implements AutoCloseable {
    public record Key(UUID datasetId, long resetGeneration, UUID documentId,
                      String documentSha256, String sourceFingerprint, int schema) {
        public Key {
            Objects.requireNonNull(datasetId); Objects.requireNonNull(documentId);
            Objects.requireNonNull(documentSha256); Objects.requireNonNull(sourceFingerprint);
            if (resetGeneration < 0 || schema < 1) throw new IllegalArgumentException("Invalid original identity");
        }
    }

    private static final long MIB = 1024L * 1024L;
    // Retention/admission bounds, NEVER a document row limit. An uncacheable
    // complete original retains the old complete read path below. Existing I/O
    // and transaction deadlines are not increased by this cache.
    private static VersionedReadSnapshotCache.Limits defaults() {
        return new VersionedReadSnapshotCache.Limits(8, 64 * MIB, 128 * MIB,
                Duration.ofMinutes(3), 2, 32, Duration.ofSeconds(30), 256, 8_000_000);
    }

    private final ObjectMapper json;
    private final TxSessionVars tx;
    private final VersionedReadSnapshotCache<Key> cache;

    @Autowired public FinanceStatementOriginalSnapshotReader(ObjectMapper json, TxSessionVars tx) {
        this(json, tx, defaults());
    }
    FinanceStatementOriginalSnapshotReader(ObjectMapper json, TxSessionVars tx,
                                         VersionedReadSnapshotCache.Limits limits) {
        this.json = Objects.requireNonNull(json); this.tx = Objects.requireNonNull(tx);
        cache = new VersionedReadSnapshotCache<>(limits);
    }

    public Map<String, Object> read(Key key, Supplier<String> ciphertext) {
        // Only this invocation can see this newly parsed map. If deep freezing
        // exceeds cache tree safety bounds, use that COMPLETE local value;
        // never fail a previously readable document because it cannot be kept.
        var parsedForThisRead = new AtomicReference<Map<String, Object>>();
        try {
            return cache.read(key, cancellation -> {
                cancellation.checkCurrent();
                String plain = tx.decrypt(Objects.requireNonNull(ciphertext.get()));
                cancellation.checkCurrent();
                Map<String, Object> parsed = FinancialJsonResults.object(json, plain);
                parsedForThisRead.set(parsed);
                return new VersionedReadSnapshotCache.Loaded(parsed,
                        plain.getBytes(StandardCharsets.UTF_8).length);
            }).value();
        } catch (VersionedReadSnapshotCache.CapacityException capacity) {
            Map<String, Object> complete = parsedForThisRead.get();
            if (complete != null) return complete;
            // No hidden extra loader is started when the shared admission is
            // full. This is temporary concurrency pressure, not a row limit.
            throw new ApiException(ErrorCode.PRIMARY_UNAVAILABLE, "原件读取繁忙，请稍后重新读取完整结果");
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            throw new ApiException(ErrorCode.CONFLICT, "原件读取已中断，请重新读取完整结果");
        } catch (ApiException expected) {
            throw expected;
        } catch (Exception unreadable) {
            throw new ApiException(ErrorCode.CONFLICT, "打印资料历史版本无法读取，请核对原密钥和版本");
        }
    }

    @PreDestroy @Override public void close() { cache.close(); }
}
