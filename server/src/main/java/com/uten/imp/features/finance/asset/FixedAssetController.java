package com.uten.imp.features.finance.asset;

import com.uten.imp.features.finance.report.ReportTableResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;
import java.util.UUID;

/**
 * 固定资产 + 长期待摊 API（C5，依赖 C3 总账）。
 *
 * <ul>
 *   <li>固定资产：GET/POST /api/finance/fixed-assets，PUT/DELETE /{id}。</li>
 *   <li>长期待摊：GET/POST /api/finance/deferred-expenses，PUT/DELETE /{id}。</li>
 *   <li>计提（幂等）：POST /api/finance/fa/depreciate?period=YYYY-MM、POST /api/finance/fa/amortize?period=。</li>
 *   <li>报表：GET /api/finance/reports/fa/depreciation-schedule、/fa/amortization-schedule。</li>
 * </ul>
 */
@RestController
@RequestMapping("/api/finance")
@RequiredArgsConstructor
public class FixedAssetController {

    private final FixedAssetService service;

    // ======================== 固定资产 ========================

    @GetMapping("/fixed-assets")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public List<Map<String, Object>> listAssets() {
        return service.listAssets();
    }

    @PostMapping("/fixed-assets")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public Map<String, Object> createAsset(@RequestBody Map<String, Object> body) {
        return Map.of("id", service.createAsset(body));
    }

    @PutMapping("/fixed-assets/{id}")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public Map<String, Object> updateAsset(@PathVariable UUID id, @RequestBody Map<String, Object> body) {
        service.updateAsset(id, body);
        return Map.of("ok", true);
    }

    @DeleteMapping("/fixed-assets/{id}")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public Map<String, Object> deleteAsset(@PathVariable UUID id) {
        service.deleteAsset(id);
        return Map.of("ok", true);
    }

    // ======================== 长期待摊 ========================

    @GetMapping("/deferred-expenses")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public List<Map<String, Object>> listDeferred() {
        return service.listDeferred();
    }

    @PostMapping("/deferred-expenses")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public Map<String, Object> createDeferred(@RequestBody Map<String, Object> body) {
        return Map.of("id", service.createDeferred(body));
    }

    @PutMapping("/deferred-expenses/{id}")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public Map<String, Object> updateDeferred(@PathVariable UUID id, @RequestBody Map<String, Object> body) {
        service.updateDeferred(id, body);
        return Map.of("ok", true);
    }

    @DeleteMapping("/deferred-expenses/{id}")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public Map<String, Object> deleteDeferred(@PathVariable UUID id) {
        service.deleteDeferred(id);
        return Map.of("ok", true);
    }

    // ======================== 计提 ========================

    /** 计提折旧（幂等重跑期间：先回滚该期间 FA_DEP 凭证+日志再重建）。 */
    @PostMapping("/fa/depreciate")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public Map<String, Object> depreciate(@RequestParam String period) {
        int n = service.depreciate(period);
        return Map.of("period", period, "assets", n);
    }

    /** 计提摊销（幂等重跑期间）。 */
    @PostMapping("/fa/amortize")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public Map<String, Object> amortize(@RequestParam String period) {
        int n = service.amortize(period);
        return Map.of("period", period, "items", n);
    }

    // ======================== 报表 ========================

    /** 固定资产折旧清单（原值/月折旧/已提月数/累计折旧/净值）。 */
    @GetMapping("/reports/fa/depreciation-schedule")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse depreciationSchedule() {
        return service.depreciationSchedule();
    }

    /** 长期待摊摊销清单（总额/月摊销/已摊月数/累计摊销/余额）。 */
    @GetMapping("/reports/fa/amortization-schedule")
    @PreAuthorize("hasAuthority('finance_report:view')")
    public ReportTableResponse amortizationSchedule() {
        return service.amortizationSchedule();
    }
}
