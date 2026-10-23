package com.uten.imp.features.master.paymentstyle;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.concurrency.PaymentStyleHierarchyLock;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.paymentstyle.dto.PaymentStyleDetail;
import com.uten.imp.features.master.paymentstyle.dto.PaymentStyleUpdateRequest;
import com.uten.imp.security.CurrentAuthorityGuard;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.Map;
import java.util.Set;
import java.util.UUID;

/** Field-CAS adapter; hierarchy, financial identity and balances stay in native commands. */
@Service
@RequiredArgsConstructor
public class PaymentStyleInlineEditService {
    private static final Set<String> FIELDS=Set.of("name","sortOrder","departmental","receipt","payment","status");
    private final PaymentStyleService styles;
    private final EntityManager em;
    private final ObjectMapper mapper;
    private final SecurityContextCurrentUser currentUser;
    private final TxSessionVars tx;

    @Transactional
    public PaymentStyleDetail patch(UUID id,Map<String,Object> expected,Map<String,Object> changes) {
        var user=currentUser.get().orElseThrow(()->new ApiException(ErrorCode.UNAUTHORIZED,"当前登录状态无效"));
        if(user.getEmployeeId()==null||user.isVisitor()||!user.isAccountNonLocked()||user.isMustChangePassword()||user.getImpersonatedBy()!=null)
            throw new ApiException(ErrorCode.FORBIDDEN,"当前账号不能编辑资料，请核对登录状态");
        CurrentAuthorityGuard.requireAll("payment_style:view");
        if(changes==null||changes.isEmpty()||expected==null||!FIELDS.containsAll(changes.keySet())||!expected.keySet().containsAll(changes.keySet()))
            throw new ApiException(ErrorCode.VALIDATION_FAILED,"只能编辑允许的类别字段，并须提供每个字段的原值");
        for(var change:changes.entrySet()) {
            String key=change.getKey();JsonNode value=mapper.valueToTree(change.getValue());
            CurrentAuthorityGuard.requireAll("payment_style:"+(key.equals("sortOrder")?"reorder":key.equals("status")?"status":"edit"));
            boolean valid=switch(key) {
                case "sortOrder"->value.isIntegralNumber()&&value.canConvertToInt();
                case "name"->value.isTextual()&&!value.asText().isBlank();
                case "status"->value.isTextual()&&Set.of("使用","禁用").contains(value.asText());
                default->value.isBoolean();
            };
            if(!valid)throw new ApiException(ErrorCode.VALIDATION_FAILED,"编辑值格式不正确，请检查名称、排列顺序或选择项");
        }
        tx.bind();
        PaymentStyleHierarchyLock.lockForHierarchyChange(em);
        try {
            if(em.createNativeQuery("SELECT id FROM payment_styles WHERE id=:id AND NOT is_deleted FOR UPDATE NOWAIT").setParameter("id",id).getResultList().isEmpty())
                throw new ApiException(ErrorCode.NOT_FOUND,"类别不存在");
        } catch(ApiException failure) {throw failure;}
        catch(RuntimeException failure) {var error=new ApiException(ErrorCode.CONFLICT,"类别正在由其他操作更新，请刷新后重试");error.initCause(failure);throw error;}
        JsonNode actual=mapper.valueToTree(styles.detail(id));
        for(String key:changes.keySet())if(!equal(actual.get(key),mapper.valueToTree(expected.get(key))))
            throw new ApiException(ErrorCode.CONFLICT,"该行已有后续修改，请刷新后重新编辑；没有覆盖任何修改");
        PaymentStyleUpdateRequest request=mapper.convertValue(changes,PaymentStyleUpdateRequest.class);
        return styles.update(id,request);
    }
    private static boolean equal(JsonNode actual,JsonNode expected) {
        if(actual==null||actual.isNull())return expected==null||expected.isNull();
        if(actual.isNumber()&&expected!=null&&expected.isNumber())return actual.decimalValue().compareTo(expected.decimalValue())==0;
        return actual.equals(expected);
    }
}
