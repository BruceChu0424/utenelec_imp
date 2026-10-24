import 'package:flutter/widgets.dart';

String recoveryText(BuildContext context, String chinese) {
  final values = _text[chinese];
  if (values == null) return chinese;
  return switch (Localizations.localeOf(context).languageCode) {
    'en' => values[0],
    'ko' => values[1],
    _ => chinese,
  };
}

const _text = <String, List<String>>{
  '出差时按人开通远程访问，回来后关闭；同时最多授权5人，不是固定名单。': [
    'Enable remote access per person for a trip and revoke it on return. Up to five people may be authorized at a time; the list can change.',
    '출장 시 개인별 원격 접속을 허용하고 복귀 후 해제하세요. 고정 명단이 아니라 한 번에 최대 5명까지 허용됩니다.',
  ],
  '管理出差远程授权': ['Manage temporary remote access', '출장 원격 접속 권한 관리'],
  '运行与灾备': ['Operations and recovery', '운영 및 재해 복구'],
  '本机连接': ['This device’s connection', '이 기기의 연결'],
  '调整连接': ['Change connection', '연결 변경'],
  '这里只调整这台设备的连接，不改变公司业务运行位置。': [
    'This changes this device’s connection only. It does not move the company’s business service.',
    '이 기기의 연결만 변경하며 회사 업무 서비스 위치는 변경하지 않습니다.',
  ],
  '独立救援入口': ['Independent recovery portal', '독립 복구 포털'],
  '公司业务服务不可达时，仍可在独立入口查询备份、管理已登记目标和恢复演练。需要另行绑定的救援口令与动态验证码。': [
    'When the business service is unavailable, use the independent portal to inspect backups, registered targets and recovery drills. A separately enrolled recovery password and authenticator code are required.',
    '업무 서비스에 연결할 수 없어도 독립 포털에서 백업, 등록 대상 및 복구 훈련을 확인할 수 있습니다. 별도로 등록한 복구 비밀번호와 인증 코드가 필요합니다.',
  ],
  '尚未登记可信救援地址，请联系管理员完成入口验收。': [
    'No trusted recovery address is configured. Ask an administrator to commission it.',
    '신뢰할 수 있는 복구 주소가 등록되지 않았습니다. 관리자에게 설정을 요청하세요.',
  ],
  '已登记入口': ['Registered portal', '등록된 포털'],
  '现场先关机并隔离旧主，核验独立恢复证据后，由超级管理员人工启用备用服务；网络断开不会自动切换。': [
    'Power off and isolate the old primary on site, verify independent recovery evidence, then let a super-admin manually activate the standby. A network outage never triggers automatic failover.',
    '현장에서 기존 주 서버를 종료하고 격리한 뒤 독립 복구 증거를 확인해야 최고 관리자가 대기 서비스를 수동으로 활성화할 수 있습니다. 네트워크 단절 시 자동 전환하지 않습니다.',
  ],
  '打开独立救援入口': ['Open independent recovery portal', '독립 복구 포털 열기'],
  '首次绑定须在公司内网，由超级管理员本人重新验证，并由运维开放短期绑定窗口。': [
    'First enrollment requires the super-admin’s fresh verification on the company network and a short enrollment window opened by operations.',
    '최초 등록은 사내망에서 최고 관리자 본인의 재인증과 운영 담당자가 연 단기 등록 시간이 필요합니다.',
  ],
  '绑定独立救援身份': ['Enroll independent recovery identity', '독립 복구 신원 등록'],
  '继续绑定独立救援身份': ['Continue recovery enrollment', '복구 신원 등록 계속'],
  '无法打开独立救援入口，请使用已登记的救援地址。': [
    'Could not open the portal. Use the registered recovery address.',
    '포털을 열 수 없습니다. 등록된 복구 주소를 사용하세요.',
  ],
  '独立救援入口暂不可用，请检查这台设备的网络。': [
    'The recovery portal is unavailable. Check this device’s network.',
    '복구 포털을 사용할 수 없습니다. 이 기기의 네트워크를 확인하세요.',
  ],
  '一次性绑定已准备，请立即继续。绑定将在五分钟内过期，不要分享页面地址。': [
    'One-time enrollment is ready. Continue now; it expires within five minutes. Do not share the page address.',
    '일회용 등록이 준비되었습니다. 5분 이내에 만료되므로 바로 진행하세요. 페이지 주소를 공유하지 마세요.',
  ],
  '无法准备救援身份绑定，请核验公司内网连接和短期绑定窗口。': [
    'Could not prepare enrollment. Check the company connection and enrollment window.',
    '등록을 준비할 수 없습니다. 사내 연결 및 등록 허용 시간을 확인하세요.',
  ],
};
