import 'package:flutter/widgets.dart';

import 'gen/app_localizations.dart';

String tableReadStatusText(BuildContext context, String key) {
  // Isolated table and picker hosts may not install the application's
  // delegates. Keep their established Chinese fallback, as basicDataL10n does.
  final language =
      Localizations.of<AppLocalizations>(context, AppLocalizations) == null
      ? 'zh'
      : Localizations.localeOf(context).languageCode;
  return _texts[key]![switch (language) {
    'en' => 1,
    'ko' => 2,
    _ => 0,
  }];
}

const _texts = <String, List<String>>{
  'details': ['查看详情', 'View details', '자세히 보기'],
  'retry': ['重试', 'Retry', '다시 시도'],
  'close': ['关闭', 'Close', '닫기'],
  'loadFailed': ['数据加载失败', 'Data could not be loaded', '데이터를 불러오지 못했습니다'],
  'loadImpact': [
    '尚未取得本次查询的数据。重试只会重新读取数据。',
    'Data for this query has not been loaded. Retrying only reads the data again.',
    '현재 조회의 데이터를 불러오지 못했습니다. 재시도는 데이터만 다시 불러옵니다.',
  ],
  'refreshFailed': [
    '更新失败，显示上次数据',
    'Update failed; showing previous data',
    '갱신에 실패하여 이전 데이터를 표시합니다',
  ],
  'refreshImpact': [
    '下方为上次成功读取的数据，尚未核对最新变化。重试只会重新读取数据。',
    'The rows below are from the last successful read and have not been checked for recent changes. Retrying only reads the data again.',
    '아래는 마지막으로 불러온 데이터이며 최신 변경 사항을 확인하지 못했습니다. 재시도는 데이터만 다시 불러옵니다.',
  ],
  'appendFailed': [
    '下一页加载失败',
    'Next page could not be loaded',
    '다음 페이지를 불러오지 못했습니다',
  ],
  'prependFailed': [
    '上一页加载失败',
    'Previous page could not be loaded',
    '이전 페이지를 불러오지 못했습니다',
  ],
  'pageImpact': [
    '已加载的数据仍可查看。重试只会重新读取失败的页面。',
    'Loaded rows remain available. Retrying only reads the failed page again.',
    '이미 불러온 데이터는 계속 볼 수 있습니다. 재시도는 실패한 페이지만 다시 불러옵니다.',
  ],
  'groupFailed': ['分组加载失败', 'Group could not be loaded', '그룹을 불러오지 못했습니다'],
  'groupImpact': [
    '此分组未能完成读取，已显示的记录仍保留。重试只会重新读取此分组。',
    'This group could not finish loading. Its displayed rows are retained. Retrying only reads this group again.',
    '그룹을 모두 불러오지 못했으며 표시된 기록은 유지됩니다. 재시도는 이 그룹만 다시 불러옵니다.',
  ],
  'groupEmptyImpact': [
    '尚未取得此分组的记录。重试只会重新读取此分组。',
    'Records for this group have not been loaded. Retrying only reads this group again.',
    '이 그룹의 기록을 불러오지 못했습니다. 재시도는 이 그룹만 다시 불러옵니다.',
  ],
  'guidance': [
    '请检查连接后重试；若仍失败，可复制详情交给管理员。',
    'Check the connection and retry. If it still fails, copy the details for an administrator.',
    '연결을 확인한 후 다시 시도하세요. 계속 실패하면 상세 내용을 복사하여 관리자에게 전달하세요.',
  ],
};
