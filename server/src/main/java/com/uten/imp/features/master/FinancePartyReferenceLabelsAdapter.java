package com.uten.imp.features.master;

import com.uten.imp.application.port.FinancePartyReferenceLabelsPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.util.NativeQueryResults;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import java.util.*;

/** Follows PaymentReferenceLabelsAdapter: resolve only authorized document references,
 * retaining a retired/hidden master's stored name without exposing its other fields.
 */
@Service
@RequiredArgsConstructor
public class FinancePartyReferenceLabelsAdapter implements FinancePartyReferenceLabelsPort {
    private final EntityManager em;
    @Override @Transactional(readOnly=true)
    public Map<UUID,String> clients(Collection<UUID> ids) { return resolve("clients",ids); }
    @Override @Transactional(readOnly=true)
    public Map<UUID,String> suppliers(Collection<UUID> ids) { return resolve("suppliers",ids); }
    private Map<UUID,String> resolve(String table,Collection<UUID> requested) {
        if(requested==null || requested.isEmpty())return Map.of();
        if(requested.size()>200 || requested.stream().anyMatch(Objects::isNull))
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"金融单据引用名称一次最多200个有效UUID");
        var ids=requested.stream().distinct().sorted().toList();
        var query=em.createNativeQuery("SELECT id,name FROM "+table+" WHERE id IN :ids").setParameter("ids",ids);
        Map<UUID,String> labels=new HashMap<>();
        for(Object[] row:NativeQueryResults.objectArrayRows(query)) {
            if(row[0] instanceof UUID id && ids.contains(id) && row[1] instanceof String name && !name.isBlank())
                labels.put(id,name);
        }
        return Map.copyOf(labels);
    }
}
