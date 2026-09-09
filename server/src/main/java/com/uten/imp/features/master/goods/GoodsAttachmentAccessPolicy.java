package com.uten.imp.features.master.goods;

import com.uten.imp.application.port.AttachmentOwnerAccessPolicy;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import java.util.UUID;

/** Product images, drawings and specifications share the existing goods scope. */
@Component
@RequiredArgsConstructor
@Transactional(readOnly = true)
public class GoodsAttachmentAccessPolicy implements AttachmentOwnerAccessPolicy {
    public static final String OWNER_TYPE = "GOODS";
    private final EntityManager em;
    private final GoodsService goods;

    @Override public String ownerType() { return OWNER_TYPE; }

    @Override public void requireCanView(UUID ownerId, AuthUser user) {
        readable(find(ownerId), user);
    }

    @Override public void requireCanManage(UUID ownerId, AuthUser user) {
        editable(find(ownerId), user);
    }

    @Override
    @Transactional(propagation = Propagation.MANDATORY)
    public void requireCanManageForUpdate(UUID ownerId, AuthUser user) {
        editable(find(ownerId), user);
        Goods locked = em.find(Goods.class, ownerId, LockModeType.PESSIMISTIC_WRITE);
        if (locked == null) throw missing();
        em.refresh(locked, LockModeType.PESSIMISTIC_WRITE);
        editable(locked, user);
    }

    private Goods find(UUID id) {
        if (id == null) throw new ApiException(ErrorCode.VALIDATION_FAILED, "请先保存货品，再添加文件");
        Goods result = em.find(Goods.class, id);
        if (result == null || result.isDeleted()) throw missing();
        return result;
    }

    private void readable(Goods value, AuthUser user) {
        if (value.isDeleted() || !has(user, "goods:view")) throw missing();
        goods.requireVisible(value);
    }

    private void editable(Goods value, AuthUser user) {
        readable(value, user);
        if (!has(user, "goods:edit")) throw new ApiException(ErrorCode.FORBIDDEN, "缺少货品编辑权限");
        goods.requireWritable(value);
    }

    private static boolean has(AuthUser user, String authority) {
        return user != null && (user.isSuperAdmin() || user.getPermissions().contains(authority));
    }
    private static ApiException missing() { return new ApiException(ErrorCode.NOT_FOUND, "货品不存在"); }
}
