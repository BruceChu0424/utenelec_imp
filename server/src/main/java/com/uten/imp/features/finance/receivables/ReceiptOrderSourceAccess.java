package com.uten.imp.features.finance.receivables;

import com.uten.imp.application.port.CurrentStaffAuthorityPort;
import com.uten.imp.application.port.SalesDocumentReadScopePort;
import com.uten.imp.common.util.NativeQueryResults;
import com.uten.imp.common.util.NativeValueConverters;
import com.uten.imp.common.web.*;
import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;
import java.util.*;

/** One authority for a newly chosen receipt order, shared by preparation and writes. */
@Component
@RequiredArgsConstructor
public class ReceiptOrderSourceAccess {
    private final EntityManager em;
    private final SalesDocumentReadScopePort salesScope;
    private final CurrentStaffAuthorityPort staff;
    public record Source(UUID id,UUID clientId,UUID currencyId,short status,boolean stopped,boolean closed,String billNo) { }
    private NativeReadScope scope() {
        Set<String> permissions=staff.currentStaffPermissions();
        boolean full=permissions.contains("finance:view:all");
        if(!full && !permissions.contains("sales_order:view"))
            throw new ApiException(ErrorCode.FORBIDDEN,"选择新的订单收款来源需要查看订货单权限");
        return full ? new NativeReadScope("TRUE",null,Set.of())
                : salesScope.nativeReadScope("orders.owner_employee_id","receiptOrderSourceOwners");
    }
    @Transactional(readOnly=true)
    public Source require(UUID orderId) {
        NativeReadScope scope=scope();
        var query=em.createNativeQuery("""
                SELECT orders.id,orders.client_id,orders.currency_id,orders.status,
                       orders.is_stopped,orders.is_closed,orders.bill_no
                FROM sales_orders orders WHERE orders.id=:orderId AND NOT orders.is_deleted AND
                """+"("+scope.predicate()+")").setParameter("orderId",orderId);
        scope.bind(query);
        var rows=NativeQueryResults.objectArrayRows(query);
        if(rows.isEmpty())throw new ApiException(ErrorCode.NOT_FOUND,"订货单不存在或无权引用该收款来源");
        if(rows.size()!=1)throw new ApiException(ErrorCode.CONFLICT,"订货单来源不唯一，请核对");
        Object[] row=rows.getFirst();
        if(!Objects.equals(row[0],orderId))throw new ApiException(ErrorCode.CONFLICT,"订货单来源已变化，请重新引用");
        return new Source((UUID)row[0],(UUID)row[1],(UUID)row[2],((Number)row[3]).shortValue(),
                Boolean.TRUE.equals(row[4]),Boolean.TRUE.equals(row[5]),Objects.toString(row[6],null));
    }

    public record Choice(UUID id,String billNo,java.time.LocalDate billDate,java.time.LocalDate deliverDate,
                         UUID sellerId,String sellerName,short status,UUID clientId,UUID currencyId,boolean closed,boolean stopped) { }
    /** Minimal bounded references for the receipt capability; no price or customer-wide money. */
    @Transactional(readOnly=true,isolation=org.springframework.transaction.annotation.Isolation.REPEATABLE_READ)
    public PageResponse<Choice> choices(String keyword,String billNo,UUID sellerId,int page,int size,String sort,String order) {
        NativeReadScope scope=scope();var pageable=Pageables.of(page,size);
        String where=" FROM sales_orders orders LEFT JOIN clients client ON client.id=orders.client_id "
                +"LEFT JOIN employees seller ON seller.id=orders.seller_id WHERE NOT orders.is_deleted AND orders.status=1 AND ("+scope.predicate()+")";
        boolean search=keyword!=null&&!keyword.isBlank(),bill=billNo!=null&&!billNo.isBlank();
        if(search)where+=" AND (orders.bill_no ILIKE :keyword OR client.name ILIKE :keyword)";
        if(bill)where+=" AND orders.bill_no ILIKE :billNo";
        if(sellerId!=null)where+=" AND orders.seller_id=:seller";
        String ordering=java.util.Map.of("billNo","orders.bill_no","billDate","orders.bill_date",
                "deliverDate","orders.deliver_date","seller","seller.full_name").get(sort==null?"billDate":sort);
        if(ordering==null)throw new ApiException(ErrorCode.VALIDATION_FAILED,"订货单来源不支持此排序列");
        var count=em.createNativeQuery("SELECT count(*)"+where);
        var data=em.createNativeQuery("SELECT orders.id,orders.bill_no,orders.bill_date,orders.deliver_date,orders.seller_id,"
                +"seller.full_name,orders.status,orders.client_id,orders.currency_id,orders.is_closed,orders.is_stopped"+where+" ORDER BY "+ordering
                +("asc".equalsIgnoreCase(order)?" ASC":" DESC")+",orders.id");
        for(var query:java.util.List.of(count,data)){
            scope.bind(query);if(search)query.setParameter("keyword","%"+keyword.trim()+"%");
            if(bill)query.setParameter("billNo","%"+billNo.trim()+"%");if(sellerId!=null)query.setParameter("seller",sellerId);
        }
        long total=((Number)count.getSingleResult()).longValue();
        var rows=NativeQueryResults.objectArrayRows(data.setFirstResult(Pageables.checkedOffset(pageable.getPageNumber()+1,pageable.getPageSize()))
                .setMaxResults(pageable.getPageSize()));
        var items=rows.stream().map(row->new Choice((UUID)row[0],Objects.toString(row[1],null),NativeValueConverters.toLocalDate(row[2]),
                NativeValueConverters.toLocalDate(row[3]),(UUID)row[4],Objects.toString(row[5],null),((Number)row[6]).shortValue(),(UUID)row[7],(UUID)row[8],Boolean.TRUE.equals(row[9]),Boolean.TRUE.equals(row[10]))).toList();
        return new PageResponse<>(items,pageable.getPageNumber()+1,pageable.getPageSize(),total,
                total==0?0:Math.toIntExact((total+pageable.getPageSize()-1)/pageable.getPageSize()));
    }
}
