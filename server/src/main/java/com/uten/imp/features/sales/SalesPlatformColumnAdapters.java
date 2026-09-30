package com.uten.imp.features.sales;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.platformcolumns.DocumentPlatformColumnAdapter;
import com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter;
import com.uten.imp.common.platformcolumns.PlatformColumnResourceAdapter.FactDefinition;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import java.util.List;
import java.util.Set;

/** Fixed resource registrations; actual detail loaders enforce each domain's row visibility. */
@Configuration
@RequiredArgsConstructor
public class SalesPlatformColumnAdapters {
    private final EntityManager em;
    private final ObjectMapper json;
    private final SecurityContextCurrentUser current;
    private final com.uten.imp.features.sales.quote.SalesQuoteService quoteService;
    private final com.uten.imp.features.sales.order.SalesOrderService orderService;
    private final com.uten.imp.features.sales.shipment.SalesShipmentService shipmentService;
    private final com.uten.imp.features.sales.ret.SalesReturnService retService;
    private final com.uten.imp.features.sales.other_shipment.SalesOtherShipmentService othershipmentService;
    private static final List<FactDefinition> HEADER=List.of(new FactDefinition("totalOriginal","原币合计",true),new FactDefinition("totalLocal","本币合计",true));
    private static final List<FactDefinition> LINE=List.of(new FactDefinition("qty","数量",false),new FactDefinition("weight","重量",false),new FactDefinition("price","单价",true),new FactDefinition("amountOriginal","原币金额",true),new FactDefinition("amountLocal","本币金额",true));

    @Bean
    public PlatformColumnResourceAdapter salesquoteHeaderPlatformColumns() {
        return new DocumentPlatformColumnAdapter("sales_quote","销售报价",current,em,json,
                Set.of("sales_quote:view"),Set.of("sales_quote:edit"),Set.of("sales_order:price:view","sales_quote_finance:view"),
                com.uten.imp.features.sales.quote.SalesQuote.class,
                null,
                quoteService::detail,(id,header)->DocumentPlatformColumnAdapter.draft(header) && header.path("allowedActions").toString().contains("\"edit\""),HEADER);
    }

    @Bean
    public PlatformColumnResourceAdapter salesorderHeaderPlatformColumns() {
        return new DocumentPlatformColumnAdapter("sales_order","销售订货",current,em,json,
                Set.of("sales_order:view"),Set.of("sales_order:edit"),Set.of("sales_order:price:view"),
                com.uten.imp.features.sales.order.SalesOrder.class,
                null,
                orderService::detail,(id,header)->DocumentPlatformColumnAdapter.draft(header) && header.path("writable").asBoolean(false),HEADER);
    }

    @Bean
    public PlatformColumnResourceAdapter salesshipmentHeaderPlatformColumns() {
        return new DocumentPlatformColumnAdapter("sales_shipment","销售出货",current,em,json,
                Set.of("sales_shipment:view","sales_other_shipment:view","sales_shipment_finance:view","warehouse_sales_outbound:view"),Set.of("sales_shipment:edit","sales_other_shipment:edit"),Set.of("sales_order:price:view"),
                com.uten.imp.features.sales.shipment.SalesShipment.class,
                null,
                shipmentService::detail,(id,header)->DocumentPlatformColumnAdapter.draft(header) && header.path("writable").asBoolean(false) && !header.path("rejected").asBoolean(false) && header.path("financeAudit").asInt(0)==0,HEADER);
    }

    @Bean
    public PlatformColumnResourceAdapter salesshipmentItemPlatformColumns() {
        return new DocumentPlatformColumnAdapter("sales_shipment_item","销售出货明细",current,em,json,
                Set.of("sales_shipment:view","sales_other_shipment:view","sales_shipment_finance:view","warehouse_sales_outbound:view"),Set.of("sales_shipment:edit","sales_other_shipment:edit"),Set.of("sales_order:price:view"),
                com.uten.imp.features.sales.shipment.SalesShipment.class,
                "SELECT id,shipment_id FROM sales_shipment_items WHERE id IN (:ids) AND NOT is_deleted",
                shipmentService::detail,(id,header)->DocumentPlatformColumnAdapter.draft(header) && header.path("writable").asBoolean(false) && !header.path("rejected").asBoolean(false) && header.path("financeAudit").asInt(0)==0,LINE)
                .documentRows("SELECT id FROM sales_shipment_items WHERE shipment_id=:document AND NOT is_deleted")
                .documentCreateAuthorities(Set.of("sales_shipment:create", "sales_other_shipment:create"));
    }

    @Bean
    public PlatformColumnResourceAdapter salesreturnHeaderPlatformColumns() {
        return new DocumentPlatformColumnAdapter("sales_return","销售退货",current,em,json,
                Set.of("sales_return:view"),Set.of("sales_return:edit"),Set.of("sales_order:price:view"),
                com.uten.imp.features.sales.ret.SalesReturn.class,
                null,
                retService::detail,(id,header)->DocumentPlatformColumnAdapter.draft(header) && header.path("writable").asBoolean(false),HEADER);
    }

    @Bean
    public PlatformColumnResourceAdapter salesreturnItemPlatformColumns() {
        return new DocumentPlatformColumnAdapter("sales_return_item","销售退货明细",current,em,json,
                Set.of("sales_return:view"),Set.of("sales_return:edit"),Set.of("sales_order:price:view"),
                com.uten.imp.features.sales.ret.SalesReturn.class,
                "SELECT id,return_id FROM sales_return_items WHERE id IN (:ids) AND NOT is_deleted",
                retService::detail,(id,header)->DocumentPlatformColumnAdapter.draft(header) && header.path("writable").asBoolean(false),LINE)
                .documentRows("SELECT id FROM sales_return_items WHERE return_id=:document AND NOT is_deleted")
                .documentCreateAuthorities(Set.of("sales_return:create"));
    }

    @Bean
    public PlatformColumnResourceAdapter salesothershipmentHeaderPlatformColumns() {
        return new DocumentPlatformColumnAdapter("sales_other_shipment","历史其它出货",current,em,json,
                Set.of("sales_other_shipment:view"),Set.of(),Set.of("sales_order:price:view"),
                com.uten.imp.features.sales.other_shipment.SalesOtherShipment.class,
                null,
                othershipmentService::detail,(id,header)->false,HEADER);
    }

    @Bean
    public PlatformColumnResourceAdapter salesothershipmentItemPlatformColumns() {
        return new DocumentPlatformColumnAdapter("sales_other_shipment_item","历史其它出货明细",current,em,json,
                Set.of("sales_other_shipment:view"),Set.of(),Set.of("sales_order:price:view"),
                com.uten.imp.features.sales.other_shipment.SalesOtherShipment.class,
                "SELECT id,shipment_id FROM sales_other_shipment_items WHERE id IN (:ids) AND NOT is_deleted",
                othershipmentService::detail,(id,header)->false,LINE)
                .documentRows("SELECT id FROM sales_other_shipment_items WHERE shipment_id=:document AND NOT is_deleted")
                .documentCreateAuthorities(Set.of());
    }
}
