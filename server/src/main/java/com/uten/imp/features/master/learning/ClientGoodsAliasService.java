package com.uten.imp.features.master.learning;

import com.uten.imp.application.port.MasterIntakeLookupPort.AliasKind;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.util.NativeValueConverters;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.master.client.ClientAccessPolicy;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.CurrentAuthorityGuard;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.UUID;

/**
 * 客户资料「货品对照」(ADR-134): 查看与删除某个客户学到的客户型号/品名 → 货品对应。
 *
 * <p>只列该客户专属的对照(全局对照不在这里显示)。查看要求对客户有读范围, 删除要求 client:edit
 * 且对客户有写范围; 删除时校验对照确实属于路径上的客户(防越权改别人的对照), 并写一条审计事件
 * (对照表不挂行级审计, 这条事件是删除的唯一留痕)。删掉的客户对照不再算全局对照的证据,
 * 同一叫法的全局对照随即按剩余证据重算可信度。
 */
@Service
@RequiredArgsConstructor
public class ClientGoodsAliasService {

    static final String AUDIT_ACTION_DELETE = "client_goods_alias.delete";

    private final EntityManager em;
    private final ClientAccessPolicy clientAccess;
    private final SecurityContextCurrentUser currentUser;
    private final AuditService audit;
    private final ClientGoodsAliasLedger aliasLedger;
    private final TxSessionVars tx;

    @Transactional(readOnly = true)
    @SuppressWarnings("unchecked")
    public PageResponse<ClientGoodsAliasView> list(UUID clientId, String keyword, int page, int size) {
        ClientAccessPolicy.ClientScope scope = clientAccess.evaluate();
        UUID owner = requireReadableClient(clientId, scope);
        boolean canDelete = hasClientEdit() && clientAccess.canWriteOwner(owner, scope);
        int safePage = Math.max(1, page);
        int safeSize = Math.min(Math.max(1, size), 100);
        String pattern = keywordPattern(keyword);
        String filter = pattern == null ? "" : """
                 AND (lower(a.alias_text) LIKE :kw ESCAPE '\\'
                      OR lower(coalesce(g.code, '')) LIKE :kw ESCAPE '\\'
                      OR lower(coalesce(g.name, '')) LIKE :kw ESCAPE '\\'
                      OR lower(coalesce(g.model, '')) LIKE :kw ESCAPE '\\')
                """;
        String from = """
                FROM client_goods_aliases a
                JOIN goods g ON g.id = a.goods_id AND NOT g.is_deleted
                WHERE a.client_id = :clientId
                """ + filter;
        Query count = em.createNativeQuery("SELECT count(*) " + from);
        count.setParameter("clientId", clientId);
        if (pattern != null) count.setParameter("kw", pattern);
        long total = ((Number) count.getSingleResult()).longValue();
        List<ClientGoodsAliasView> items = new ArrayList<>();
        if (total > 0) {
            Query rows = em.createNativeQuery("""
                    SELECT a.id, a.alias_kind, a.alias_text, a.context_norm, a.confirm_count, a.explicit_count,
                           a.last_confirmed_at, g.id, g.code, g.name, col.name,
                           e.full_name, e.code
                    FROM client_goods_aliases a
                    JOIN goods g ON g.id = a.goods_id AND NOT g.is_deleted
                    LEFT JOIN colors col ON col.id = g.color_id
                    LEFT JOIN users usr ON usr.id = a.last_confirmed_by
                    LEFT JOIN employees e ON e.id = usr.employee_id
                    WHERE a.client_id = :clientId
                    """ + filter + """
                     ORDER BY a.last_confirmed_at DESC, a.id
                     LIMIT :size OFFSET :offset
                    """);
            rows.setParameter("clientId", clientId);
            if (pattern != null) rows.setParameter("kw", pattern);
            rows.setParameter("size", safeSize);
            rows.setParameter("offset", (safePage - 1) * safeSize);
            for (Object[] row : (List<Object[]>) rows.getResultList()) {
                items.add(new ClientGoodsAliasView(
                        (UUID) row[0], "CLIENT", (String) row[1], (String) row[2], contextText((String) row[3]),
                        new ClientGoodsAliasView.GoodsRef((UUID) row[7], (String) row[8], (String) row[9],
                                (String) row[10]),
                        ((Number) row[4]).intValue(), ((Number) row[5]).intValue(),
                        NativeValueConverters.toOffsetDateTime(row[6]),
                        personName((String) row[11], (String) row[12]), canDelete));
            }
        }
        int totalPages = (int) ((total + safeSize - 1) / safeSize);
        return new PageResponse<>(items, safePage, safeSize, total, totalPages);
    }

