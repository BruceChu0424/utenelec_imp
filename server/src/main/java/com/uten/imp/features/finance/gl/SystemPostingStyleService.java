package com.uten.imp.features.finance.gl;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.validation.constraints.NotNull;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** Missing roles can be completed; existing operational assignments are never silently replaced. */
@Service
@RequiredArgsConstructor
public class SystemPostingStyleService {
    private final JdbcTemplate db;
    private final TxSessionVars tx;
    private final SecurityContextCurrentUser currentUser;

    public record Role(String roleKey, String description, String requiredCategory,
            UUID styleId, String styleName, boolean usable, OffsetDateTime updatedAt, boolean canConfigure) {
        public Role(String roleKey,String description,String requiredCategory,UUID styleId,String styleName,
                    boolean usable,OffsetDateTime updatedAt){this(roleKey,description,requiredCategory,styleId,styleName,usable,updatedAt,false);}
    }
    public record Configure(@NotNull UUID styleId, @NotNull OffsetDateTime expectedUpdatedAt) {}

    @Transactional(readOnly = true)
    public List<Role> list() { return read(null, false); }

    @Transactional
    public Role configure(String roleKey, Configure request) {
        if (roleKey == null || !roleKey.matches("[A-Z][A-Z0-9_]*")
                || request == null || request.styleId() == null || request.expectedUpdatedAt() == null)
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择科目并重新核对用途版本");
        tx.bind();
        // V278's role trigger shares the hierarchy lock with account maintenance.
        // Acquire it before either row lock to keep that order in both directions.
        db.queryForObject("SELECT pg_advisory_xact_lock(hashtextextended('PAYMENT_STYLE_HIERARCHY',0))", Object.class);
        List<Role> rows = read(roleKey, true);
        if (rows.size() != 1) throw new ApiException(ErrorCode.NOT_FOUND, "系统科目用途不存在");
        Role before = rows.getFirst();
        requireCurrent(before, request);
        @SuppressWarnings("unchecked") List<Object[]> choices = db.query(
                "SELECT category,status,is_deleted FROM payment_styles WHERE id=? FOR SHARE",
                (rs, n) -> new Object[]{rs.getString(1), rs.getString(2), rs.getBoolean(3)}, request.styleId());
        if (choices.size() != 1 || !before.requiredCategory().equals(choices.getFirst()[0])
                || !"使用".equals(choices.getFirst()[1]) || Boolean.TRUE.equals(choices.getFirst()[2]))
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请选择该用途所需类别中使用中的科目");
        // An imported invalid assignment may still identify historical vouchers. Restore that
        // account first instead of silently redirecting its retained accounting history.
        if (before.styleId() != null && !before.styleId().equals(request.styleId()))
            throw new ApiException(ErrorCode.CONFLICT, "该用途已有科目，请先核对并恢复原科目，不能直接替换历史用途");
        Long assigned = db.queryForObject("SELECT count(*) FROM system_posting_style_roles WHERE style_id=? AND role_key<>?",
                Long.class, request.styleId(), roleKey);
        if (assigned != null && assigned > 0)
            throw new ApiException(ErrorCode.CONFLICT, "该科目已用于另一系统用途，请选择独立科目");
        if (!before.usable()) {
            int changed = db.update("UPDATE system_posting_style_roles SET style_id=?,updated_by=?,updated_at=CURRENT_TIMESTAMP WHERE role_key=? AND updated_at=?",
                    request.styleId(), currentUser.requireId(), roleKey, before.updatedAt());
            if (changed != 1) throw new ApiException(ErrorCode.CONFLICT, "科目用途已变化，请刷新核对后保存");
        }
        return read(roleKey, false).getFirst();
    }

    static void requireCurrent(Role before, Configure request) {
        if (!before.updatedAt().toInstant().equals(request.expectedUpdatedAt().toInstant()))
            throw new ApiException(ErrorCode.CONFLICT, "科目用途已变化，请刷新核对后保存");
        if (before.usable() && !before.styleId().equals(request.styleId()))
            throw new ApiException(ErrorCode.CONFLICT, "该用途已配置，不能直接替换已用于过账的科目");
    }

    private List<Role> read(String roleKey, boolean lock) {
        boolean permitted=currentUser.get().map(user -> !user.isVisitor() && !user.isMustChangePassword()
                && user.isAccountNonLocked() && user.getImpersonatedBy()==null && (user.isSuperAdmin()
                || user.getPermissions().containsAll(java.util.Set.of("payment_style:edit","finance_post:execute")))).orElse(false);
        String sql = "SELECT role.role_key,role.description,role.required_category,role.style_id,style.name,"
                + "system_posting_style_id(role.role_key) IS NOT NULL AS usable,role.updated_at "
                + "FROM system_posting_style_roles role LEFT JOIN payment_styles style ON style.id=role.style_id "
                + (roleKey == null ? "" : "WHERE role.role_key=? ") + "ORDER BY role.role_key"
                + (lock ? " FOR UPDATE OF role" : "");
        return db.query(sql, (rs, n) -> new Role(rs.getString(1), rs.getString(2), rs.getString(3),
                rs.getObject(4, UUID.class), rs.getString(5), rs.getBoolean(6), rs.getObject(7, OffsetDateTime.class),permitted&&!rs.getBoolean(6)),
                roleKey == null ? new Object[0] : new Object[]{roleKey});
    }
}
