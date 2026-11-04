package com.uten.imp.features.finance.gl;

import com.uten.imp.application.port.FinancialChartCurrencyReadPort;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.util.*;

/** Called only behind the owning purpose's authorization gate and, for posting, chart hierarchy locks. */
@Service @RequiredArgsConstructor
public class FinancialChartCurrencyReadAdapter implements FinancialChartCurrencyReadPort {
    private final JdbcTemplate db;
    @Override @Transactional(readOnly=true) public List<Choice> choices() {
        return db.query("SELECT id,code,name,is_base_currency,status FROM currencies WHERE NOT is_deleted ORDER BY is_base_currency DESC,name,code,id",
                (rs,n)->new Choice(rs.getObject(1,UUID.class),rs.getString(2),rs.getString(3),rs.getBoolean(4),rs.getString(5)));
    }
    @Override @Transactional(readOnly=true) public Map<String,Reference> read(Set<String> codes) {
        if(codes==null||codes.isEmpty())return Map.of();if(codes.size()>5000)throw new IllegalArgumentException("Too many chart currency references");
        var choices=choices();Map<UUID,Choice> currencies=new HashMap<>();choices.forEach(choice->currencies.put(choice.id(),choice));
        var base=choices.stream().filter(Choice::baseCurrency).toList();UUID baseId=base.size()==1?base.getFirst().id():null;
        Map<String,Reference> result=new LinkedHashMap<>();
        new NamedParameterJdbcTemplate(db).query("SELECT code,currency_id,currency_name,row_version FROM finance_chart_codes WHERE code IN(:codes)",Map.of("codes",codes),rs->{
            String code=rs.getString(1),source=rs.getString(3);UUID id=rs.getObject(2,UUID.class);
            if(id==null&&(source==null||source.isBlank()))id=baseId;
            var currency=currencies.get(id);result.put(code,new Reference(code,currency==null?null:id,currency!=null&&currency.baseCurrency(),source,rs.getLong(4)));
        });
        return Collections.unmodifiableMap(result);
    }
}
