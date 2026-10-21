package com.uten.imp.features.master.goods.pricing;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Component;
import java.util.UUID;

@Component
@RequiredArgsConstructor
class GoodsMarketReferenceStore {
    private final NamedParameterJdbcTemplate db;
    record Binding(String seriesId,long version,String identityDigest) {}
    Binding find(UUID goods) {
        var rows=db.query("SELECT series_id,version,identity_digest FROM goods_market_reference_bindings WHERE goods_id=:goods",
                new MapSqlParameterSource("goods",goods),(r,n)->new Binding(r.getString(1),r.getLong(2),r.getString(3)));
        return rows.isEmpty()?new Binding(null,0,null):rows.getFirst();
    }
    void compareAndSet(UUID goods,String series,String digest,long expected,UUID actor) {
        var p=new MapSqlParameterSource("goods",goods).addValue("series",series).addValue("digest",digest).addValue("expected",expected).addValue("actor",actor);
        int changed=expected==0?db.update("""
                INSERT INTO goods_market_reference_bindings(goods_id,series_id,identity_digest,version,updated_by)
                VALUES(:goods,:series,:digest,1,:actor) ON CONFLICT(goods_id) DO NOTHING
                """,p):db.update("""
                UPDATE goods_market_reference_bindings
                SET series_id=:series,identity_digest=:digest,version=version+1,updated_by=:actor,updated_at=clock_timestamp()
                WHERE goods_id=:goods AND version=:expected
                """,p);
        if(changed!=1)throw new ApiException(ErrorCode.CONFLICT,"货品市场关联已有修改，请刷新后重新选择");
    }
}
