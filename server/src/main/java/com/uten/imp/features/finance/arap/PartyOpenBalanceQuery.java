package com.uten.imp.features.finance.arap;

import com.uten.imp.application.port.PartyOpenBalancePort;
import com.uten.imp.common.finance.PartyOpenBalances;
import com.uten.imp.features.finance.LegacyOpeningBalanceSql;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.Collection;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/**
 * 往来单位未结余额的唯一查询(ADR-128), 经 {@link PartyOpenBalancePort} 给各模块用。
 *
 * <p>一页一条 SQL: 按「往来单位 × 币种」取原币合计(单据币种精确求和, 不换算)、
 * 全币种正式应收(应付)账面本币毛额(信用口径)、原币未核实部分。口径:
 * <ul>
 *   <li>原币余额取 {@code amount_balance_original}; 本位币行缺原币时按账面本币(本位币原币 = 本币)。</li>
 *   <li>原币未核实 = 旧系统迁入的 {@code LEGACY_UNVERIFIED} 行, 以及非本位币行满足
 *       {@link LegacyOpeningBalanceSql#unverifiedOriginalCondition()} 的(缺币种 / 缺原币);
 *       这些行只有本币可信, 单列, 不进任何币种。</li>
 *   <li>信用口径 {@code openBookLocal} = 全部币种正式应收(应付)行的账面本币, 不扣预收(预付);
 *       缺原币的正式行照样计入(本币账面可信), 旧系统迁入行不计入(科目性质未核实, 只在原币未核实里单列)。
 *       账面本币按各行立账时冻结的汇率, 收款当天汇率的差额记在收款行的汇兑差额里, 不回写应收。</li>
 * </ul>
 * AR / AP 各一份常量 SQL, 方向与往来列都是字面量, 这样 {@code idx_arap_client_date} /
 * {@code idx_arap_supplier_date} 两个部分索引能用上。
 */
@Component
@RequiredArgsConstructor
public class PartyOpenBalanceQuery implements PartyOpenBalancePort {

    static final String CLIENT_SQL = balanceSql(
            "AR", "client_id", "'RECEIVABLE'", "'CUSTOMER_PREPAYMENT'");
    static final String SUPPLIER_SQL = balanceSql(
            "AP", "supplier_id", "'PAYABLE'", "'PREPAYMENT','CREDIT','CLAIM_CREDIT'");
    static final String CURRENCY_SQL = """
            SELECT currency.id, currency.name, COALESCE(currency.is_base_currency, FALSE)
            FROM currencies currency
            """;

    private final EntityManager em;

    @Override
    public PartyOpenBalances clients(Collection<UUID> clientIds) {
        return load(CLIENT_SQL, clientIds);
    }

    @Override
    public PartyOpenBalances suppliers(Collection<UUID> supplierIds) {
        return load(SUPPLIER_SQL, supplierIds);
    }

    private PartyOpenBalances load(String sql, Collection<UUID> partyIds) {
        Map<UUID, PartyOpenBalances.Currency> currencies = new HashMap<>();
        @SuppressWarnings("unchecked")
        List<Object[]> currencyRows = em.createNativeQuery(CURRENCY_SQL).getResultList();
        for (Object[] row : currencyRows) {
            UUID id = (UUID) row[0];
            currencies.put(id, new PartyOpenBalances.Currency(
                    id, (String) row[1], Boolean.TRUE.equals(row[2])));
        }
        Set<UUID> ids = new LinkedHashSet<>();
        if (partyIds != null) {
            partyIds.stream().filter(Objects::nonNull).forEach(ids::add);
        }
        if (ids.isEmpty()) {
            return new PartyOpenBalances(currencies, Map.of());
        }
        @SuppressWarnings("unchecked")
        List<Object[]> rows = em.createNativeQuery(sql)
                .setParameter("partyIds", List.copyOf(ids))
                .getResultList();
        Map<UUID, Accumulator> byParty = new LinkedHashMap<>();
        for (Object[] row : rows) {
            Accumulator party = byParty.computeIfAbsent((UUID) row[0], ignored -> new Accumulator());
            UUID currencyId = (UUID) row[1];
            if (currencyId != null) {
                party.currencies.add(new PartyOpenBalances.CurrencyAmounts(
                        currencyId, decimal(row[2]), decimal(row[3]), decimal(row[4])));
            }
            party.openBookLocal = party.openBookLocal.add(decimal(row[5]));
            party.unverifiedLocal = party.unverifiedLocal.add(decimal(row[6]));
            party.unverifiedCount += ((Number) row[7]).longValue();
        }
        Map<UUID, PartyOpenBalances.Party> parties = new HashMap<>();
        byParty.forEach((id, party) -> parties.put(id, new PartyOpenBalances.Party(
                party.currencies, party.openBookLocal, party.unverifiedLocal, party.unverifiedCount)));
        return new PartyOpenBalances(currencies, parties);
    }

    /**
     * 只由上面两个常量调用, 参数全是本类写死的白名单字面量(方向、往来列、科目种类), 不接外部输入。
     */
    private static String balanceSql(String direction, String partyColumn, String openKinds, String creditKinds) {
        return """
                SELECT item.party_id, item.currency_id,
                       COALESCE(SUM(item.balance_original)
                           FILTER (WHERE NOT item.unverified AND item.open_item_kind IN (%3$s)), 0),
                       COALESCE(-SUM(item.balance_original)
                           FILTER (WHERE NOT item.unverified AND item.open_item_kind IN (%4$s)), 0),
                       COALESCE(-SUM(item.amount_balance)
                           FILTER (WHERE NOT item.unverified AND item.open_item_kind IN (%4$s)), 0),
                       COALESCE(SUM(item.amount_balance) FILTER (WHERE item.open_item_kind IN (%3$s)), 0),
                       COALESCE(SUM(item.amount_balance) FILTER (WHERE item.unverified), 0),
                       COUNT(*) FILTER (WHERE item.unverified)
                FROM (
                    SELECT ledger.%2$s AS party_id, ledger.currency_id, ledger.open_item_kind,
                           ledger.amount_balance,
                           COALESCE(ledger.amount_balance_original,
                                    CASE WHEN currency.is_base_currency THEN ledger.amount_balance END)
                               AS balance_original,
                           (ledger.open_item_kind = 'LEGACY_UNVERIFIED'
                            OR (NOT COALESCE(currency.is_base_currency, FALSE) AND (%5$s))) AS unverified
                    FROM ar_ap_ledger ledger
                    LEFT JOIN currencies currency ON currency.id = ledger.currency_id
                    %6$s
                    WHERE ledger.direction = '%1$s' AND ledger.status = 1 AND ledger.is_deleted = FALSE
                      AND ledger.is_settled = FALSE AND ledger.%2$s IN (:partyIds)
                ) item
                GROUP BY item.party_id, item.currency_id
                """.formatted(direction, partyColumn, openKinds, creditKinds,
                LegacyOpeningBalanceSql.unverifiedOriginalCondition(), LegacyOpeningBalanceSql.PROOF_JOIN);
    }

    private static BigDecimal decimal(Object value) {
        if (value == null) return BigDecimal.ZERO;
        if (value instanceof BigDecimal decimal) return decimal;
        return new BigDecimal(value.toString());
    }

    private static final class Accumulator {
        private final List<PartyOpenBalances.CurrencyAmounts> currencies = new ArrayList<>();
        private BigDecimal openBookLocal = BigDecimal.ZERO;
        private BigDecimal unverifiedLocal = BigDecimal.ZERO;
        private long unverifiedCount;
    }
}
