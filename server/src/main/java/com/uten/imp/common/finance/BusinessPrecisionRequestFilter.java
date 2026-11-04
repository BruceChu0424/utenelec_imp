package com.uten.imp.common.finance;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.uten.imp.common.web.*;
import jakarta.servlet.*;
import jakarta.servlet.http.*;
import lombok.RequiredArgsConstructor;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;
import java.io.IOException;

@Component @RequiredArgsConstructor @Order(Ordered.HIGHEST_PRECEDENCE+30)
public class BusinessPrecisionRequestFilter extends OncePerRequestFilter {
    // 回退仅在容器没有 ObjectMapper bean 时使用（Boot 4 @WebMvcTest 切片不再提供 databind-2 ObjectMapper）；
    // 完整应用始终优先复用容器内主 ObjectMapper，行为不变。findAndRegisterModules+ISO 日期保证 ApiError 与主 mapper 输出同形。
    private static final ObjectMapper FALLBACK=new ObjectMapper().findAndRegisterModules().disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);
    private final ObjectProvider<ObjectMapper> jsonProvider;
    @Override protected void doFilterInternal(HttpServletRequest request,HttpServletResponse response,FilterChain chain)throws ServletException,IOException{
        ObjectMapper json=jsonProvider.getIfAvailable();if(json==null)json=FALLBACK;
        try(var ignored=BusinessPrecisionContext.use(BusinessPrecisionContext.parse(request.getHeader(BusinessPrecisionContext.HEADER)))){chain.doFilter(request,response);}
        catch(ApiException invalid){response.setStatus(invalid.getCode().getHttpStatus());response.setContentType("application/json;charset=UTF-8");json.writeValue(response.getOutputStream(),ApiError.of(invalid.getCode(),invalid.getMessage()));}
        catch(ServletException|IOException failure){throw failure;}
        catch(RuntimeException failure){throw failure;}
        catch(Exception impossible){throw new ServletException("数值处理上下文无法释放",impossible);}
    }
}
