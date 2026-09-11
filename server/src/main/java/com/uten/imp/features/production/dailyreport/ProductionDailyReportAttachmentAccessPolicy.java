package com.uten.imp.features.production.dailyreport;

import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.security.AuthUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

/**
 * 生产日报附件（报工照片、检验记录、班组签认单）的对象级授权。
 *
 * <p>可读 = 与日报详情同口径（production_daily_report:view + 制单人归属范围，审核/红冲权可旁路归属）；
 * 可管理 = 草稿且未关闭/取消，并持 production_daily_report:edit 与可写归属；审核后原件只读。
 * 确认/删除前锁真实日报行并复核状态，避免审核与文件替换交错。</p>
 */
@Component
@RequiredArgsConstructor
@Transactional(readOnly = true)
public class ProductionDailyReportAttachmentAccessPolicy implements AttachmentOwnerAccessPolicy {
    public static final String OWNER_TYPE = "PRODUCTION_DAILY_REPORT";
    private static final short STATUS_DRAFT = 0;
    private final EntityManager em;
    private final ProductionDocumentAccessPolicy access;

    @Override public String ownerType() { return OWNER_TYPE; }

    @Override public void requireCanView(UUID ownerId, AuthUser user) {
        readable(report(ownerId), user);
    }

    @Override public void requireCanManage(UUID ownerId, AuthUser user) {
        editable(report(ownerId), user);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void requireCanManageForUpdate(UUID ownerId, AuthUser user) {
        editable(report(ownerId), user);
        ProductionDailyReport locked = em.find(ProductionDailyReport.class, ownerId, LockModeType.PESSIMISTIC_WRITE);
        if (locked == null) throw missing();
        em.refresh(locked, LockModeType.PESSIMISTIC_WRITE);
        editable(locked, user);
    }

    private ProductionDailyReport report(UUID id) {
        if (id == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "附件必须绑定生产日报");
        ProductionDailyReport report = em.find(ProductionDailyReport.class, id);
        if (report == null || report.isDeleted()) throw missing();
        return report;
    }

    private void readable(ProductionDailyReport report, AuthUser user) {
        if (report.isDeleted() || !has(user, "production_daily_report:view")) throw missing();
        access.requireReadable(report.getMakerId(), "生产日报单不存在",
                "production_daily_report:approve", "production_daily_report:reverse");
    }

    private void editable(ProductionDailyReport report, AuthUser user) {
        readable(report, user);
        if (!has(user, "production_daily_report:edit")) {
            throw new ApiException(ErrorCode.FORBIDDEN, "缺少生产日报编辑权限");
        }
        access.requireWritable(report.getMakerId(), "无权修改该生产日报附件");
        boolean draft = report.getStatus() != null && report.getStatus() == STATUS_DRAFT;
        if (!draft || report.isClosed() || report.isCanceled()) {
            throw new ApiException(ErrorCode.CONFLICT, "仅未关闭的草稿生产日报可修改附件，审核后原件只读");
        }
    }

    private static boolean has(AuthUser user, String authority) {
        return user != null && (user.isSuperAdmin() || user.getPermissions().contains(authority));
    }
    private static ApiException missing() { return new ApiException(ErrorCode.NOT_FOUND, "生产日报单不存在"); }
}
