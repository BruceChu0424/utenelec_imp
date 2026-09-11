package com.uten.imp.features.stock;

import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.ProductionStockTaskAccessPolicy;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.UUID;

/**
 * 仓库实物单据（DRAW/调拨/盘点等）附件（2026-09-09：领料出库凭证；2026-09-10 修订）。
 *
 * <p>可看 = 与 {@link StockDocService#detail} 同口径：持 stock_doc:view 且单据未删，
 * 生产链单据按仓储组织对象范围（{@link ProductionStockTaskAccessPolicy}）可跨制单人
 * 查看，手工单按制单人 maker/data-scope（{@link StockDocAccessPolicy}）隔离，
 * 不可达一律 404 不泄露存在性。</p>
 *
 * <p>可管 = 可看 ∩ 持 approve 或 issue（出库/审核即单据操作者）∩ 单据状态为草稿或已审
 * （已红冲 -1 的单据凭证冻结，409）∩ 对象范围可写（生产链单据要求仓库任务办理范围，
 * 手工单要求制单人可写范围）。更新变体在 FOR UPDATE 之后重读状态，防止并发红冲
 * 后仍替换凭证。</p>
 */
@Component
@RequiredArgsConstructor
@Transactional(readOnly = true)
public class StockDocumentAttachmentAccessPolicy implements AttachmentOwnerAccessPolicy {
    public static final String OWNER_TYPE = "STOCK_DOCUMENT";

    private static final short STATUS_DRAFT = 0;
    private static final short STATUS_APPROVED = 1;

    private static final List<String> OPERATOR_AUTHORITIES = List.of(
            "stock_doc:view", "stock_doc:approve", "stock_doc:reverse",
            "stock_doc:issue", "stock_doc:reverse_issue");

    private final EntityManager em;
    private final StockDocAccessPolicy access;
    private final ProductionStockTaskAccessPolicy productionStockTaskAccess;

    @Override public String ownerType() { return OWNER_TYPE; }

    @Override public void requireCanView(UUID ownerId, AuthUser user) {
        readable(ownerId, user, false);
    }

    @Override public void requireCanManage(UUID ownerId, AuthUser user) {
        manageable(ownerId, user, false);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void requireCanManageForUpdate(UUID ownerId, AuthUser user) {
        manageable(ownerId, user, true);
    }

    private Document readable(UUID id, AuthUser user, boolean forUpdate) {
        if (id == null) throw missing();
        if (!has(user, "stock_doc:view")) throw missing();
        Document document = load(id, forUpdate);
        boolean productionTaskReadable = document.productionLinked()
                && productionStockTaskAccess.canAccessWarehouseTasks()
                && OPERATOR_AUTHORITIES.stream().anyMatch(authority -> has(user, authority));
        if (!productionTaskReadable) {
            access.requireReadable(document.makerId(), "仓库单据不存在");
        }
        return document;
    }

    private void manageable(UUID id, AuthUser user, boolean forUpdate) {
        Document document = readable(id, user, forUpdate);
        if (!has(user, "stock_doc:approve") && !has(user, "stock_doc:issue")) {
            throw new ApiException(ErrorCode.FORBIDDEN, "缺少单据办理权限，不能管理附件");
        }
        if (document.status() == null
                || (document.status() != STATUS_DRAFT && document.status() != STATUS_APPROVED)) {
            throw new ApiException(ErrorCode.CONFLICT, "已红冲的仓库单据不能再上传或删除附件");
        }
        if (document.productionLinked()) {
            productionStockTaskAccess.requireWarehouseTaskAccess("缺少仓库任务办理范围，不能管理附件");
        } else {
            access.requireWritable(document.makerId(), "无权管理此仓库单据的附件");
        }
    }

    private Document load(UUID id, boolean forUpdate) {
        List<Object[]> rows = NativeQueryResults.objectArrayRows(
                em.createNativeQuery("""
                                SELECT status, maker_id,
                                       fn_is_production_linked_stock_document(id)
                                FROM stock_documents
                                WHERE id = :id AND is_deleted = FALSE
                                """ + (forUpdate ? " FOR UPDATE" : ""))
                        .setParameter("id", id));
        if (rows.size() != 1) throw missing();
        Object[] row = rows.getFirst();
        Short status = row[0] == null ? null : ((Number) row[0]).shortValue();
        return new Document(status, (UUID) row[1], Boolean.TRUE.equals(row[2]));
    }

    private static boolean has(AuthUser user, String authority) {
        return user != null
                && (user.isSuperAdmin() || user.getPermissions().contains(authority));
    }

    private static ApiException missing() {
        return new ApiException(ErrorCode.NOT_FOUND, "仓库单据不存在");
    }

    private record Document(Short status, UUID makerId, boolean productionLinked) {}
}
