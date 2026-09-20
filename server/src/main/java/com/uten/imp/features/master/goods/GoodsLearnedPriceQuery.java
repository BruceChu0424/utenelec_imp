package com.uten.imp.features.master.goods;

import com.uten.imp.features.master.goods.dto.GoodsLearnedPriceView;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.util.UUID;

/** Main-record display of learned costs; ordinary goods/sales-price visibility never grants access. */
@Service
@RequiredArgsConstructor
public class GoodsLearnedPriceQuery {
    private final JdbcTemplate jdbc;
    private final GoodsCostMasker costs;

    @Transactional(readOnly = true)
    public Prices find(UUID goodsId) {
        if (!costs.canView()) return new Prices(null, null);
        var rows = jdbc.query("""
                SELECT g.default_purchase_price, ps.name, pc.name, pu.name, pm.name,
                       g.default_purchase_price_tax_rate,
                       g.default_subcontract_price, ss.name, sc.name, su.name, sm.name,
                       g.default_subcontract_price_tax_rate
                FROM goods g
                LEFT JOIN suppliers ps ON ps.id=g.default_purchase_price_supplier_id
                LEFT JOIN colors pc ON pc.id=g.default_purchase_price_color_id
                LEFT JOIN units pu ON pu.id=g.default_purchase_price_unit_id
                LEFT JOIN currencies pm ON pm.id=g.default_purchase_price_currency_id
                LEFT JOIN suppliers ss ON ss.id=g.default_subcontract_price_supplier_id
                LEFT JOIN colors sc ON sc.id=g.default_subcontract_price_color_id
                LEFT JOIN units su ON su.id=g.default_subcontract_price_unit_id
                LEFT JOIN currencies sm ON sm.id=g.default_subcontract_price_currency_id
                WHERE g.id=? AND NOT g.is_deleted
                """, (rs, index) -> new Prices(view(rs, 1), view(rs, 7)), goodsId);
        return rows.isEmpty() ? new Prices(null, null) : rows.getFirst();
    }

    private static GoodsLearnedPriceView view(java.sql.ResultSet row, int offset) throws java.sql.SQLException {
        var price = row.getBigDecimal(offset);
        if (price == null) return null;
        String supplier = row.getString(offset + 1), color = row.getString(offset + 2),
                unit = row.getString(offset + 3), currency = row.getString(offset + 4);
        var tax = row.getBigDecimal(offset + 5);
        return new GoodsLearnedPriceView(price, supplier, color, unit, currency, tax,
                supplier != null && unit != null && currency != null && tax != null);
    }
    public record Prices(GoodsLearnedPriceView purchase, GoodsLearnedPriceView subcontract) {}
}
