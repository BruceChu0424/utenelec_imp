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
    /** Download/preview activity inside this window pins an attachment to the hot root. */
    private static final long RECENT_ACCESS_DAYS = 90;

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
        Instant activeCutoff = Instant.now().minus(Duration.ofDays(RECENT_ACCESS_DAYS));
        // Heat beats age: anything downloaded or preview-authorized inside the
        // recent window stays on the NVMe hot root no matter how old it is.
        var activeIds = java.util.Set.copyOf(jdbc.queryForList(
                "SELECT DISTINCT l.target_id FROM audit_log l" +
                " WHERE l.target_type = 'attachments'" +
                " AND l.action IN ('attachment_download_raw','attachment_download_grant','attachment.presign')" +
                " AND l.created_at >= ?",
                String.class, java.sql.Timestamp.from(activeCutoff)));
        // Company-library nodes reference their attachments explicitly and keep
        // them on the hot root regardless of age.
        var candidates = jdbc.queryForList(
                "SELECT a.id, a.storage_key FROM attachments a" +
                " WHERE a.created_at < ? AND NOT EXISTS" +
                " (SELECT 1 FROM company_file_nodes c WHERE c.attachment_id = a.id)" +
                " ORDER BY a.created_at LIMIT " + MAX_OBJECTS_PER_PASS,
                java.sql.Timestamp.from(cutoff));
        var keys = selectColdKeys(candidates, activeIds);
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
        // Heat works in both directions: an archived object that people started
        // using again returns to the NVMe hot root.
        int revived = 0;
        for (var row : candidates) {
            Object id = row.get("id");
            Object key = row.get("storage_key");
            if (id == null || key == null || !activeIds.contains(id.toString())) continue;
            try {
                if (storage.archived(key.toString())) {
                    storage.reviveFromArchive(key.toString());
                    revived++;
                    Thread.sleep(THROTTLE_MILLIS);
                }
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                break;
            } catch (Exception error) {
                log.warn("Internal storage revival skipped attachment {}: {}", key, error.getMessage());
            }
        }
        if (!keys.isEmpty() || moved > 0 || revived > 0)
            log.info("Internal storage tiering moved {}/{} aged attachments to the archive root and revived {}",
                    moved, keys.size(), revived);
    }

    /**
     * Pure selection seam: aged candidates minus recently accessed ones. Package
     * visibility keeps the SQL row shape and the heat rule independently tested.
     */
    static java.util.List<String> selectColdKeys(java.util.List<java.util.Map<String, Object>> candidates,
                                                 java.util.Set<String> recentlyActiveAttachmentIds) {
        var keys = new java.util.ArrayList<String>();
        for (var row : candidates) {
            Object id = row.get("id");
            if (id != null && recentlyActiveAttachmentIds.contains(id.toString())) continue;
            Object key = row.get("storage_key");
            if (key != null) keys.add(key.toString());
        }
        return keys;
    }
}
