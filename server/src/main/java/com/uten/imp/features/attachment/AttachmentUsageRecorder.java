package com.uten.imp.features.attachment;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

/**
 * 附件「最近使用时间」的唯一写入口：下载授权、本地原件下载与在线预览通过权限校验并写好审计后，
 * 把 {@code attachments.last_used_at} 推进到数据库当前时间，供冷热分层判定访问热度
 * （业务时间点落在附件自己的列上，不读审计日志）。
 *
 * <ul>
 *   <li>独立短事务（REQUIRES_NEW，与审计显式事件同一口径）：下载/预览本身是只读事务，热度写入
 *       不进入、也不拖住下载事务；调用方吞掉失败，下载从不因热度写入失败或重放。</li>
 *   <li>按天节流：一天内已推进过的不再写行；分层窗口按 90 天计，一天的粒度不影响判定。</li>
 *   <li>不等锁：行正被别的事务改（分类、删除等）时 {@code SKIP LOCKED} 直接跳过，下次使用再推进。</li>
 *   <li>只推进可用（CLEAN 且未申请删除）的附件：已删除历史整行不可变，下载入口也只放行 CLEAN。</li>
 * </ul>
 * {@code last_used_at} 在 fn_audit 运维列清单里，只推进本列的更新不产生整行审计事件。
 */
@Component
public class AttachmentUsageRecorder {

    /** 节流间隔与 SQL 里的 interval 保持一致：一天内重复使用不再写附件行。 */
    static final String TOUCH_SQL = """
            UPDATE attachments SET last_used_at = now()
             WHERE id = (SELECT a.id FROM attachments a
                          WHERE a.id = ?
                            AND a.lifecycle_state = 'CLEAN'
                            AND a.delete_requested_at IS NULL
                            AND (a.last_used_at IS NULL OR a.last_used_at < now() - interval '1 day')
                          FOR UPDATE SKIP LOCKED)
            """;

    private final JdbcTemplate jdbc;

    public AttachmentUsageRecorder(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /** @return 是否真的推进了（节流、行被锁或附件不可用时为 false）。 */
    @Transactional(propagation = Propagation.REQUIRES_NEW, timeout = 5)
    public boolean recordUse(UUID attachmentId) {
        return jdbc.update(TOUCH_SQL, attachmentId) > 0;
    }
}
