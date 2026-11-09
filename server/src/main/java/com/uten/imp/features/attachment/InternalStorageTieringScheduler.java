package com.uten.imp.features.attachment;

import com.uten.imp.common.storage.InternalStorageService;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.context.annotation.Profile;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.time.Instant;

/**
 * Nightly cold-tiering task for the internal storage provider.
 *
 * Attachments older than the configured age leave the NVMe hot root for the
 * large RAID volume; downloads keep working through the archive fallback.
 * Company-library attachments are excluded — they are read often and stay on
 * the hot root permanently. Deletes never happen here; a move interrupted at
 * any point is safe to re-run on the next pass.
 */
@Component
@Profile("!cloud")
@ConditionalOnProperty(prefix="uten.storage",name="provider",havingValue="internal")
class InternalStorageTieringScheduler {
    private static final Logger log = LoggerFactory.getLogger(InternalStorageTieringScheduler.class);
    /** Upper bound per pass so one night can never monopolize disk I/O. */
    private static final int MAX_OBJECTS_PER_PASS = 5000;
    private static final long THROTTLE_MILLIS = 50;

    private final InternalStorageService storage;
    private final JdbcTemplate jdbc;

    InternalStorageTieringScheduler(InternalStorageService storage, JdbcTemplate jdbc) {
        this.storage = storage;
        this.jdbc = jdbc;
    }

    /**
     * 03:35 daily, between the 02:17 full backups and the 03:40 paired backup;
     * on the paired run the moved files are picked up from the archive root.
     */
    @Scheduled(cron = "${uten.storage.internal.tiering-cron:0 35 3 * * *}", zone = "Asia/Shanghai")
    void tierAgedAttachments() {
        if (!storage.archiveTieringConfigured()) return;
        int archiveAfterDays = storage.archiveAfterDays();
        if (archiveAfterDays <= 0) return;
        Instant cutoff = Instant.now().minus(Duration.ofDays(archiveAfterDays));
        // Company-library nodes reference their attachments explicitly and keep
        // them on the hot root regardless of age.
        var keys = jdbc.queryForList(
                "SELECT a.storage_key FROM attachments a" +
                " WHERE a.created_at < ? AND NOT EXISTS" +
                " (SELECT 1 FROM company_file_nodes c WHERE c.attachment_id = a.id)" +
                " ORDER BY a.created_at LIMIT " + MAX_OBJECTS_PER_PASS,
                String.class, java.sql.Timestamp.from(cutoff));
        int moved = 0;
        for (String key : keys) {
            try {
                storage.tierToArchive(key);
                moved++;
                Thread.sleep(THROTTLE_MILLIS);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                break;
            } catch (Exception error) {
                // One unreadable object must not stop the rest of the pass.
                log.warn("Internal storage tiering skipped attachment {}: {}", key, error.getMessage());
            }
        }
        if (!keys.isEmpty() || moved > 0)
            log.info("Internal storage tiering moved {}/{} aged attachments to the archive root", moved, keys.size());
    }
}
