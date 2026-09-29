package com.uten.imp.features.master.learning;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.json.JsonMapper;
import com.uten.imp.application.port.MasterIntakeLookupPort.AliasKind;
import com.uten.imp.application.port.MasterIntakeLookupPort.AliasScope;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * 客户货品对照表(client_goods_aliases)的集合式写入(ADR-134): 一次保存的撤回、写入、全局对照可信度刷新
 * 各一条语句, 不随明细行数增长。调用方负责事务与权限(本类只在已有事务里执行)。
 *
 * <p><b>全局对照的确认次数</b>不是保存次数, 而是「有多少个不同客户把同一叫法对到同一货品」:
 * 每个客户最多算一次, 同一个人反复保存同一批单据不会把它推过「至少 2 次确认」的使用门槛;
 * 明确选择次数同理(有多少个客户明确选过)。客户对照照旧按保存次数累计(同一张单据重复保存不重复计数)。
 */
@Component
@RequiredArgsConstructor
class ClientGoodsAliasLedger {

    private static final JsonMapper JSON = JsonMapper.builder().build();

    private final EntityManager em;

    /** 全局对照可信度的证据键: 叫法种类 + 规范化叫法 + 货品(不分上下文)。 */
    record EvidenceKey(AliasKind kind, String norm, UUID goodsId) {
    }

    /** 撤回结果: 撤回(删除/扣减/解除来源)的行数, 受影响的证据键, 以及解除来源的全局对照 id。 */
    record Retraction(int changed, Set<EvidenceKey> touched, Set<UUID> releasedGlobalIds) {
        static Retraction none() {
            return new Retraction(0, Set.of(), Set.of());
        }
    }

    /**
     * 同一张单据再次保存时, 某个叫法这次对到了别的货品: 撤回本单据上次学到的旧对应。
     * 客户对照只被确认过一次的删除, 多次的扣掉一次并清空来源(避免再扣); 全局对照只清空来源,
     * 由 {@link #refreshGlobalConfidence} 按剩余证据重算, 没有任何客户证据时删除。
     * 按对照键走唯一索引, 首次保存(没有旧对应)也只是一条空跑的语句。
     */
    @SuppressWarnings("unchecked")
    Retraction retractChangedMappings(String docType, UUID docId, List<SalesLearningPlanner.AliasUpsert> aliases) {
        if (aliases.isEmpty()) return Retraction.none();
        List<Map<String, Object>> keys = new ArrayList<>(aliases.size());
        for (SalesLearningPlanner.AliasUpsert alias : aliases) {
            Map<String, Object> key = new LinkedHashMap<>();
            key.put("client_id", alias.scope() == AliasScope.GLOBAL ? null : alias.clientId());
            key.put("kind", alias.kind().name());
            key.put("norm", alias.norm());
            key.put("context", alias.context());
            key.put("goods_id", alias.goodsId());
            keys.add(key);
        }
        List<Object[]> rows = em.createNativeQuery(RETRACT_SQL)
                .setParameter("keys", json(keys))
                .setParameter("docType", docType)
                .setParameter("docId", docId)
                .getResultList();
        Set<EvidenceKey> touched = new LinkedHashSet<>();
        Set<UUID> released = new LinkedHashSet<>();
        for (Object[] row : rows) {
            touched.add(new EvidenceKey(AliasKind.valueOf((String) row[2]), (String) row[3], (UUID) row[4]));
            if (row[1] == null) released.add((UUID) row[0]);
        }
        return new Retraction(rows.size(), touched, released);
    }

