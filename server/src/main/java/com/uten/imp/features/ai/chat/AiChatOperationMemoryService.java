package com.uten.imp.features.ai.chat;

import com.uten.imp.features.ai.AiProperties;
import com.uten.imp.security.AiChatAccessPolicy;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.text.Normalizer;
import java.util.List;
import java.util.Locale;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

/**
 * ADR-163 个人操作记忆: 记住「本人怎么问 -> 服务端怎么解答」。同一问法重复出现只累加计数并刷新
 * last_used_at, 换了解法则覆盖 resolution 重计数; 每人只保留最近 50 行(写后 LRU 收整)。
 * 行内容仅问法与表单/工具名的统计, 不含业务数据, 不挂业务审计。读写一律以 {@code requireChat()}
 * 拿到的本人 id 过滤(照 AiChatEvidence 的 owner 口径); 唯独 {@link #purgeUnused(int)} 由定时清理
 * 调用, 没有本人上下文, 按保留天数全局删除。
 */
@Service
public class AiChatOperationMemoryService {
    /** 每人保留的最多行数(写后 LRU 收整, 防高频用户无限增长)。 */
    static final int PER_USER_LIMIT = 50;
    private static final Set<String> KINDS = Set.of("OPEN_FORM", "TOOL");
    private static final String COLUMNS = "question_key, resolution->>'kind' AS kind, resolution->>'target' AS target, hit_count";
    private final JdbcTemplate jdbc;
    private final AiChatAccessPolicy access;
    private final TransactionTemplate tx;
    /** recall 有效期(天), 来自 AiProperties.operationMemoryRetentionDays, 配置错乱时至少 1 天。 */
    private final int retentionDays;

    public AiChatOperationMemoryService(JdbcTemplate jdbc, AiChatAccessPolicy access, AiProperties properties,
                                        PlatformTransactionManager transactions) {
        this.jdbc = jdbc; this.access = access;
        this.tx = new TransactionTemplate(transactions);
        this.tx.setTimeout(15);
        this.retentionDays = Math.max(1, properties.getOperationMemoryRetentionDays());
    }

    /** 一条被记住的操作: 规范化后的问法、当时的解法(OPEN_FORM/TOOL + 目标)与重复次数。 */
    record Remembered(String question, String kind, String target, int hitCount) {}

    /**
     * 记住(或强化)一条解法: 同 key 同 resolution 只累加 hit_count 并刷新 last_used_at; 同 key 换了
     * resolution 则覆盖并把计数归 1(最近一次解法才算数)。记忆是尽力而为: 问法规范化后为空或目标
     * 不成样子时静默不记, 绝不影响正在回答的问题。
     */
    public void remember(String message, String kind, String target) {
        if (!KINDS.contains(kind)) throw new IllegalArgumentException("Invalid operation memory kind");
        String key = questionKey(message);
        String what = target == null ? "" : target.replaceAll("[\\p{Cc}\\p{Cf}]+", " ").strip();
        if (key.isEmpty() || what.isEmpty() || what.length() > 160) return;
        UUID user = access.requireChat().getId();
        tx.executeWithoutResult(status -> {
            jdbc.update("""
                    INSERT INTO ai_chat_operation_memory(id, user_id, question_key, resolution)
                    VALUES (?, ?, ?, jsonb_build_object('kind', ?::text, 'target', ?::text))
                    ON CONFLICT (user_id, question_key) DO UPDATE SET
                        hit_count = CASE WHEN ai_chat_operation_memory.resolution = EXCLUDED.resolution
                                         THEN ai_chat_operation_memory.hit_count + 1 ELSE 1 END,
                        resolution = EXCLUDED.resolution,
                        last_used_at = now()
                    """, UUID.randomUUID(), user, key, kind, what);
            // LRU 收整: 只留本人最近 50 行, 行数有限才能保证此表永远小而快
            jdbc.update("""
                    DELETE FROM ai_chat_operation_memory WHERE user_id = ? AND id NOT IN
                        (SELECT id FROM ai_chat_operation_memory WHERE user_id = ?
                         ORDER BY last_used_at DESC, id LIMIT ?)
                    """, user, user, PER_USER_LIMIT);
        });
    }

