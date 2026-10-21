package com.uten.imp.features.master.goods.pricing;

import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.goods.GoodsMarketBindingWriteAccess;
import com.uten.imp.security.CurrentAuthorityGuard;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.util.*;
import static com.uten.imp.features.master.goods.pricing.MaterialForecastContracts.*;

@Service
@RequiredArgsConstructor
@PreAuthorize("hasAuthority('goods:view') and hasAuthority('goods:price_analysis:view') and (hasAuthority('purchase_order:view') or hasAuthority('finance_order_approval:view')) and (hasAuthority('purchase_order:price:view') or hasAuthority('finance:view:all'))")
public class GoodsMarketReferenceService {
    private final GoodsPriceAccess access;
    private final MasterReferenceValidationPort references;
    private final GoodsPriceSourceReader goods;
    private final GoodsMarketBindingWriteAccess writeAccess;
    private final GoodsMarketReferenceStore bindings;
    private final MaterialForecastSnapshotReader snapshots;
    private final MaterialBenchmarkCatalog benchmarks;
    private final MaterialMarketFeedReader feed;
    private final SecurityContextCurrentUser current;
    private final TxSessionVars tx;
    private final AuditService audit;

    @Transactional(readOnly=true)
    public Envelope get(UUID goodsId) {
        requireRead(goodsId);
        return envelope(goodsId,bindings.find(goodsId));
    }
    @Transactional(readOnly=true)
    public List<Benchmark> catalog(UUID goodsId) {
        requireRead(goodsId);
        return benchmarks.all();
    }
    @Transactional
    @PreAuthorize("hasAuthority('goods:edit') and hasAuthority('goods:view') and hasAuthority('goods:price_analysis:view') and (hasAuthority('purchase_order:view') or hasAuthority('finance_order_approval:view')) and (hasAuthority('purchase_order:price:view') or hasAuthority('finance:view:all'))")
    public Envelope put(UUID goodsId,BindingRequest request) {
        requireRead(goodsId);
        CurrentAuthorityGuard.requireAll("goods:edit");
        if(request==null||request.expectedVersion()==null||request.expectedVersion()<0||request.expectedVersion()==Long.MAX_VALUE
                ||request.seriesId()!=null&&!MaterialForecastSnapshotReader.validSeries(request.seriesId()))
            throw GoodsPriceAnalysisService.invalid("请选择有效的市场参考并提供当前关联版本");
        tx.bind();writeAccess.requireWritableAndLock(goodsId);
        // Recheck purchase authority after acquiring the master row lock as well.
        access.require(GoodsPriceContracts.Kind.PURCHASE);
        var previous=bindings.find(goodsId);
        if(previous.version()!=request.expectedVersion())throw new ApiException(ErrorCode.CONFLICT,"货品市场关联已有修改，请刷新后重新选择");
        String digest=null;
        if(request.seriesId()!=null) {
            Benchmark selected=benchmarks.find(request.seriesId());
            if(selected==null||!selected.selectable())throw GoodsPriceAnalysisService.invalid("请选择内置市场参考后重新确认");
            digest=benchmarks.identityDigest(selected);
        }
        var actor=current.get().orElseThrow(()->new ApiException(ErrorCode.FORBIDDEN,"当前登录状态无效"));
        bindings.compareAndSet(goodsId,request.seriesId(),digest,request.expectedVersion(),actor.getId());
        Map<String,Object> change=new LinkedHashMap<>();
        change.put("previousSeriesId",previous.seriesId());change.put("seriesId",request.seriesId());
        change.put("bindingVersion",request.expectedVersion()+1);change.put("identityDigest",digest);
        audit.logCommittedChange(actor.getId(),actor.getLoginAccount(),"update_goods_market_reference","goods",goodsId.toString(),request.seriesId()==null?"已解除市场参考关联":"已保存市场参考关联",change);
        return envelope(goodsId,new GoodsMarketReferenceStore.Binding(request.seriesId(),request.expectedVersion()+1,digest));
    }
    private void requireRead(UUID goodsId) {
        access.require(GoodsPriceContracts.Kind.PURCHASE);
        if(goodsId==null)throw GoodsPriceAnalysisService.invalid("请选择货品");
        references.requireVisibleGoods(goodsId);goods.goods(goodsId);
    }
    private Envelope envelope(UUID goodsId,GoodsMarketReferenceStore.Binding binding) {
        boolean manage=writeAccess.canManage(goodsId);
        Benchmark benchmark=benchmarks.find(binding.seriesId());
        if(!snapshots.enabled())return new Envelope("DISABLED",binding.seriesId(),binding.version(),null,manage,List.of("MARKET_FORECAST_DISABLED"),null,benchmark,feed.offline(),null,60);
        if(binding.seriesId()==null)return new Envelope("UNMAPPED",null,binding.version(),null,manage,List.of("MARKET_REFERENCE_UNMAPPED"),null,null,feed.offline(),null,60);
        Sync sync=benchmark==null?feed.offline():feed.sync(binding.seriesId());
        if(benchmark!=null&&!Objects.equals(binding.identityDigest(),benchmarks.identityDigest(benchmark)))
            return new Envelope("UNAVAILABLE",binding.seriesId(),binding.version(),null,manage,List.of("MARKET_REFERENCE_IDENTITY_CHANGED"),null,benchmark,sync,null,60);
        var read=snapshots.read(binding.seriesId());
        if(benchmark==null&&read.snapshot()!=null&&!Objects.equals(binding.identityDigest(),snapshots.identityDigest(read.snapshot())))
            return new Envelope("UNAVAILABLE",binding.seriesId(),binding.version(),null,manage,List.of("MARKET_REFERENCE_IDENTITY_CHANGED"),null,null,sync,null,60);
        String status=read.status();
        if(benchmark!=null&&read.status().equals("SYNC_PENDING"))status="ERROR".equals(sync.status())?"SYNC_FAILED":"SYNC_PENDING";
        return new Envelope(status,binding.seriesId(),binding.version(),read.snapshot(),manage,read.reasons(),read.snapshot()==null?null:snapshots.expiresAt(read.snapshot()),benchmark,sync,feed.quote(benchmark,read.snapshot()),60);
    }
}
