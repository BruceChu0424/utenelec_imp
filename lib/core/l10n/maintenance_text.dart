import 'package:flutter/widgets.dart';

String maintenanceText(BuildContext context, String chinese) {
  final translated = _text[chinese];
  if (translated == null) return chinese;
  return switch (Localizations.localeOf(context).languageCode) {
    'en' => translated[0],
    'ko' => translated[1],
    _ => chinese,
  };
}

const _text = <String, List<String>>{
  '服务器即将更新': ['Server update coming soon', '서버 업데이트 예정'],
  '服务器正在更新中': ['The server is being updated', '서버 업데이트 중'],
  '正在确认服务恢复': ['Checking service recovery', '서비스 복구 확인 중'],
  '服务恢复需要管理员确认': [
    'Service recovery needs administrator attention',
    '서비스 복구에 관리자 확인이 필요합니다',
  ],
  '请先保存当前工作': ['Save your current work', '현재 작업을 저장하세요'],
  '更新开始时连接会暂时中断。请在倒计时结束前保存正在编辑的内容，并等待当前提交完成。': [
    'The connection will pause when the update starts. Save your edits before the countdown ends and let current submissions finish.',
    '업데이트가 시작되면 연결이 일시 중단됩니다. 남은 시간 안에 편집 내용을 저장하고 진행 중인 제출이 완료될 때까지 기다리세요.',
  ],
  '更新尚未开始，请保存工作并等候服务器通知。': [
    'The update has not started. Save your work and wait for the server notice.',
    '아직 업데이트가 시작되지 않았습니다. 작업을 저장하고 서버 알림을 기다리세요.',
  ],
  '开始时间（北京时间）': ['Starts at (Beijing time)', '시작 시간 (베이징 시간)'],
  '目标版本': ['Target version', '대상 버전'],
  '我知道了，继续保存工作': ['Got it, continue saving work', '확인, 작업 계속 저장'],
  '查看更新提醒': ['View update notice', '업데이트 알림 보기'],
  '服务器更新倒计时': ['Server update countdown', '서버 업데이트 카운트다운'],
  '拖动调整位置，点击查看更新提醒': [
    'Drag to move; select to view the update notice',
    '드래그하여 이동하고 클릭하여 업데이트 알림 보기',
  ],
  '正在更新服务并检查运行状态。请保留当前窗口，恢复后会自动返回。': [
    'The service is being updated and checked. Keep this window open; your screen will return when it is ready.',
    '서비스 업데이트와 상태 확인을 진행 중입니다. 이 창을 유지하면 준비 완료 후 원래 화면으로 돌아갑니다.',
  ],
  '更新尚未完成。请保留当前窗口并联系管理员，服务通过检查后会自动返回。': [
    'The update is not complete. Keep this window open and contact an administrator. Your screen will return after service checks pass.',
    '업데이트가 완료되지 않았습니다. 창을 유지하고 관리자에게 문의하세요. 서비스 검사 통과 후 원래 화면으로 돌아갑니다.',
  ],
  '暂时无法读取更新状态，正在继续检查。': [
    'The update status is temporarily unavailable. Checks will continue.',
    '업데이트 상태를 일시적으로 읽을 수 없습니다. 확인을 계속합니다.',
  ],
  '当前页面和已输入内容保留在此窗口中。恢复连接不会自动重复提交；结果不确定时，请先核对单据。': [
    'This window keeps your page and entered content. Reconnecting will not resubmit anything. Check the document first if a submission result is uncertain.',
    '현재 페이지와 입력 내용은 이 창에 유지됩니다. 재연결 시 자동 재제출하지 않습니다. 제출 결과가 불확실하면 문서를 먼저 확인하세요.',
  ],
  '检查恢复状态': ['Check recovery', '복구 상태 확인'],
  '正在检查': ['Checking', '확인 중'],
  '更新预告已发布': ['Update notice published', '업데이트 사전 공지 게시됨'],
  '等待恢复服务': ['Waiting for service recovery', '서비스 복구 대기 중'],
  '服务更新中': ['Updating service', '서비스 업데이트 중'],
  '恢复后返回工作': ['Return to work when ready', '복구 후 작업으로 돌아가기'],
  '通知用户保存工作': ['Notifying users to save their work', '사용자에게 작업 저장 알림'],
};