    @Transactional
    @SuppressWarnings("unchecked")
    public void delete(UUID clientId, UUID aliasId) {
        CurrentAuthorityGuard.requireAll("client:edit");
        tx.bind();
        ClientAccessPolicy.ClientScope scope = clientAccess.evaluate();
        UUID owner = requireReadableClient(clientId, scope);
        if (!clientAccess.canWriteOwner(owner, scope)) {
            throw new ApiException(ErrorCode.FORBIDDEN, "这个客户由其他业务员负责, 你只能查看, 不能删除对照");
        }
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT a.client_id, a.alias_kind, a.alias_text, g.code, a.alias_norm, a.goods_id
                        FROM client_goods_aliases a
                        JOIN goods g ON g.id = a.goods_id
                        WHERE a.id = :aliasId
                        FOR UPDATE OF a
                        """)
                .setParameter("aliasId", aliasId)
                .getResultList();
        // 对照必须属于路径上的客户; 全局对照(client_id 为空)与别的客户的对照一律按不存在处理。
        if (rows.size() != 1 || !clientId.equals(rows.getFirst()[0])) {
            throw new ApiException(ErrorCode.NOT_FOUND, "这条货品对照不存在或已删除");
        }
        Object[] row = rows.getFirst();
        em.createNativeQuery("DELETE FROM client_goods_aliases WHERE id = :aliasId")
                .setParameter("aliasId", aliasId)
                .executeUpdate();
        aliasLedger.refreshGlobalConfidence(List.of(new ClientGoodsAliasLedger.EvidenceKey(
                AliasKind.valueOf((String) row[1]), (String) row[4], (UUID) row[5])), List.of());
        AuthUser user = currentUser.get().orElse(null);
        String kind = "PART_NO".equals(row[1]) ? "客户型号" : "客户品名";
        audit.logCommitted(user == null ? null : user.getId(), user == null ? null : user.getLoginAccount(),
                AUDIT_ACTION_DELETE, "client_goods_aliases", aliasId.toString(),
                "删除客户货品对照: " + kind + " " + shorten((String) row[2]) + " -> 货品 " + row[3]);
    }

    /** 客户须存在、未删除且调用人看得到, 否则 404(不暴露存在性); 返回负责人。 */
    @SuppressWarnings("unchecked")
    private UUID requireReadableClient(UUID clientId, ClientAccessPolicy.ClientScope scope) {
        List<Object[]> rows = em.createNativeQuery("""
                        SELECT c.owner_employee_id, c.is_deleted
                        FROM clients c
                        WHERE c.id = :id
                        """)
                .setParameter("id", clientId)
                .getResultList();
        if (rows.size() != 1 || Boolean.TRUE.equals(rows.getFirst()[1])) {
            throw new ApiException(ErrorCode.NOT_FOUND, "客户不存在");
        }
        UUID owner = (UUID) rows.getFirst()[0];
        if (!clientAccess.canRead(clientId, owner, scope)) {
            throw new ApiException(ErrorCode.NOT_FOUND, "客户不存在");
        }
        return owner;
    }

    private boolean hasClientEdit() {
        AuthUser user = currentUser.get().orElse(null);
        if (user == null || user.isVisitor()) return false;
        return user.isSuperAdmin() || (user.getPermissions() != null && user.getPermissions().contains("client:edit"));
    }

    /** 「Z9|白」→「Z9 · 白」; 空段略过, 全空返回 null。 */
    static String contextText(String contextNorm) {
        if (contextNorm == null || contextNorm.isBlank()) return null;
        List<String> parts = new ArrayList<>();
        for (String part : contextNorm.split("\\|")) {
            if (!part.isBlank()) parts.add(part.strip());
        }
        return parts.isEmpty() ? null : String.join(" · ", parts);
    }

    private static String personName(String name, String code) {
        if (name == null || name.isBlank()) return null;
        return code == null || code.isBlank() ? name : name + "(" + code + ")";
    }

    private static String keywordPattern(String keyword) {
        if (keyword == null || keyword.isBlank()) return null;
        String trimmed = keyword.strip().toLowerCase(Locale.ROOT);
        if (trimmed.length() > 100) trimmed = trimmed.substring(0, 100);
        String escaped = trimmed.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_");
        return "%" + escaped + "%";
    }

    private static String shorten(String text) {
        if (text == null) return "";
        return text.length() > 80 ? text.substring(0, 80) + "..." : text;
    }
}
