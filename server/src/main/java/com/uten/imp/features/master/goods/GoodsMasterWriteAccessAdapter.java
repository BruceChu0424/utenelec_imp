package com.uten.imp.features.master.goods;

import com.uten.imp.application.port.GoodsMasterWriteAccessPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.UUID;

@Component
@RequiredArgsConstructor
class GoodsMasterWriteAccessAdapter implements GoodsMasterWriteAccessPort {
    private final EntityManager em;
    private final GoodsService goods;
    @Override public void requireWritable(UUID id) {
        Goods master=em.find(Goods.class,id);
        if(master==null || master.isDeleted()) throw new ApiException(ErrorCode.NOT_FOUND,"货品不存在");
        em.refresh(master);
        goods.requireVisible(master);
        goods.requireWritable(master);
    }
}
