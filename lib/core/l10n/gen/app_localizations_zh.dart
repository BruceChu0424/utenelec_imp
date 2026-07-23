// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => '优腾综合管理平台';

  @override
  String get appName => 'Uten IMP';

  @override
  String get commonConfirm => '确认';

  @override
  String get commonCancel => '取消';

  @override
  String get commonSave => '保存';

  @override
  String get commonDelete => '删除';

  @override
  String get commonEdit => '编辑';

  @override
  String get commonAdd => '新增';

  @override
  String get commonSearch => '搜索';

  @override
  String get commonRefresh => '刷新';

  @override
  String get commonRetry => '重试';

  @override
  String get commonClose => '关闭';

  @override
  String get commonBack => '返回';

  @override
  String get commonLoading => '加载中…';

  @override
  String get commonNoData => '暂无数据';

  @override
  String get commonError => '出错了，请稍后重试';

  @override
  String get commonSuccess => '操作成功';

  @override
  String get commonFailed => '操作失败';

  @override
  String get commonMore => '更多';

  @override
  String get commonViewAll => '查看全部';

  @override
  String get commonAction => '操作';

  @override
  String get loginTitle => '欢迎回来';

  @override
  String get loginSubtitle => '登录到优腾综合管理平台';

  @override
  String get loginAccountLabel => '账号';

  @override
  String get loginAccountHint => '请输入员工工号或手机号';

  @override
  String get loginAccountRequired => '请输入账号';

  @override
  String get loginPasswordLabel => '密码';

  @override
  String get loginPasswordHint => '请输入密码';

  @override
  String get loginPasswordRequired => '请输入密码';

  @override
  String get loginRememberMe => '记住此设备';

  @override
  String get loginForgotPassword => '忘记密码？';

  @override
  String get loginButton => '登 录';

  @override
  String get loginLoggingIn => '登录中…';

  @override
  String get loginSuccess => '登录成功';

  @override
  String get loginFailed => '账号或密码错误';

  @override
  String get loginWelcomeHint => '演示模式：任意账号密码即可登录';

  @override
  String get loginFooter => '© 2026 优腾 · 综合管理平台';

  @override
  String get navDashboard => '工作台';

  @override
  String get navProfile => '我的';

  @override
  String get navSettings => '设置';

  @override
  String dashboardWelcome(Object name) {
    return '欢迎，$name';
  }

  @override
  String get dashboardWelcomeSubtitle => '今天也要加油哦';

  @override
  String get dashboardTodayStats => '今日概览';

  @override
  String get dashboardQuickActions => '快捷操作';

  @override
  String get statTodayOutput => '今日产量';

  @override
  String get statOutputUnit => '件';

  @override
  String get statInventory => '当前库存';

  @override
  String get statOnlineEmployees => '在线员工';

  @override
  String get statPendingTodos => '待办事项';

  @override
  String statTrendUp(Object percent) {
    return '较昨日 +$percent%';
  }

  @override
  String statTrendDown(Object percent) {
    return '较昨日 $percent%';
  }

  @override
  String get settingsTitle => '设置';

  @override
  String get settingsSectionAppearance => '外观';

  @override
  String get settingsThemeMode => '主题模式';

  @override
  String get settingsThemeLight => '浅色';

  @override
  String get settingsThemeDark => '深色';

  @override
  String get settingsThemeSystem => '跟随系统';

  @override
  String get settingsLanguage => '语言';

  @override
  String get settingsLanguageZh => '简体中文';

  @override
  String get settingsLanguageEn => 'English';

  @override
  String get settingsFontSize => '字号';

  @override
  String get settingsFontSmall => '小';

  @override
  String get settingsFontMedium => '中';

  @override
  String get settingsFontLarge => '大';

  @override
  String get settingsFontXLarge => '超大';

  @override
  String get settingsSectionPerformance => '性能';

  @override
  String get settingsPerformanceTier => '性能模式';

  @override
  String get settingsPerformanceAuto => '自动';

  @override
  String get settingsPerformanceLite => '省电';

  @override
  String get settingsPerformanceStandard => '标准';

  @override
  String get settingsPerformanceRich => '极致';

  @override
  String get settingsPerformanceHint => '性能差的设备建议选省电模式';

  @override
  String get settingsSectionAbout => '关于';

  @override
  String get settingsVersion => '版本';

  @override
  String get settingsLogout => '退出登录';

  @override
  String get settingsLogoutConfirm => '确定要退出登录吗？';

  @override
  String get profileTitle => '我的';

  @override
  String get profileEditProfile => '编辑资料';

  @override
  String get profileChangePassword => '修改密码';

  @override
  String get profileEmployeeCode => '工号';

  @override
  String get profileDepartment => '部门';

  @override
  String get profilePosition => '岗位';

  @override
  String get entryTitle => '欢迎使用优腾';

  @override
  String get entrySubtitle => '请选择登录方式';

  @override
  String get entryStaff => '内部人员登录';

  @override
  String get entryStaffDesc => '员工 / 人事 / 财务 / 管理层 / 保安';

  @override
  String get entryVisitor => '访客登录';

  @override
  String get entryVisitorDesc => '外来访客预约登记';

  @override
  String get entryStaffHint => '您是优腾员工，请走员工通道';

  @override
  String get visitorLoginTitle => '访客登录';

  @override
  String get visitorLoginSubtitle => '输入手机号获取验证码';

  @override
  String get visitorPhoneLabel => '手机号';

  @override
  String get visitorPhoneHint => '请输入手机号';

  @override
  String get visitorCodeLabel => '验证码';

  @override
  String get visitorCodeHint => '请输入验证码';

  @override
  String get visitorCodeRequired => '请输入验证码';

  @override
  String get visitorGetCode => '获取验证码';

  @override
  String visitorCodeCountdown(Object seconds) {
    return '${seconds}s 后重发';
  }

  @override
  String get visitorLoginButton => '登 录';

  @override
  String get visitorLoggingIn => '登录中…';

  @override
  String get visitorCodeSent => '验证码已发送';

  @override
  String visitorCodeSentDev(Object code) {
    return '验证码：$code（开发期）';
  }

  @override
  String get visitorIsEmployee => '该手机号为优腾员工账号，请走员工通道登录';

  @override
  String get visitorPhoneInvalid => '请输入正确的手机号';

  @override
  String get visitorHomeTitle => '我的访客预约';

  @override
  String get visitorApplyNew => '预约来访';

  @override
  String get visitorFilterAll => '全部';

  @override
  String get visitorFilterPending => '申请中';

  @override
  String get visitorFilterApproved => '已批准';

  @override
  String get visitorFilterRejected => '已拒绝';

  @override
  String get visitorApplyTitle => '来访预约';

  @override
  String get visitorApplyName => '姓名';

  @override
  String get visitorApplyNameHint => '请输入真实姓名';

  @override
  String get visitorApplyIdCard => '身份证号';

  @override
  String get visitorApplyIdCardHint => '选填';

  @override
  String get visitorApplyCompany => '来访单位';

  @override
  String get visitorApplyCompanyHint => '选填';

  @override
  String get visitorApplyPurpose => '来访事由';

  @override
  String get visitorApplyPurposeHint => '请说明来访目的';

  @override
  String get visitorApplyVehicle => '是否开车';

  @override
  String get visitorApplyPlate => '车牌号';

  @override
  String get visitorApplyPlateHint => '请输入车牌号';

  @override
  String get visitorApplyHost => '接待人';

  @override
  String get visitorApplyHostHint => '选择要拜访的同事';

  @override
  String get visitorApplyDept => '接待部门';

  @override
  String get visitorApplyVisitTime => '计划到访时间';

  @override
  String get visitorApplySubmit => '提交预约';

  @override
  String get visitorApplySubmitting => '提交中…';

  @override
  String get visitorApplyValidateName => '请输入姓名';

  @override
  String get visitorApplyValidatePurpose => '请填写来访事由';

  @override
  String get visitorApplyValidateHost => '请选择接待人';

  @override
  String get visitorApplyValidateVisitTime => '请选择到访时间';

  @override
  String get visitorApplySuccess => '预约已提交，等待审批';

  @override
  String get visitorStatusPending => '申请中';

  @override
  String get visitorStatusHostReviewing => '待接待人确认';

  @override
  String get visitorStatusApproved => '已批准';

  @override
  String get visitorStatusRejected => '已拒绝';

  @override
  String get visitorStatusCheckedIn => '已签到';

  @override
  String get visitorStatusCancelled => '已取消';

  @override
  String get visitorDetailTitle => '预约详情';

  @override
  String get visitorDetailHost => '接待人';

  @override
  String get visitorDetailPurpose => '来访事由';

  @override
  String get visitorDetailVisitTime => '到访时间';

  @override
  String get visitorDetailVehicle => '车辆';

  @override
  String get visitorDetailAppliedAt => '提交时间';

  @override
  String get visitorDetailApprovedAt => '批准时间';

  @override
  String get visitorDetailRejectReason => '拒绝原因';

  @override
  String get visitorDetailQr => '入厂凭证';

  @override
  String get visitorDetailQrHint => '请向保安出示此二维码核验入厂';

  @override
  String get visitorDetailTimeline => '审批轨迹';

  @override
  String get visitorLogout => '退出访客';

  @override
  String get visitorApprovalTitle => '访客审批';

  @override
  String get visitorApprovalPending => '待审批';

  @override
  String get visitorApprovalProcessed => '已处理';

  @override
  String get visitorApprovalApprove => '批准';

  @override
  String get visitorApprovalReject => '拒绝';

  @override
  String get visitorApprovalForward => '转接待人确认';

  @override
  String get visitorApprovalRejectReason => '拒绝原因';

  @override
  String get visitorApprovalRejectReasonHint => '请填写拒绝原因（选填）';

  @override
  String get visitorApprovalConfirmApprove => '确认批准该访客来访？';

  @override
  String get visitorApprovalConfirmReject => '确认拒绝该访客来访？';

  @override
  String get visitorApprovalHostConfirmed => '接待人已确认';

  @override
  String get visitorApprovalEmpty => '暂无待审批的访客';

  @override
  String get myVisitorsTitle => '我的访客';

  @override
  String get myVisitorsEmpty => '暂无需要您确认的访客';

  @override
  String get myVisitorsConfirm => '同意接待';

  @override
  String get myVisitorsReject => '拒绝接待';

  @override
  String get myVisitorsConfirmHint => '确认接待该访客？';

  @override
  String get securityTitle => '访客核验';

  @override
  String get securityScanHint => '将访客二维码对准扫码框';

  @override
  String get securityScanManual => '手动输入凭证';

  @override
  String get securityManualInputHint => '粘贴或输入二维码内容';

  @override
  String get securityPasscodeHint => '输入6位通行码';

  @override
  String get visitorPasscodeLabel => '通行码';

  @override
  String get securityVerifying => '核验中…';

  @override
  String get securityPass => '允许通行';

  @override
  String get securityReject => '禁止通行';

  @override
  String get securityReasonOk => '凭证有效';

  @override
  String get securityReasonInvalid => '二维码无效';

  @override
  String get securityReasonExpired => '凭证已过期';

  @override
  String get securityReasonUsed => '该凭证已使用';

  @override
  String get securityReasonRejected => '该访客已被拒绝';

  @override
  String get securityCheckIn => '确认签到';

  @override
  String get securityCheckInDone => '签到成功';

  @override
  String get securityVisitor => '访客';

  @override
  String get securityPurpose => '事由';

  @override
  String get securityHost => '接待人';

  @override
  String get securityPlate => '车牌';

  @override
  String get securityVisitTime => '到访时间';
}