    /** 本人这条问法最近一次的解法; 超过保留天数没再用就当作没记住。 */
    public Optional<Remembered> recall(String message) {
        String key = questionKey(message);
        if (key.isEmpty()) return Optional.empty();
        UUID user = access.requireChat().getId();
        return jdbc.query("SELECT " + COLUMNS + " FROM ai_chat_operation_memory"
                + " WHERE user_id = ? AND question_key = ? AND last_used_at > now() - make_interval(days => ?)",
                this::row, user, key, retentionDays).stream().findFirst();
    }

    /** 命中记忆直接复用后只刷新计数与时间(不改 resolution: 解法没变)。 */
    public void touch(String message) {
        String key = questionKey(message);
        if (key.isEmpty()) return;
        jdbc.update("UPDATE ai_chat_operation_memory SET last_used_at = now(), hit_count = hit_count + 1"
                + " WHERE user_id = ? AND question_key = ?", access.requireChat().getId(), key);
    }

    /** 本人近期用过的查询工具(按最近使用排序, 提示注入用)。 */
    public List<Remembered> recentTools(int limit) {
        return jdbc.query("SELECT " + COLUMNS + " FROM ai_chat_operation_memory"
                + " WHERE user_id = ? AND resolution->>'kind' = 'TOOL'"
                + " AND last_used_at > now() - make_interval(days => ?) ORDER BY last_used_at DESC LIMIT ?",
                this::row, access.requireChat().getId(), retentionDays, clamp(limit));
    }

    /** 本人最常让我打开的表单(按重复次数、再按最近使用排序, 欢迎区建议用)。 */
    public List<Remembered> suggestions(int limit) {
        return jdbc.query("SELECT " + COLUMNS + " FROM ai_chat_operation_memory"
                + " WHERE user_id = ? AND resolution->>'kind' = 'OPEN_FORM'"
                + " AND last_used_at > now() - make_interval(days => ?)"
                + " ORDER BY hit_count DESC, last_used_at DESC LIMIT ?",
                this::row, access.requireChat().getId(), retentionDays, clamp(limit));
    }

    /** 本人清除自己的全部操作记忆(设置面板「清除记录」)。 */
    public int clear() {
        return jdbc.update("DELETE FROM ai_chat_operation_memory WHERE user_id = ?", access.requireChat().getId());
    }

    /** 定时清理(无本人上下文): 全局删除超过 days 天没再使用的记忆行。 */
    public int purgeUnused(int days) {
        return jdbc.update("DELETE FROM ai_chat_operation_memory WHERE last_used_at < now() - make_interval(days => ?)",
                Math.max(1, days));
    }

    private Remembered row(ResultSet rs, int index) throws SQLException {
        return new Remembered(rs.getString("question_key"), rs.getString("kind"), rs.getString("target"),
                rs.getInt("hit_count"));
    }

    private static int clamp(int limit) { return Math.max(1, Math.min(limit, PER_USER_LIMIT)); }

    /**
     * question_key 口径: NFKC+小写+去空白标点, 与 AiChatDialogueSupport.normalized 相同(该类归并行
     * 改动文件, 不跨文件引用, 口径一致即可), 再额外洗掉控制/格式字符并截 160(ADR-163 §2.1: key 在
     * Java 侧生成, DB 不猜)。写入与 recall 用的是同一个方法, 双向口径必然一致。
     */
    private static String questionKey(String message) {
        if (message == null || message.length() > 2000) return "";
        // \p{Z} covers U+2028/U+2029 line separators, which plain \s misses and which could forge line breaks
        // when the key is later quoted inside the untrusted prompt part.
        String key = Normalizer.normalize(message, Normalizer.Form.NFKC).toLowerCase(Locale.ROOT)
                .replaceAll("[\\s\\p{Z}\\p{P}\\p{Cc}\\p{Cf}]+", "");
        return key.length() <= 160 ? key
                : key.substring(0, Character.isHighSurrogate(key.charAt(159)) ? 159 : 160);
    }
}
