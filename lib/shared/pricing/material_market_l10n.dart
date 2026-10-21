import 'package:flutter/widgets.dart';

String materialMarketText(BuildContext context, String key) {
  final index = switch (Localizations.maybeLocaleOf(context)?.languageCode) {
    'en' => 1,
    'ko' => 2,
    _ => 0,
  };
  return (_copy[key] ?? _copy['review']!)[index];
}

String materialMarketHorizon(BuildContext context, int horizon) =>
    switch (Localizations.maybeLocaleOf(context)?.languageCode) {
      'en' => 'Next $horizon observations',
      'ko' => '향후 $horizon개 관측 기간',
      _ => '未来 $horizon 个观测期',
    };

const _copy = <String, List<String>>{
  'title': ['原材料行情与研判', 'Material market outlook', '원자재 시황 및 전망'],
  'link': ['关联行情基准', 'Link market benchmark', '시세 기준 연결'],
  'change': ['更换行情基准', 'Change benchmark', '시세 기준 변경'],
  'unlink': ['解除关联', 'Unlink benchmark', '연결 해제'],
  'unlinkConfirm': [
    '解除后，此货品不再显示该行情研判。历史成交参考保持原有口径。',
    'This item will stop showing this market outlook. Its transaction reference keeps its existing basis.',
    '이 품목의 시황 전망 표시가 중단됩니다. 기존 거래 참고가는 유지됩니다.',
  ],
  'confirm': ['确定', 'Confirm', '확인'],
  'cancel': ['取消', 'Cancel', '취소'],
  'close': ['关闭', 'Close', '닫기'],
  'refresh': ['重新加载', 'Reload', '새로고침'],
  'loading': ['正在读取行情依据', 'Loading market evidence', '시황 근거 조회 중'],
  'saving': ['正在确认关联', 'Confirming benchmark link', '연결 확인 중'],
  'choose': ['选择与货品一致的行情基准', 'Choose a matching benchmark', '품목에 맞는 시세 기준 선택'],
  'selectionHint': [
    '选择沪铜、沪铝或沪银等对应品种，核对期货与现货、币种及单位后点击确定。关联只需保存一次，后续行情自动更新。',
    'Choose the matching benchmark and check futures or spot basis, currency and unit. Confirm once; later prices update automatically.',
    '해당 품목의 선물·현물 기준, 통화와 단위를 확인한 후 확정하세요. 한 번 연결하면 이후 시세가 자동 갱신됩니다.',
  ],
  'noSelection': ['尚未选择行情基准', 'No benchmark selected', '선택한 시세 기준 없음'],
  'emptyCatalog': [
    '暂未读取到可关联的内置行情品种，请重新加载或联系管理员检查行情服务。',
    'Built-in benchmarks could not be loaded. Reload or ask an administrator to check the market service.',
    '내장 시세 품목을 불러오지 못했습니다. 새로고침하거나 관리자에게 시세 서비스를 확인해 달라고 요청하세요.',
  ],
  'DISABLED': [
    '自动行情服务尚未连接，可先关联品种。服务连接后将按该关联更新行情。',
    'The automatic market service is not connected. You can link a benchmark now; prices will update through that link once connected.',
    '자동 시세 서비스가 연결되지 않았습니다. 품목을 먼저 연결하면 서비스 연결 후 해당 시세가 갱신됩니다.',
  ],
  'UNMAPPED': ['尚未关联行情基准', 'No market benchmark linked', '연결된 시세 기준 없음'],
  'STALE': [
    '行情已过期，暂停未来研判。请核对自动更新状态与最近行情时间。',
    'Market evidence is stale. Projections are paused; check the update status and quote time.',
    '시세가 오래되어 전망을 중단했습니다. 자동 갱신 상태와 최근 시세 시각을 확인하세요.',
  ],
  'UNAVAILABLE': [
    '行情暂不可用，请重新加载或检查行情服务连接。已保存的品种关联会保留。',
    'Market data is unavailable. Reload or check the service connection. Saved benchmark links are retained.',
    '시세를 사용할 수 없습니다. 새로고침하거나 서비스 연결을 확인하세요. 저장된 품목 연결은 유지됩니다.',
  ],
  'INSUFFICIENT': [
    '行情样本不足，暂不提供未来研判',
    'Insufficient market data for an outlook',
    '시세 표본이 부족하여 전망을 제공하지 않습니다',
  ],
  'BASELINE_ONLY': [
    '仅基线估计，预测尚未通过回测',
    'Baseline estimate; model has not passed validation',
    '기준선 추정만 제공, 예측 검증 미통과',
  ],
  'READY': ['已通过历史回测', 'Historical validation passed', '과거 데이터 검증 통과'],
  'review': ['依据待核对', 'Evidence needs review', '근거 확인 필요'],
  'saveUnverified': [
    '关联结果尚未核实，请重新加载后再操作。系统不会自动重复提交。',
    'The saved link could not be verified. Reload before continuing. The change is not retried automatically.',
    '연결 결과가 확인되지 않았습니다. 새로고침 후 다시 진행하세요. 변경은 자동으로 재전송되지 않습니다.',
  ],
  'quote': ['最近行情', 'Latest market quote', '최근 시세'],
  'projection': ['未来价格估计', 'Future price estimates', '향후 가격 추정'],
  'baselineProjection': ['未来基线估计', 'Future baseline estimates', '향후 기준선 추정'],
  'interval': ['模型标称 80% 区间', 'Nominal 80% model interval', '모델 명목 80% 구간'],
  'sessions': [
    '观测期按行情数据记录计数，通常为交易日；不对应自然日。',
    'Horizons count market observations, usually trading sessions, rather than calendar days.',
    '기간은 달력 날짜가 아닌 시세 관측 기록(통상 거래일) 수로 계산됩니다.',
  ],
  'UP': ['倾向上涨', 'Upward tendency', '상승 경향'],
  'DOWN': ['倾向下跌', 'Downward tendency', '하락 경향'],
  'UNCERTAIN': ['方向不明', 'Uncertain direction', '방향 불확실'],
  'RISING': [
    '上涨风险较高，结合交期与库存核对采购安排',
    'Rising-price risk; review purchasing with stock and lead time',
    '가격 상승 위험, 재고 및 납기를 고려해 구매 검토',
  ],
  'WATCH': ['暂宜持续询价与观察', 'Continue monitoring quotes', '견적 및 시세 관찰 유지'],
  'decisionLimit': [
    '市场走势不能单独决定是否下单，还需核对库存、交期及供应商报价。行情不会自动改写成交参考或采购单价。',
    'Market direction alone cannot decide an order. Review stock, lead times and supplier quotes. Market data does not change the transaction reference or purchase prices.',
    '시장 방향만으로 발주를 결정할 수 없습니다. 재고, 납기 및 공급업체 견적을 확인하세요. 시세가 거래 참고가나 구매가를 변경하지 않습니다.',
  ],
  'source': ['来源', 'Source', '출처'],
  'asOf': ['行情截至', 'Market data as of', '시세 기준일'],
  'generated': ['生成时间', 'Generated', '생성 시각'],
  'SYNC_PENDING': [
    '品种关联已保存，等待首次行情',
    'Benchmark saved; waiting for the first prices',
    '품목 연결 저장됨, 첫 시세 대기 중',
  ],
  'SYNC_FAILED': [
    '行情同步失败，品种关联已保留',
    'Market synchronization failed; benchmark link retained',
    '시세 동기화 실패, 품목 연결 유지',
  ],
  'RESEARCH_ONLY': [
    '研究模式：历史归档回放',
    'Research mode: historical archive replay',
    '연구 모드: 과거 자료 재생',
  ],
  'researchProjection': [
    '历史回放研究预测',
    'Historical replay research forecasts',
    '과거 자료 재생 연구 예측',
  ],
  'researchLimit': [
    '历史归档缺少当时发布版本，本结果属于研究预测，尚未验证实时预测效果，不提供主动采购建议。',
    'Historical archives lack publication vintages. These are research forecasts, without verified live predictive performance or active purchasing advice.',
    '과거 자료에 당시 공개 버전이 없어 연구 예측으로만 제공합니다. 실시간 예측 성능은 검증되지 않았으며 구매 권고를 제공하지 않습니다.',
  ],
  'anchorMAE': [
    '预测值和 MAE 已折算至当前主力合约价位',
    'Forecasts and MAE are converted to the current main-contract price level',
    '예측값과 MAE는 현재 주력 계약 가격 수준으로 환산됨',
  ],
  'replayCoverage': [
    '历史回放 80% 区间覆盖比例',
    'Historical replay 80% interval coverage',
    '과거 재생 80% 구간 포함 비율',
  ],
  'settlement': ['最近日终结算', 'Latest daily settlement', '최근 일일 정산가'],
  'settlementDate': ['日终交易日', 'Settlement trading date', '일일 정산 거래일'],
  'delayedQuote': [
    '最新延迟行情（至少 30 分钟）',
    'Latest delayed quote (at least 30 minutes)',
    '최근 지연 시세(최소 30분)',
  ],
  'quoteStale': [
    '延迟行情已过期，仅供按下列时间核对',
    'Delayed quote is stale; review its timestamps below',
    '지연 시세가 오래되었습니다. 아래 시각을 확인하세요',
  ],
  'contract': ['合约', 'Contract', '계약'],
  'marketTime': ['行情时间', 'Market timestamp', '시세 시각'],
  'fetchedAt': ['读取时间', 'Fetched at', '조회 시각'],
  'quoteContract': ['日终采用合约', 'Daily settlement contract', '일일 정산 계약'],
  'sourceFetchedAt': ['日终数据读取时间', 'Daily data fetched at', '일일 데이터 조회 시각'],
  'historyRecordCount': ['历史记录数', 'Historical records', '과거 기록 수'],
  'autoConnected': ['自动更新已连接', 'Automatic updates connected', '자동 갱신 연결됨'],
  'autoStopped': [
    '自动更新未运行，关联已保存',
    'Automatic updates are not running; link saved',
    '자동 갱신 중지됨, 연결 저장됨',
  ],
  'syncOFFLINE': [
    '自动行情服务未连接，关联已保存',
    'Automatic market service offline; link saved',
    '자동 시세 서비스 오프라인, 연결 저장됨',
  ],
  'syncUnknown': [
    '暂无法核对自动更新状态，保留上次行情依据',
    'Automatic update status cannot be verified; previous market evidence is retained',
    '자동 갱신 상태를 확인할 수 없어 이전 시세 근거를 유지합니다',
  ],
  'syncFETCHING': ['正在读取最新行情', 'Fetching latest prices', '최신 시세 조회 중'],
  'syncBACKFILLING': ['正在补充历史行情', 'Loading historical prices', '과거 시세 보완 중'],
  'syncMODEL': ['正在更新研究预测', 'Updating research forecasts', '연구 예측 갱신 중'],
  'syncERROR': [
    '自动更新失败，关联已保留；请核对服务连接',
    'Automatic update failed; the link is retained. Check the service connection.',
    '자동 갱신에 실패했지만 연결은 유지됩니다. 서비스 연결을 확인하세요.',
  ],
  'lastSuccessAt': ['上次更新', 'Last successful update', '최근 갱신'],
  'nextSyncAt': ['下次检查', 'Next check', '다음 확인'],
  'basis': ['行情依据与回测', 'Market evidence and validation', '시세 근거 및 검증'],
  'model': ['模型版本', 'Model version', '모델 버전'],
  'library': ['算法库版本', 'Library version', '라이브러리 버전'],
  'dataset': ['数据摘要', 'Dataset digest', '데이터 요약'],
  'folds': ['回测窗口', 'Validation windows', '검증 구간'],
  'coverage': [
    '80% 区间实际覆盖率',
    'Observed 80% interval coverage',
    '80% 구간 실제 포함률',
  ],
  'baselineMAE': ['末值基线 MAE', 'Last-value baseline MAE', '직전 값 기준 MAE'],
  'modelMAE': ['模型 MAE', 'Model MAE', '모델 MAE'],
  'maeHint': [
    'MAE 为平均绝对误差，单位与行情价格一致；历史结果不保证未来表现。',
    'MAE is mean absolute error in the quote unit. Historical results do not guarantee future performance.',
    'MAE는 시세 단위의 평균 절대 오차입니다. 과거 결과는 미래 성과를 보장하지 않습니다.',
  ],
  'SPOT': ['现货', 'Spot', '현물'],
  'FUTURES': ['期货', 'Futures', '선물'],
  'COPPER': ['铜', 'Copper', '구리'],
  'ALUMINIUM': ['铝', 'Aluminium', '알루미늄'],
  'SILVER': ['银', 'Silver', '은'],
  'POLYCARBONATE': ['PC 聚碳酸酯', 'PC polycarbonate', 'PC 폴리카보네이트'],
};
