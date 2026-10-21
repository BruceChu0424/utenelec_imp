package com.uten.imp.features.master.goods;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.CurrentAuthorityGuard;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.UUID;

/** Uses the master editor's authoritative visibility and write scope for market associations. */
@Component
@RequiredArgsConstructor
public class GoodsMarketBindingWriteAccess {
    private final GoodsService goods;
    private final GoodsRepository repository;
    private final EntityManager em;
    private final SecurityContextCurrentUser current;

    public boolean canManage(UUID id) {
        var actor=current.get();
        if(actor.isEmpty()||!validActor(actor.get())||!(actor.get().isSuperAdmin()||actor.get().getPermissions().contains("goods:edit")))return false;
        var row=repository.findById(id);
        return row.isPresent()&&!row.get().isDeleted()&&!row.get().isAutoCreated()&&goods.canWrite(row.get());
    }

    public void requireWritableAndLock(UUID id) {
        CurrentAuthorityGuard.requireAll("goods:view","goods:edit");
        if(!current.get().map(GoodsMarketBindingWriteAccess::validActor).orElse(false))
            throw new ApiException(ErrorCode.FORBIDDEN,"当前账号不能修改货品关联，请核对登录状态");
        Goods row=repository.findById(id).filter(g->!g.isDeleted()&&!g.isAutoCreated())
                .orElseThrow(()->new ApiException(ErrorCode.NOT_FOUND,"货品不存在"));
        goods.requireVisible(row);
        goods.requireWritable(row);
        em.refresh(row,LockModeType.PESSIMISTIC_WRITE);
        if(row.isDeleted()||row.isAutoCreated())throw new ApiException(ErrorCode.NOT_FOUND,"货品不存在");
        goods.requireVisible(row);
        goods.requireWritable(row);
    }

    private static boolean validActor(AuthUser user) {
        return user.getEmployeeId()!=null&&!user.isVisitor()&&user.isAccountNonLocked()
                &&!user.isMustChangePassword()&&user.getImpersonatedBy()==null;
    }
}