    private static final String RETRACT_SQL = """
            WITH k AS (
                SELECT *
                FROM jsonb_to_recordset(CAST(:keys AS jsonb))
                     AS k(client_id uuid, kind text, norm text, context text, goods_id uuid)
            ), stale AS (
                SELECT a.id, a.client_id, a.confirm_count
                FROM k
                JOIN client_goods_aliases a
                  ON a.client_id = k.client_id
                 AND a.alias_kind = k.kind AND a.alias_norm = k.norm AND a.context_norm = k.context
                WHERE k.client_id IS NOT NULL
                  AND a.goods_id <> k.goods_id
                  AND a.last_source_doc_type = :docType AND a.last_source_doc_id = :docId
                UNION
                SELECT a.id, a.client_id, a.confirm_count
                FROM k
                JOIN client_goods_aliases a
                  ON a.client_id IS NULL
                 AND a.alias_kind = k.kind AND a.alias_norm = k.norm AND a.context_norm = k.context
                WHERE k.client_id IS NULL
                  AND a.goods_id <> k.goods_id
                  AND a.last_source_doc_type = :docType AND a.last_source_doc_id = :docId
            ), deleted AS (
                DELETE FROM client_goods_aliases a
                USING stale s
                WHERE a.id = s.id AND s.client_id IS NOT NULL AND s.confirm_count = 1
                RETURNING a.id, a.client_id, a.alias_kind, a.alias_norm, a.goods_id
            ), decremented AS (
                UPDATE client_goods_aliases a
                SET confirm_count = a.confirm_count - 1,
                    last_source_doc_type = NULL,
                    last_source_doc_id = NULL,
                    updated_at = now()
                FROM stale s
                WHERE a.id = s.id AND s.client_id IS NOT NULL AND s.confirm_count > 1
                RETURNING a.id, a.client_id, a.alias_kind, a.alias_norm, a.goods_id
            ), released AS (
                UPDATE client_goods_aliases a
                SET last_source_doc_type = NULL,
                    last_source_doc_id = NULL,
                    updated_at = now()
                FROM stale s
                WHERE a.id = s.id AND s.client_id IS NULL
                RETURNING a.id, a.client_id, a.alias_kind, a.alias_norm, a.goods_id
            )
            SELECT id, client_id, alias_kind, alias_norm, goods_id FROM deleted
            UNION ALL
            SELECT id, client_id, alias_kind, alias_norm, goods_id FROM decremented
            UNION ALL
            SELECT id, client_id, alias_kind, alias_norm, goods_id FROM released
            """;

    /**
     * 用户明确选择(识别面板或明细里亲手选/改成某货品)即改正: 同一客户、同一叫法、同一上下文下
     * 指向其它货品、且从没被人明确选过(explicit_count = 0, 只是系统自动对上后保存学到的)的旧对照直接作废。
     * 人明确选过的旧对照保留(同一叫法确有两种货品时由核对界面让人选), 全局对照由证据重算处理。
     *
     * @return 受影响的证据键(用于重算全局对照可信度)
     */
    @SuppressWarnings("unchecked")
    Set<EvidenceKey> supersedeAutoLearned(List<SalesLearningPlanner.AliasUpsert> aliases) {
        List<Map<String, Object>> keys = new ArrayList<>();
        for (SalesLearningPlanner.AliasUpsert alias : aliases) {
            if (alias.scope() != AliasScope.CLIENT || !alias.explicit() || alias.clientId() == null) continue;
            Map<String, Object> key = new LinkedHashMap<>();
            key.put("client_id", alias.clientId());
            key.put("kind", alias.kind().name());
            key.put("norm", alias.norm());
            key.put("context", alias.context());
            key.put("goods_id", alias.goodsId());
            keys.add(key);
        }
        if (keys.isEmpty()) return Set.of();
        List<Object[]> rows = em.createNativeQuery(SUPERSEDE_SQL)
                .setParameter("keys", json(keys))
                .getResultList();
        Set<EvidenceKey> touched = new LinkedHashSet<>();
        for (Object[] row : rows) {
            touched.add(new EvidenceKey(AliasKind.valueOf((String) row[0]), (String) row[1], (UUID) row[2]));
        }
        return touched;
    }

    private static final String SUPERSEDE_SQL = """
            WITH k AS (
                SELECT *
                FROM jsonb_to_recordset(CAST(:keys AS jsonb))
                     AS k(client_id uuid, kind text, norm text, context text, goods_id uuid)
            )
            DELETE FROM client_goods_aliases a
            USING k
            WHERE a.client_id = k.client_id
              AND a.alias_kind = k.kind AND a.alias_norm = k.norm AND a.context_norm = k.context
              AND a.goods_id <> k.goods_id
              AND a.explicit_count = 0
            RETURNING a.alias_kind, a.alias_norm, a.goods_id
            """;

