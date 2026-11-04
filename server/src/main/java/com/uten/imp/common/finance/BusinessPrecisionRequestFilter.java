package com.uten.imp.common.finance;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.*;
import jakarta.servlet.*;
import jakarta.servlet.http.*;
import lombok.RequiredArgsConstructor;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;
import java.io.IOException;

@Component @RequiredArgsConstructor @Order(Ordered.HIGHEST_PRECEDENCE+30)
public class BusinessPrecisionRequestFilter extends OncePerRequestFilter {
    private final ObjectMapper json;
    @Override protected void doFilterInternal(HttpServletRequest request,HttpServletResponse response,FilterChain chain)throws ServletException,IOException{
        try(var ignored=BusinessPrecisionContext.use(BusinessPrecisionContext.parse(request.getHeader(BusinessPrecisionContext.HEADER)))){chain.doFilter(request,response);}
        catch(ApiException invalid){response.setStatus(invalid.getCode().getHttpStatus());response.setContentType("application/json;charset=UTF-8");json.writeValue(response.getOutputStream(),ApiError.of(invalid.getCode(),invalid.getMessage()));}
        catch(ServletException|IOException failure){throw failure;}
        catch(RuntimeException failure){throw failure;}
        catch(Exception impossible){throw new ServletException("数值处理上下文无法释放",impossible);}
    }
}
