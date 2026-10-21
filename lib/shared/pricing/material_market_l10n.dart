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
    '先核对材质、牌号、地区、币种、单位与税价口径，选择后点击确定。',
    'Check material, grade, region, currency, unit and tax basis, then confirm your selection.',
    '재질, 등급, 지역, 통화, 단위 및 세금 기준을 확인한 후 선택을 확정하세요.',
  ],
  'noSelection': ['尚未选择行情基准', 'No benchmark selected', '선택한 시세 기준 없음'],
  'emptyCatalog': [
    '暂无可关联行情。请先由维护人员导入有授权来源的 CSV 行情并生成快照，再重新加载；当前未接入实时行情源。',
    'No benchmarks are available. Ask an operator to import authorized CSV prices and generate a snapshot, then reload. A live feed is not connected.',
    '연결할 시세가 없습니다. 담당자가 허가된 CSV 시세를 가져와 스냅샷을 생성한 후 새로고침하세요. 실시간 시세는 연결되지 않았습니다.',
  ],
  'DISABLED': [
    '行情尚未配置。请由维护人员配置行情快照并导入有授权来源的 CSV 数据；当前未接入实时行情源。',
    'Market snapshots are not configured. Ask an operator to configure snapshots and import authorized CSV data. A live feed is not connected.',
    '시세 스냅샷이 설정되지 않았습니다. 담당자가 스냅샷을 설정하고 허가된 CSV 데이터를 가져와야 합니다. 실시간 시세는 연결되지 않았습니다.',
  ],
  'UNMAPPED': ['尚未关联行情基准', 'No market benchmark linked', '연결된 시세 기준 없음'],
  'STALE': [
    '行情已过期，暂停未来研判。请更新行情快照后重新加载。',
    'Market data is stale. Projections are paused until the snapshot is updated.',
    '시세가 오래되어 전망을 중단했습니다. 스냅샷을 갱신한 후 새로고침하세요.',
  ],
  'UNAVAILABLE': [
    '行情暂不可用，请重新加载或核对行情快照。',
    'Market data is unavailable. Reload or review the snapshot.',
    '시세를 사용할 수 없습니다. 새로고침하거나 스냅샷을 확인하세요.',
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
  'imported': ['CSV 导入快照', 'CSV snapshot', 'CSV 스냅샷'],
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