    /**
     * 一条语句写入本次保存的全部对照(按货品 id 顺序加锁): 新叫法确认 1 次; 已有叫法确认次数 +1,
     * 明确选择次数按本次是否明确选择 +1; 同一张单据重复保存只更新原文与时间, 不重复计数。
     * 全局对照的两个次数随后由 {@link #refreshGlobalConfidence} 按客户证据重算。
     *
     * @return 写入(新增或更新)的行数
     */
    int upsert(String docType, UUID docId, UUID actorUserId, List<SalesLearningPlanner.AliasUpsert> aliases) {
        if (aliases.isEmpty()) return 0;
        List<Map<String, Object>> rows = new ArrayList<>(aliases.size());
        for (SalesLearningPlanner.AliasUpsert alias : aliases) {
            Map<String, Object> row = new LinkedHashMap<>();
            row.put("client_id", alias.scope() == AliasScope.GLOBAL ? null : alias.clientId());
            row.put("kind", alias.kind().name());
            row.put("text", alias.text());
            row.put("norm", alias.norm());
            row.put("context", alias.context());
            row.put("goods_id", alias.goodsId());
            row.put("explicit", alias.explicit() ? 1 : 0);
            row.put("actor", actorUserId);
            rows.add(row);
        }
        return em.createNativeQuery(UPSERT_SQL)
                .setParameter("rows", json(rows))
                .setParameter("docType", docType)
                .setParameter("docId", docId)
                .executeUpdate();
    }

    private static final String UPSERT_SQL = """
            INSERT INTO client_goods_aliases (
                client_id, alias_kind, alias_text, alias_norm, context_norm, goods_id,
                confirm_count, explicit_count, first_confirmed_at, last_confirmed_at,
                last_confirmed_by, last_source_doc_type, last_source_doc_id)
            SELECT r.client_id, r.kind, r.text, r.norm, r.context, r.goods_id,
                   1, r.explicit, now(), now(), r.actor, :docType, :docId
            FROM jsonb_to_recordset(CAST(:rows AS jsonb))
                 AS r(client_id uuid, kind text, text text, norm text, context text, goods_id uuid,
                      explicit integer, actor uuid)
            ORDER BY r.goods_id, r.client_id NULLS FIRST, r.kind, r.norm, r.context
            ON CONFLICT ON CONSTRAINT uq_client_goods_aliases_key DO UPDATE SET
                alias_text = EXCLUDED.alias_text,
                last_confirmed_at = GREATEST(client_goods_aliases.last_confirmed_at, EXCLUDED.last_confirmed_at),
                last_confirmed_by = EXCLUDED.last_confirmed_by,
                confirm_count = client_goods_aliases.confirm_count + CASE
                    WHEN client_goods_aliases.last_source_doc_type IS NOT DISTINCT FROM EXCLUDED.last_source_doc_type
                     AND client_goods_aliases.last_source_doc_id IS NOT DISTINCT FROM EXCLUDED.last_source_doc_id
                    THEN 0 ELSE 1 END,
                explicit_count = client_goods_aliases.explicit_count + CASE
                    WHEN client_goods_aliases.last_source_doc_type IS NOT DISTINCT FROM EXCLUDED.last_source_doc_type
                     AND client_goods_aliases.last_source_doc_id IS NOT DISTINCT FROM EXCLUDED.last_source_doc_id
                    THEN 0 ELSE EXCLUDED.explicit_count END,
                last_source_doc_type = EXCLUDED.last_source_doc_type,
                last_source_doc_id = EXCLUDED.last_source_doc_id,
                updated_at = now()
            """;

    /**
     * 按客户证据重算给定证据键下全部全局对照(不分上下文)的确认次数与明确选择次数: 确认次数 =
     * 有同一叫法对到同一货品的客户对照的不同客户数(至少记 1, 表约束要求), 明确选择次数 = 其中明确选过的客户数。
     * {@code releasedGlobalIds} 里(刚被撤回来源)且已经没有任何客户证据的全局对照直接删除。一条语句。
     *
     * @return 删除 + 实际改了次数的全局对照行数
     */
    int refreshGlobalConfidence(Collection<EvidenceKey> keys, Collection<UUID> releasedGlobalIds) {
        if (keys.isEmpty()) return 0;
        List<Map<String, Object>> rows = new ArrayList<>(keys.size());
        for (EvidenceKey key : new LinkedHashSet<>(keys)) {
            Map<String, Object> row = new LinkedHashMap<>();
            row.put("kind", key.kind().name());
            row.put("norm", key.norm());
            row.put("goods_id", key.goodsId());
            rows.add(row);
        }
        String released = releasedGlobalIds.stream().map(UUID::toString).collect(Collectors.joining(","));
        Object[] counts = (Object[]) em.createNativeQuery(REFRESH_GLOBAL_SQL)
                .setParameter("keys", json(rows))
                .setParameter("released", released)
                .getSingleResult();
        return ((Number) counts[0]).intValue() + ((Number) counts[1]).intValue();
    }

    private static final String REFRESH_GLOBAL_SQL = """
            WITH k AS (
                SELECT DISTINCT k.kind, k.norm, k.goods_id
                FROM jsonb_to_recordset(CAST(:keys AS jsonb)) AS k(kind text, norm text, goods_id uuid)
            ), g AS (
                SELECT a.id, a.alias_kind, a.alias_norm, a.goods_id,
                       a.id = ANY(CAST(string_to_array(CAST(:released AS text), ',') AS uuid[])) AS released
                FROM k
                JOIN client_goods_aliases a
                  ON a.client_id IS NULL AND a.alias_kind = k.kind AND a.alias_norm = k.norm
                 AND a.goods_id = k.goods_id
            ), ev AS (
                SELECT c.alias_kind, c.alias_norm, c.goods_id,
                       count(DISTINCT c.client_id) AS clients,
                       count(DISTINCT c.client_id) FILTER (WHERE c.explicit_count > 0) AS explicit_clients
                FROM client_goods_aliases c
                JOIN (SELECT DISTINCT alias_kind, alias_norm, goods_id FROM g) gk
                  ON c.alias_kind = gk.alias_kind AND c.alias_norm = gk.alias_norm AND c.goods_id = gk.goods_id
                WHERE c.client_id IS NOT NULL
                GROUP BY c.alias_kind, c.alias_norm, c.goods_id
            ), scored AS (
                SELECT g.id, g.released,
                       COALESCE(ev.clients, 0)::integer AS clients,
                       COALESCE(ev.explicit_clients, 0)::integer AS explicit_clients
                FROM g
                LEFT JOIN ev
                  ON ev.alias_kind = g.alias_kind AND ev.alias_norm = g.alias_norm AND ev.goods_id = g.goods_id
            ), dropped AS (
                DELETE FROM client_goods_aliases a
                USING scored s
                WHERE a.id = s.id AND s.released AND s.clients = 0
                RETURNING a.id
            ), refreshed AS (
                UPDATE client_goods_aliases a
                SET confirm_count = GREATEST(1, s.clients),
                    explicit_count = s.explicit_clients,
                    updated_at = now()
                FROM scored s
                WHERE a.id = s.id
                  AND NOT (s.released AND s.clients = 0)
                  AND (a.confirm_count <> GREATEST(1, s.clients) OR a.explicit_count <> s.explicit_clients)
                RETURNING a.id
            )
            SELECT (SELECT count(*) FROM dropped), (SELECT count(*) FROM refreshed)
            """;

    private static String json(Object value) {
        try {
            return JSON.writeValueAsString(value);
        } catch (JsonProcessingException exception) {
            throw new IllegalStateException("Unable to encode alias rows", exception);
        }
    }
}
