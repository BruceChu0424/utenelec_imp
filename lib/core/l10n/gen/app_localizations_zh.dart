// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appTitle => '优腾·综合管理平台';

  @override
  String get appName => 'UTEN IMP';

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
  String get connectionReconnecting => '网络暂时不稳定，正在自动连接…';

  @override
  String get connectionDisconnected => '暂时连不上服务器，系统会继续自动连接';

  @override
  String get connectionRestored => '网络已恢复，可以继续使用';

  @override
  String get connectionRetryNow => '立即重试';

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
  String get loginAccountHint => '请输入员工工号或手机号';

  @override
  String get loginAccountRequired => '请输入账号';

  @override
  String get loginPasswordHint => '请输入密码';

  @override
  String get loginPasswordRequired => '请输入密码';

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
  String get loginServerRecoveryAction => '恢复自动选择服务器';

  @override
  String get loginServerRecoveryHint => '登录异常或更换网络时使用；只会在此安装包内置的公司与云端地址之间自动选择。';

  @override
  String get loginServerRecoverySuccess => '已恢复自动选择，请重新登录';

  @override
  String get loginServerRecoveryFailed => '服务器选择恢复失败，请稍后重试或联系管理员';

  @override
  String get loginFooter => '© 2026 优腾 · 综合管理平台';

  @override
  String get navDashboard => '工作台';

  @override
  String get navNotice => '通知';

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
  String get settingsFontMedium => '标准';

  @override
  String get settingsFontLarge => '大';

  @override
  String get settingsFontXLarge => '超大';

  @override
  String get settingsFontXXLarge => '超超大';

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
  String get entrySubtitle => '请选择登录方式';

  @override
  String get entryStaff => '内部人员登录';

  @override
  String get entryVisitor => '访客登录';

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
    return '验证码：$code(开发期)';
  }

  @override
  String get visitorIsEmployee => '该手机号为优腾员工账号，请走员工通道登录';

  @override
  String get visitorPhoneInvalid => '请输入正确的手机号';

  @override
  String get visitorHomeTitle => '我的访客预约';

  @override
  String get visitorSettingsTitle => '访客设置';

  @override
  String get visitorSettingsTooltip => '设置';

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
  String get visitorApplyValidateIdCard => '请输入正确的 18 位居民身份证号';

  @override
  String get visitorApplyValidatePurpose => '请填写来访事由';

  @override
  String get visitorApplyValidateHost => '请选择接待人';

  @override
  String get visitorApplyValidateVisitTime => '请选择到访时间';

  @override
  String get visitorApplyValidateVisitTimeFuture => '到访时间需晚于当前时间';

  @override
  String get visitorApplyDuplicateTime => '您已有相同时段的进行中预约，请换一个时间';

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
  String get visitorApprovalRejectReasonHint => '请填写拒绝原因(选填)';

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

  @override
  String get navHrGroup => '人事管理';

  @override
  String get navHrEmployees => '员工档案';

  @override
  String get navHrDepartments => '部门管理';

  @override
  String get navHrOnboarding => '入职办理';

  @override
  String get navHrPayrollGenerate => '工资条生成';

  @override
  String get navHrNoticePublish => '通知发布';

  @override
  String get employeeTitle => '员工档案';

  @override
  String get employeeFabOnboard => '入职';

  @override
  String get employeeSearchHint => '搜索工号 / 姓名 / 车牌';

  @override
  String get employeeEmpty => '暂无员工';

  @override
  String get employeeEmptyHint => '点右下角「入职」添加新员工';

  @override
  String get employeeLoadMore => '加载更多';

  @override
  String get employeeDetailTitle => '员工详情';

  @override
  String get employeeDetailBasic => '基本信息';

  @override
  String get employeeDetailContact => '联系与地址';

  @override
  String get employeeDetailOrg => '组织与用工';

  @override
  String get employeeDetailContract => '合同 / 薪资(按权限可见)';

  @override
  String get employeeDetailEmergency => '紧急联系人';

  @override
  String get employeeDetailHistory => '任职轨迹';

  @override
  String get employeeFieldCode => '工号';

  @override
  String get employeeFieldName => '姓名';

  @override
  String get employeeFieldGender => '性别';

  @override
  String get employeeFieldIdType => '证件类型';

  @override
  String get employeeFieldIdNumber => '证件号码';

  @override
  String get employeeFieldBirthDate => '出生日期';

  @override
  String get employeeFieldEthnicity => '民族';

  @override
  String get employeeFieldPoliticalStatus => '政治面貌';

  @override
  String get employeeFieldMaritalStatus => '婚姻状况';

  @override
  String get employeeFieldPhone => '手机号';

  @override
  String get employeeFieldOfficePhone => '办公电话';

  @override
  String get employeeFieldEmail => '企业邮箱';

  @override
  String get employeeFieldHujiAddress => '户籍地址';

  @override
  String get employeeFieldResidenceAddress => '现居住地';

  @override
  String get employeeFieldDepartment => '所属部门';

  @override
  String get employeeFieldPosition => '岗位';

  @override
  String get employeeFieldSupervisor => '直属上级';

  @override
  String get employeeFieldHireDate => '入职日期';

  @override
  String get employeeFieldWorkYears => '工龄';

  @override
  String employeeWorkYearsYandM(int years, int months) {
    return '$years 年 $months 个月';
  }

  @override
  String employeeWorkYearsMonths(int months) {
    return '$months 个月';
  }

  @override
  String get employeeWorkYearsUnderOneMonth => '不足 1 个月';

  @override
  String get employeeFieldConfirmedDate => '转正日期';

  @override
  String get employeeFieldStatus => '工作状态';

  @override
  String get employeeFieldEmploymentType => '用工形式';

  @override
  String get employeeFieldWorkLocation => '办公地点';

  @override
  String get employeeFieldSeatNo => '工位号';

  @override
  String get employeeFieldContractType => '合同类型';

  @override
  String get employeeFieldContractPeriod => '合同起止';

  @override
  String get employeeFieldProbation => '试用期';

  @override
  String get employeeFieldRenewCount => '续签次数';

  @override
  String get employeeFieldBaseSalary => '基本工资';

  @override
  String get employeeFieldPerfSalary => '绩效/补贴';

  @override
  String get employeeFieldSocialBase => '社保基数';

  @override
  String get employeeFieldHousingBase => '公积金基数';

  @override
  String get employeeFieldBankBranch => '开户银行';

  @override
  String get employeeFieldBankAccount => '银行卡号';

  @override
  String employeeContractPeriodValue(Object end, Object start) {
    return '$start ~ $end';
  }

  @override
  String employeeProbationValue(Object end, Object months) {
    return '$months 个月(至 $end)';
  }

  @override
  String employeeRenewCountValue(Object count) {
    return '$count';
  }

  @override
  String get employeeFieldAccountStatus => '登录账号';

  @override
  String get accountStatusActive => '正常';

  @override
  String get accountStatusLocked => '已锁定';

  @override
  String get accountStatusDisabled => '已停用';

  @override
  String get accountStatusNone => '未开通';

  @override
  String employeeProbationExpiring(Object date, Object days) {
    return '试用期将于 $date 到期(剩 $days 天)，请及时办理转正';
  }

  @override
  String employeeProbationExpired(Object date) {
    return '试用期已于 $date 到期，请尽快办理转正或离职';
  }

  @override
  String employeeContractExpiring(Object date, Object days) {
    return '劳动合同将于 $date 到期(剩 $days 天)，请及时续签';
  }

  @override
  String employeeContractExpired(Object date) {
    return '劳动合同已于 $date 到期，请尽快处理';
  }

  @override
  String get employeeEditTitle => '编辑员工';

  @override
  String get employeeEditBasic => '基本信息';

  @override
  String get employeeEditOrg => '组织信息';

  @override
  String get employeeEditContact => '联系方式';

  @override
  String get employeeEditSalary => '薪资与银行';

  @override
  String get employeeEditFieldPhone => '手机';

  @override
  String get employeeEditFieldDepartment => '部门';

  @override
  String get employeeEditFieldPosition => '岗位';

  @override
  String get employeeEditFieldEmploymentType => '用工性质';

  @override
  String get employeeEditFieldStatus => '员工状态';

  @override
  String get employeeEditSaved => '已保存';

  @override
  String get employeeEditSaveFailed => '保存失败，请重试';

  @override
  String employeeEditLoadFailed(Object error) {
    return '加载失败：$error';
  }

  @override
  String get employeeEditNotFound => '员工不存在';

  @override
  String get employeeEditRequired => '必填';

  @override
  String get employeeOnboardTitle => '新员工入职';

  @override
  String get employeeOnboardGroupProfile => '档案';

  @override
  String get employeeOnboardGroupOrg => '组织';

  @override
  String get employeeOnboardGroupPay => '薪资 / 银行(可选，仅 HR/管理员可见)';

  @override
  String get employeeOnboardSubmit => '提交入职';

  @override
  String get employeeOnboardSuccess => '入职成功，一次性临时密码已交付';

  @override
  String get employeeOnboardSubmitFailed => '提交失败，请重试';

  @override
  String get employeeOnboardNote =>
      '提交后将自动生成工号(UT 前缀)、以手机号作为登录账号，并生成一次性临时密码(身份证后 6 位)；首次登录必须修改密码。';

  @override
  String get employeeOnboardCodeAutoNote => '工号提交后自动生成(UT 前缀，唯一递增)';

  @override
  String get positionPickerTitle => '选择或填写岗位';

  @override
  String get positionPickerHint => '请选择或填写岗位';

  @override
  String get positionPickerDepartmentFirst => '请先选择部门';

  @override
  String get positionPickerSearchHint => '输入岗位名称、编码或职级';

  @override
  String positionPickerUseCustom(Object name) {
    return '使用“$name”作为新岗位';
  }

  @override
  String get positionPickerCustomDescription => '确认后将按当前部门保存';

  @override
  String get positionPickerNoPositions => '该部门暂无岗位，可直接填写新岗位';

  @override
  String get positionPickerLoadFailed => '岗位加载失败，可重试或直接填写新岗位';

  @override
  String get positionPickerClear => '清空';

  @override
  String get employeeOnboardCredentialTitle => '账号已创建';

  @override
  String get employeeOnboardCredentialWarning =>
      '临时密码只显示这一次。请立即通过安全方式交给员工；关闭后系统不会再次显示或保存明文。';

  @override
  String get employeeOnboardAccountLabel => '登录账号';

  @override
  String get employeeOnboardTemporaryPasswordLabel => '一次性临时密码';

  @override
  String get employeeOnboardCopyTemporaryPassword => '复制密码';

  @override
  String get employeeOnboardTemporaryPasswordCopied => '临时密码已复制';

  @override
  String get employeeOnboardCredentialSaved => '我已妥善保存';

  @override
  String get employeeOnboardHintName => '张三';

  @override
  String get employeeOnboardHintIdNumber => '请输入身份证号';

  @override
  String get employeeOnboardIdNumberInvalid => '身份证号格式不正确';

  @override
  String get employeeOnboardHintPhone => '11 位手机号';

  @override
  String get employeeOnboardPhoneRequired => '手机号不能为空';

  @override
  String get employeeOnboardPhoneInvalid => '手机号格式不正确';

  @override
  String get employeeOnboardEmailOptional => '可选';

  @override
  String get employeeOnboardHireDateHint => 'yyyy-MM-dd';

  @override
  String get employeeOnboardPickHireDate => '请选择入职日期';

  @override
  String get employeeOnboardPickDepartment => '请选择部门';

  @override
  String employeeOnboardFieldRequired(Object field) {
    return '$field不能为空';
  }

  @override
  String get employeeOnboardLoadFailed => '加载失败';

  @override
  String get idTypeIdCard => '身份证';

  @override
  String get idTypePassport => '护照';

  @override
  String get idTypeHmtPermit => '港澳台通行证';

  @override
  String get idTypeOther => '其他';

  @override
  String get employeeOffboardTitle => '离职办理';

  @override
  String get employeeOffboardFieldType => '离职类型';

  @override
  String get employeeOffboardFieldDate => '离职日期';

  @override
  String get employeeOffboardPickDate => '选择日期';

  @override
  String get employeeOffboardFieldReason => '离职原因';

  @override
  String get employeeOffboardPickDateRequired => '请选择离职日期';

  @override
  String get employeeOffboardChecksRequired => '请确认所有回收项';

  @override
  String get employeeOffboardConfirmTitle => '确认办理离职？';

  @override
  String get employeeOffboardConfirmBody => '该员工账号将被停用。';

  @override
  String get employeeOffboardConfirmAction => '确认办理离职';

  @override
  String get employeeOffboardNext => '下一步';

  @override
  String get employeeOffboardBack => '上一步';

  @override
  String get employeeOffboardCompleted => '离职办理完成';

  @override
  String get employeeOffboardLoadFailed => '加载失败';

  @override
  String get employeeActions => '更多操作';

  @override
  String get employeeActionTransfer => '调岗';

  @override
  String get employeeActionConfirm => '转正';

  @override
  String get employeeActionOffboard => '办理离职';

  @override
  String get employeeActionRehire => '复职';

  @override
  String get employeeActionDelete => '删除档案';

  @override
  String get employeeActionProvision => '开通登录账号';

  @override
  String get employeeActionLockAccount => '锁定账号';

  @override
  String get employeeActionUnlockAccount => '解锁账号';

  @override
  String get employeeLockAccountSuccess => '账号已锁定';

  @override
  String get employeeUnlockAccountSuccess => '账号已解锁';

  @override
  String get employeeProvisionConfirm =>
      '将为该员工开通登录账号：账号默认为手机号，初始密码为身份证号后6位，首次登录需修改。是否继续？';

  @override
  String get employeeTransferTitle => '员工调岗';

  @override
  String get employeeTransferFieldDate => '生效日期';

  @override
  String get employeeTransferPickDate => '选择日期';

  @override
  String get employeeTransferFieldRemark => '备注';

  @override
  String get employeeTransferDateRequired => '请选择生效日期';

  @override
  String get employeeTransferSuccess => '调岗完成';

  @override
  String get employeeConfirmTitle => '确认转正？';

  @override
  String get employeeConfirmBody => '转正后员工状态将变为「在职」。';

  @override
  String get employeeConfirmSuccess => '转正完成';

  @override
  String get employeeRehireTitle => '确认复职？';

  @override
  String get employeeRehireBody => '复职后员工状态将恢复为「在职」，其登录账号将重新启用(需重新登录)。';

  @override
  String get employeeRehireSuccess => '复职完成';

  @override
  String get employeeDeleteTitle => '确认删除该员工档案？';

  @override
  String get employeeDeleteBody => '删除后其登录账号将被停用，此操作不可恢复。';

  @override
  String get employeeDeleteSuccess => '员工档案已删除';

  @override
  String get resignTypeVoluntary => '主动辞职';

  @override
  String get resignTypeDismissed => '公司辞退';

  @override
  String get resignTypeContractEnd => '合同到期';

  @override
  String get resignTypeRetire => '退休';

  @override
  String get resignCheckAccess => '收回门禁卡';

  @override
  String get resignCheckAssets => '回收公司资产';

  @override
  String get resignCheckAccount => '停用系统账号';

  @override
  String get resignCheckSocial => '停缴社保公积金';

  @override
  String get employeeStatusActive => '在职';

  @override
  String get employeeStatusProbation => '试用';

  @override
  String get employeeStatusOnLeave => '休假';

  @override
  String get employeeStatusResigned => '离职';

  @override
  String get employeeStatusUnknown => '未知';

  @override
  String get genderMale => '男';

  @override
  String get genderFemale => '女';

  @override
  String get employmentTypeRegular => '正式';

  @override
  String get employmentTypeDispatch => '劳务派遣';

  @override
  String get employmentTypeIntern => '实习';

  @override
  String get employmentTypeOutsource => '外包';

  @override
  String get contractTypeFixed => '固定期限';

  @override
  String get contractTypeOpen => '无固定期限';

  @override
  String get contractTypeTask => '任务';

  @override
  String get contractTypeIntern => '实习';

  @override
  String get historyEventOnboard => '入职';

  @override
  String get historyEventTransfer => '调岗';

  @override
  String get historyEventResign => '离职';

  @override
  String get historyEventRehire => '复职';

  @override
  String get departmentTitle => '部门管理';

  @override
  String get departmentTreeTitle => '组织架构';

  @override
  String get departmentEmpty => '选择部门';

  @override
  String get departmentEmptyHint => '点右上角图标打开部门树';

  @override
  String get departmentEmptySelect => '请选择左侧部门';

  @override
  String get departmentTooltipAdd => '新增部门';

  @override
  String get departmentTooltipRefresh => '刷新';

  @override
  String get departmentTooltipTree => '部门树';

  @override
  String get departmentDialogAddTitle => '新增部门';

  @override
  String get departmentDialogDeleteTitle => '删除部门';

  @override
  String get departmentFieldCode => '部门编码';

  @override
  String get departmentFieldCodeHint => '如 DEPT-XX';

  @override
  String get departmentFieldName => '部门名称';

  @override
  String get departmentFieldLevel => '层级';

  @override
  String get departmentCreate => '创建';

  @override
  String get departmentDelete => '删除';

  @override
  String get departmentRequireCodeAndName => '编码与名称必填';

  @override
  String get departmentCreated => '已创建';

  @override
  String get departmentDeleted => '已删除';

  @override
  String departmentDeleteConfirm(Object name) {
    return '确认删除「$name」？仅无子部门且无员工的叶子部门可删。';
  }

  @override
  String departmentLevelAndCode(Object level, Object code) {
    return '$level · 编码 $code';
  }

  @override
  String get departmentStatEmployees => '员工';

  @override
  String get departmentStatChildren => '子部门';

  @override
  String get departmentStatManager => '负责人';

  @override
  String get departmentStatParent => '上级';

  @override
  String departmentEmployeesHeader(Object count) {
    return '员工($count)';
  }

  @override
  String get departmentEmployeesEmpty => '该部门(含子部门)暂无员工';

  @override
  String departmentStatValue(Object label, Object value) {
    return '$label：$value';
  }

  @override
  String get departmentLoadFailed => '加载失败';

  @override
  String get departmentLevelCompany => '公司';

  @override
  String get departmentLevelDecision => '决策层';

  @override
  String get departmentLevelManagement => '管理中心';

  @override
  String get departmentLevelPrimary => '一级部门';

  @override
  String get departmentLevelSecondary => '二级班组';

  @override
  String get departmentLevelTertiary => '三级科室';

  @override
  String get payrollGenerateTitle => '工资条生成';

  @override
  String get payrollStepScope => '选择范围';

  @override
  String get payrollStepItems => '配置薪酬项';

  @override
  String get payrollStepPreview => '预览计算';

  @override
  String get payrollStepSubmit => '提交审核';

  @override
  String get payrollFieldMonth => '工资月份';

  @override
  String get payrollFieldScope => '生成范围';

  @override
  String get payrollItemOvertime => '加班费 (+15%)';

  @override
  String get payrollItemBonus => '绩效奖金 (+10%)';

  @override
  String get payrollItemSocial => '社保公积金 (-10.5%)';

  @override
  String get payrollItemTax => '个人所得税 (-5%)';

  @override
  String get payrollSubmitNote => '提交后将进入财务审核流程，审核通过后由人事发布给员工。';

  @override
  String get payrollSubmitButton => '提交审核';

  @override
  String get payrollSubmitted => '已提交审核，等待财务审核';

  @override
  String payrollLoadFailed(Object error) {
    return '加载失败：$error';
  }

  @override
  String get payrollEmptyPreview => '该范围无可计算员工';

  @override
  String get payrollTableTotalLabel => '合计';

  @override
  String payrollTableTotalValue(Object total, Object count) {
    return '¥ $total · $count 人';
  }

  @override
  String get payrollTableHeaderName => '工号/姓名';

  @override
  String get payrollTableHeaderNet => '实发';

  @override
  String payrollTableRowName(Object name, Object code) {
    return '$name($code)';
  }

  @override
  String payrollTableRowNet(Object net) {
    return '¥ $net';
  }

  @override
  String get payrollNext => '下一步';

  @override
  String get payrollBack => '上一步';

  @override
  String get payrollDeptAll => '全员';

  @override
  String get payrollDeptProduction => '生产部';

  @override
  String get payrollDeptQuality => '质量部';

  @override
  String get payrollDeptHr => '人事部';

  @override
  String get payrollDeptFinance => '财务部';

  @override
  String get noticePublishTitle => '发布通知';

  @override
  String get noticePublishSaveDraft => '存草稿';

  @override
  String get noticePublishDraftSaved => '已保存草稿';

  @override
  String get noticePublishPublishButton => '发布';

  @override
  String get noticePublishTopPriority => '置顶';

  @override
  String get noticePublishTitleHint => '通知标题(必填)';

  @override
  String get noticePublishContentHint => '通知正文……';

  @override
  String get noticePublishScopeTitle => '可见范围';

  @override
  String get noticePublishScopeAll => '全员';

  @override
  String get noticePublishScopeDept => '按部门';

  @override
  String get noticePublishFieldDept => '部门';

  @override
  String get noticePublishScopeAllHint => '将通知到全公司所有员工';

  @override
  String noticePublishScopeDeptHint(Object dept) {
    return '将通知到「$dept」全体员工';
  }

  @override
  String get noticePublishValidateTitle => '请填写标题';

  @override
  String get noticePublishValidateContent => '请填写正文';

  @override
  String get noticePublishConfirmTitle => '确认发布？';

  @override
  String get noticePublishConfirmBodyAll => '将通知到全员';

  @override
  String noticePublishConfirmBodyDept(Object dept) {
    return '将通知到「$dept」';
  }

  @override
  String get noticePublishPublished => '通知已发布';

  @override
  String get noticePublishPublishing => '发布中…';

  @override
  String get noticePublishContentSection => '通知内容';

  @override
  String get noticePublishTypeLabel => '通知类型';

  @override
  String get noticePublishTitleLabel => '标题';

  @override
  String get noticePublishContentLabel => '正文';

  @override
  String get noticePublishUrgentHint => '紧急通知会使用高优先级提醒，请只用于必须立即关注的事项。';

  @override
  String get noticePublishTopPriorityHint => '置顶后会优先显示，并按重要通知提醒接收人。';

  @override
  String get noticePublishScopeSelected => '指定范围';

  @override
  String get noticePublishScopeSelectedHint =>
      '部门与人员可以同时选择；部门包含其下级组织，重复接收人会自动去重。';

  @override
  String get noticePublishDepartmentsLabel => '接收部门(可多选)';

  @override
  String get noticePublishDepartmentsHint => '选择一个或多个部门';

  @override
  String get noticePublishEmployeesLabel => '单独添加人员';

  @override
  String get noticePublishEmployeesHint => '选择指定人员(可多选)';

  @override
  String get noticePublishEmployeePickerTitle => '选择接收人员';

  @override
  String get noticePublishEmployeeSearchHint => '搜索姓名 / 工号';

  @override
  String get noticePublishEmployeeEmpty => '未找到可接收通知的在职账号';

  @override
  String noticePublishEmployeeSelectedCount(int count) {
    return '已选 $count 人';
  }

  @override
  String get noticePublishEmployeeClear => '清空';

  @override
  String get noticePublishEmployeeConfirm => '确定';

  @override
  String get noticePublishValidateAudience => '请至少选择一个部门或人员';

  @override
  String noticePublishAudienceSummary(
    Object departmentCount,
    Object employeeCount,
  ) {
    return '已选 $departmentCount 个部门、$employeeCount 人';
  }

  @override
  String get noticePublishAudienceRecalculateHint =>
      '发布前会按当前组织与账号状态重新核算实际接收人数。';

  @override
  String noticePublishConfirmAudience(Object summary, Object count) {
    return '将发送给 $summary，实际接收 $count 人。';
  }

  @override
  String noticePublishPublishedTo(Object count) {
    return '通知已发布给 $count 人';
  }

  @override
  String get noticeTypeAnnouncement => '公告';

  @override
  String get noticeTypePolicy => '制度';

  @override
  String get noticeTypeBenefit => '福利';

  @override
  String get noticeTypeSystem => '系统';

  @override
  String get noticeTypeUrgent => '紧急';

  @override
  String get noticeTypeBirthday => '生日';

  @override
  String get noticeTypeAnniversary => '入职周年';

  @override
  String get noticeTypeWedding => '新婚';

  @override
  String get noticeTypeNewborn => '新生儿';

  @override
  String get noticeTypeAnnouncementDesc => '公司公告，全员可「点击收到」';

  @override
  String get noticeTypePolicyDesc => '制度发布，全员可「点击收到」';

  @override
  String get noticeTypeBenefitDesc => '福利通知，全员可「点击收到」';

  @override
  String get noticeTypeSystemDesc => '系统通知，全员可「点击收到」';

  @override
  String get noticeTypeUrgentDesc => '紧急通知，高优先级强提醒';

  @override
  String get noticeTypeBirthdayDesc => '为同事庆生，大家可「送上祝福」';

  @override
  String get noticeTypeAnniversaryDesc => '入职周年纪念，大家可「送上祝福」';

  @override
  String get noticeTypeWeddingDesc => '新婚祝福，大家可「送上祝福」';

  @override
  String get noticeTypeNewbornDesc => '喜添新丁，大家可「送上祝福」';

  @override
  String get noticeGroupBroadcast => '公告广播';

  @override
  String get noticeGroupCelebration => '庆典祝福';

  @override
  String get noticeInteractionReceive => '收到';

  @override
  String get noticeInteractionReceived => '已收到';

  @override
  String get noticeClickToReceive => '点击收到';

  @override
  String noticeAckCount(int count) {
    return '$count人已收到';
  }

  @override
  String noticeAckYouAndCount(int count) {
    return '你已收到 · 共 $count 人收到';
  }

  @override
  String get noticeAckRecent => '近期已收到';

  @override
  String get noticeSendBlessing => '送上祝福';

  @override
  String get noticeBlessingSent => '已送祝福';

  @override
  String noticeBlessingCount(int count) {
    return '$count 条祝福';
  }

  @override
  String get noticeBlessingWall => '祝福墙';

  @override
  String noticeBlessingReceivedCount(int count) {
    return '收到 $count 条祝福';
  }

  @override
  String get noticeBlessingWallEmpty => '还没有祝福，送上第一份祝福吧';

  @override
  String get noticeBlessingPlaceholder => '写下你的祝福…';

  @override
  String get noticeBlessingSendButton => '发送祝福';

  @override
  String get noticeBlessingSending => '发送中…';

  @override
  String get noticeBlessingWithdraw => '撤回';

  @override
  String noticeBlessingViewAll(int count) {
    return '查看全部 $count 条';
  }

  @override
  String get noticeBlessingTemplatesTitle => '选一句祝福';

  @override
  String get noticeBlessingValidateEmpty => '请输入祝福内容';

  @override
  String get noticeCelebrationSubjectLabel => '祝福对象';

  @override
  String get noticeCelebrationSubjectHint => '选择要祝福的同事';

  @override
  String get noticeCelebrationSubjectRequired => '请选择祝福对象';

  @override
  String get noticeCelebrationSubjectIsYou => '你';

  @override
  String noticeCelebrationFor(Object name, Object event) {
    return '祝 $name $event';
  }

  @override
  String get noticeQuickCelebrationTitle => '快捷发布祝福';

  @override
  String get noticeQuickCelebrationSubtitle => '选择类型，系统自动套用模板';

  @override
  String get noticeQuickPublish => '发通知';

  @override
  String get noticeQuickBirthday => '生日';

  @override
  String get noticeQuickAnniversary => '入职周年';

  @override
  String get noticeQuickWedding => '新婚';

  @override
  String get noticeQuickNewborn => '新生儿';

  @override
  String celebrationPopupBirthday(Object name) {
    return '$name，今天是你的生日！\n小优祝你生日快乐！';
  }

  @override
  String celebrationPopupAnniversary(Object name, Object label) {
    return '$name，今天是你的入职周年！\n小优祝你$label！';
  }

  @override
  String celebrationPopupWedding(Object name) {
    return '$name，新婚大喜！\n小优祝你们百年好合！';
  }

  @override
  String celebrationPopupNewborn(Object name) {
    return '$name，恭喜喜添新丁！\n小优祝宝宝健康成长！';
  }

  @override
  String get celebrationDismiss => '谢谢小优';

  @override
  String celebrationCardBirthday(Object name) {
    return '今天是 $name 的生日';
  }

  @override
  String celebrationCardAnniversary(Object name, Object label) {
    return '今天是 $name 的$label';
  }

  @override
  String celebrationCardWedding(Object name) {
    return '今天是 $name 的新婚大喜';
  }

  @override
  String celebrationCardNewborn(Object name) {
    return '$name 喜添新丁';
  }

  @override
  String get celebrationCardCta => '送上祝福';

  @override
  String get celebrationCardWall => '查看祝福墙';

  @override
  String get noticeAutoCelebrationTitle => '自动祝福通知';

  @override
  String get noticeAutoCelebrationEnabled => '每日自动为当天生日 / 入职周年的员工发布全员祝福';

  @override
  String get noticeAutoCelebrationTypes => '自动类型';

  @override
  String get noticeAutoCelebrationPublisher => '发布人名称';

  @override
  String get profileChangeEditTitle => '修改个人信息';

  @override
  String get profileChangeEditCta => '修改我的信息';

  @override
  String get profileChangeEditHrOnlyHint => '以下字段请联系人事修改';

  @override
  String get profileChangeSectionBasic => '基本信息(直改生效)';

  @override
  String get profileChangeSectionReview => '联系方式与重要字段(需 HR 审核)';

  @override
  String get profileChangeSectionIdentity => '姓名与紧急联系人(需 HR 审核)';

  @override
  String get profileChangeFieldDirect => '可直接修改';

  @override
  String get profileChangeFieldReview => '需 HR 审核后生效';

  @override
  String get profileChangeFieldHrOnly => '请联系人事修改';

  @override
  String get profileChangePasswordHint => '为安全起见，请输入当前登录密码';

  @override
  String get profileChangePasswordLabel => '当前密码';

  @override
  String get profileChangePasswordWrong => '密码错误，请重试';

  @override
  String get profileChangeSubmitSuccess => '修改已提交，HR 审核后生效';

  @override
  String get profileChangeSubmitApplied => '修改已保存';

  @override
  String get profileChangeSubmitFailed => '提交失败，请稍后重试';

  @override
  String get profileChangeConflict => '档案已被他人更新，请刷新后再试';

  @override
  String get profileChangeRateLimited => '24h 内已提交过该字段的修改，请等待处理';

  @override
  String get profileChangeListTitle => '我的修改申请';

  @override
  String get profileChangeListCta => '查看申请记录';

  @override
  String get profileChangeListEmpty => '暂无修改申请';

  @override
  String get profileChangeFilterAll => '全部';

  @override
  String get profileChangeFilterPending => '待审核';

  @override
  String get profileChangeFilterApplied => '已生效';

  @override
  String get profileChangeFilterApproved => '已通过';

  @override
  String get profileChangeFilterRejected => '已驳回';

  @override
  String get profileChangeFilterCancelled => '已撤销';

  @override
  String get profileChangeStatusPending => '待 HR 审核';

  @override
  String get profileChangeStatusApplied => '已生效';

  @override
  String get profileChangeStatusApproved => '已通过';

  @override
  String get profileChangeStatusRejected => '已驳回';

  @override
  String get profileChangeStatusCancelled => '已撤销';

  @override
  String get profileChangeCancel => '撤销';

  @override
  String get profileChangeCancelledByMe => '已由我撤销';

  @override
  String get profileChangeFieldLabel => '字段';

  @override
  String get profileChangeBefore => '修改前';

  @override
  String get profileChangeAfter => '修改后';

  @override
  String get profileChangeSubmittedAt => '提交时间';

  @override
  String get profileChangeReviewer => '审核人';

  @override
  String get profileChangeReviewComment => '审核意见';

  @override
  String get profileChangeDiffTitle => '本次修改';

  @override
  String profileChangeBatchItems(Object count) {
    return '共 $count 项';
  }

  @override
  String get profileChangeHrQueueTitle => '员工修改审批';

  @override
  String get profileChangeHrQueueEmpty => '暂无待审申请';

  @override
  String get profileChangeReviewApprove => '批准';

  @override
  String get profileChangeReviewReject => '驳回';

  @override
  String get profileChangeRejectDialogTitle => '驳回申请';

  @override
  String get profileChangeRejectReasonRequired => '请填写驳回原因';

  @override
  String get profileChangeRejectReasonHint => '请说明驳回原因，员工会看到';

  @override
  String get profileChangeApproveDialogTitle => '确认批准？';

  @override
  String get profileChangeApproveDialogBody => '批准后将立即合并到员工档案';

  @override
  String get profileChangeConfirm => '确认';

  @override
  String get profileChangeCancel2 => '取消';

  @override
  String get profileChangeRejectSuccess => '已驳回';

  @override
  String get profileChangeApproveSuccess => '已批准';

  @override
  String get profileChangeFieldPhone => '手机';

  @override
  String get profileChangeFieldFullName => '姓名';

  @override
  String get profileChangeFieldHujiAddress => '户籍地址';

  @override
  String get profileChangeFieldEmergencyName => '紧急联系人姓名';

  @override
  String get profileChangeFieldEmergencyPhone => '紧急联系人电话';

  @override
  String get profileChangeFieldEmergencyRelationship => '与本人关系';

  @override
  String profilePendingBadge(Object count) {
    return '$count 项待审';
  }

  @override
  String get profilePendingSectionTitle => '待我审核的修改申请';

  @override
  String get profilePendingSectionEmpty => '该员工暂无待审申请';

  @override
  String get profilePendingSectionViewAll => '全部 →';

  @override
  String get profileFieldPhoneMask => '138****1234';

  @override
  String get profileFieldIdCardMask => '****';

  @override
  String get profileFieldBankAccountMask => '****1234';

  @override
  String get profileFieldGroupIdentity => '身份信息';

  @override
  String get profileFieldGroupContact => '联系方式';

  @override
  String get profileFieldGroupAddress => '地址';

  @override
  String get profileFieldGroupEmergency => '紧急联系人';

  @override
  String get profileFieldGroupOrganization => '组织信息';

  @override
  String get profileEditPolicyHint =>
      '绿色「可直接修改」提交后立即生效；黄色「需 HR 审核」由人事核对后生效；其余字段由人事统一维护。';

  @override
  String profileEditPendingConflictHint(int count) {
    return '你有 $count 条待审申请；相关字段在审核通过前再次修改，可能与在途申请冲突。';
  }

  @override
  String get profileEditFieldAction => '修改';

  @override
  String get profileFieldGroupOrg => '组织与入职';

  @override
  String get profileFieldGroupCompensation => '薪资与银行';

  @override
  String get profileFieldWorkLocation => '工作地';

  @override
  String get profileFieldSeatNo => '工位';

  @override
  String get profileFieldOfficePhone => '办公电话';

  @override
  String get profileFieldMobile => '手机号';

  @override
  String get profileFieldEmail => '邮箱';

  @override
  String get profileFieldResidenceAddress => '现住址';

  @override
  String get profileFieldHujiAddress => '户籍地址';

  @override
  String get profileFieldEthnicity => '民族';

  @override
  String get profileFieldPoliticalStatus => '政治面貌';

  @override
  String get profileFieldMaritalStatus => '婚姻状况';

  @override
  String get profileFieldBirthDate => '出生日期';

  @override
  String get profileFieldGender => '性别';

  @override
  String get profileFieldIdType => '证件类型';

  @override
  String get profileFieldIdNumber => '身份证号';

  @override
  String get profileFieldSupervisor => '直属主管';

  @override
  String get profileFieldHireDate => '入职日期';

  @override
  String get profileFieldConfirmedAt => '转正日期';

  @override
  String get profileFieldEmploymentType => '用工性质';

  @override
  String get profileFieldAttendanceGroup => '考勤组';

  @override
  String get profileFieldPaperArchiveNo => '纸质档案号';

  @override
  String get profileFieldBaseSalary => '基本工资';

  @override
  String get profileFieldPerfSalary => '绩效工资';

  @override
  String get profileFieldSocialInsuranceBase => '社保基数';

  @override
  String get profileFieldSocialInsuranceLocation => '社保缴纳地';

  @override
  String get profileFieldHousingFundBase => '公积金基数';

  @override
  String get profileFieldAllowanceStandard => '补贴标准';

  @override
  String get profileFieldBankBranch => '开户行';

  @override
  String get profileFieldBankAccount => '银行账号';

  @override
  String get profileFieldContractType => '合同类型';

  @override
  String get profileFieldContractStart => '合同起始';

  @override
  String get profileFieldContractEnd => '合同截止';

  @override
  String get profileFieldProbationMonths => '试用期(月)';

  @override
  String get profileFieldRenewCount => '续签次数';

  @override
  String get hubDisabledChip => '未启用';

  @override
  String get hubSectionTaskCenter => '任务中心';

  @override
  String get hubDisabledDocNotice => '该单据类型暂未启用(老库无数据)';

  @override
  String get hubSubDetailPerItem => '一行一货品';

  @override
  String get hubSubSummaryPerDoc => '一行一单';

  @override
  String get hubSubPendingReturnQty => '待入库的退货量';

  @override
  String get hubSubReadOnlyPlan => '计划只读';

  @override
  String get salesHubTitle => '销售管理';

  @override
  String get salesHubSectionReports => '销售报表';

  @override
  String get salesHubSectionScarcity => '稀缺仲裁';

  @override
  String get salesHubTaskOrderProgress => '订单进度查询';

  @override
  String get salesHubTaskOrderProgressSub => '出货与完工进度';

  @override
  String get salesHubDocQuote => '销售报价单';

  @override
  String get salesHubDocQuoteSub => '报价·有效期';

  @override
  String get salesHubDocOrder => '销售订货单';

  @override
  String get salesHubDocOrderSub => '客户下单';

  @override
  String get salesHubDocShipment => '销售出货单';

  @override
  String get salesHubDocShipmentSub => '发货·立应收';

  @override
  String get salesHubDocOtherShipment => '其它出货单';

  @override
  String get salesHubDocOtherShipmentSub => '直接出库';

  @override
  String get salesHubDocReturn => '销售退货单';

  @override
  String get salesHubDocReturnSub => '退货·红字应收';

  @override
  String get salesHubReportDetail => '销售明细报表';

  @override
  String get salesHubReportSummary => '销售汇总报表';

  @override
  String get salesHubScarcity => '稀缺库存让单';

  @override
  String get salesHubScarcitySub => '释放低优先级占用';

  @override
  String get purchaseHubTitle => '采购管理';

  @override
  String get purchaseHubSectionReports => '采购报表';

  @override
  String get purchaseHubTaskCenter => '采购任务中心';

  @override
  String get purchaseHubTaskCenterSub => '按供应商拆订货';

  @override
  String get purchaseHubReturnVendor => '待退回供应商';

  @override
  String get purchaseHubDocRequest => '计划下达的采购申请';

  @override
  String get purchaseHubDocOrder => '采购订货单';

  @override
  String get purchaseHubDocOrderSub => '下单·跟踪到货';

  @override
  String get purchaseHubDocReceipt => '采购收货单';

  @override
  String get purchaseHubDocReceiptSub => '收货·入库';

  @override
  String get purchaseHubDocReturn => '采购退货单';

  @override
  String get purchaseHubDocReturnSub => '退货·出库';

  @override
  String get purchaseHubReportDetail => '采购明细报表';

  @override
  String get purchaseHubReportSummary => '采购汇总报表';

  @override
  String get purchaseHubReportExpediting => '采购催料单';

  @override
  String get purchaseHubReportExpeditingSub => '订货未收·库存';

  @override
  String get subcontractHubTitle => '委外管理';

  @override
  String get subcontractHubSectionReports => '委外报表';

  @override
  String get subcontractHubTaskCenter => '委外任务中心';

  @override
  String get subcontractHubTaskCenterSub => '按委外商拆订货';

  @override
  String get subcontractHubReturnVendor => '待退回供应商';

  @override
  String get subcontractHubDocInquiry => '委外询价单';

  @override
  String get subcontractHubDocInquirySub => '询价(未启用)';

  @override
  String get subcontractHubDocApplication => '计划下达的委外申请';

  @override
  String get subcontractHubDocOrder => '委外订货单';

  @override
  String get subcontractHubDocOrderSub => '下单·跟踪进仓';

  @override
  String get subcontractHubDocReceipt => '委外进仓单';

  @override
  String get subcontractHubDocReceiptSub => '成品进仓·立应付';

  @override
  String get subcontractHubDocMaterialIssue => '委外发料单';

  @override
  String get subcontractHubDocMaterialIssueSub => '材料出仓';

  @override
  String get subcontractHubDocReturn => '委外退货单';

  @override
  String get subcontractHubDocReturnSub => '成品退·出库';

  @override
  String get subcontractHubDocMaterialReturn => '委外材料退货单';

  @override
  String get subcontractHubDocMaterialReturnSub => '材料退回入库';

  @override
  String get subcontractHubDocWaste => '委外材料损耗单';

  @override
  String get subcontractHubDocWasteSub => '登记供应商损耗';

  @override
  String get subcontractHubReportDetail => '委外明细报表';

  @override
  String get subcontractHubReportSummary => '委外汇总报表';

  @override
  String get subcontractHubReportInOut => '委外出入状况表';

  @override
  String get subcontractHubReportInOutSub => '进出综合状况';

  @override
  String get productionHubTitle => '生产管理';

  @override
  String get productionHubSectionReports => '生产报表';

  @override
  String get productionHubSchedule => '生产调度与进度';

  @override
  String get productionHubScheduleSub => '待排产·在产·完工';

  @override
  String get productionHubPlan => '新建生产计划单';

  @override
  String get productionHubPlanSub => '引用销售订单或手工新建·历史记录';

  @override
  String get productionHubPlanHistory => '生产计划历史';

  @override
  String get productionHubPlanHistorySub => '查看计划、审批与分批记录';

  @override
  String get productionHubMaterialAnalysis => '物料分析准备';

  @override
  String get productionHubMaterialAnalysisSub => '齐套分析·路线确认·分批生成';

  @override
  String get productionHubDaily => '生产日报表';

  @override
  String get productionHubDailySub => '完工日报·红冲';

  @override
  String get productionHubReportPlanDetail => '计划明细';

  @override
  String get productionHubReportPlanDetailSub => '日期·货品·状态';

  @override
  String get productionHubReportPlanSummary => '计划汇总';

  @override
  String get productionHubReportPlanSummarySub => '单号·制单·审核';

  @override
  String get productionHubWhereUsed => '物料反查产成品';

  @override
  String get productionHubWhereUsedSub => '材料用在哪些产品';

  @override
  String get financeHubTitle => '钱流管理';

  @override
  String get financeHubSectionReports => '钱流报表';

  @override
  String get financeHubApprovalOwners => '审批负责人设置';

  @override
  String get financeHubTaskApproval => '订货审批任务中心';

  @override
  String get financeHubTaskApprovalSub => '分配给我的审批';

  @override
  String get financeHubTaskOverDelivery => '超量到货审批';

  @override
  String get financeHubTaskOverDeliverySub => '审核超量到货';

  @override
  String get financeHubDocReceipt => '销售收款';

  @override
  String get financeHubDocReceiptSub => '核销应收·直接收款';

  @override
  String get financeHubDocPayment => '采购付款';

  @override
  String get financeHubDocPaymentSub => '核销应付·直接付款';

  @override
  String get financeHubDocExpense => '一般费用';

  @override
  String get financeHubSubAllocatedByDept => '按部门分摊';

  @override
  String get financeHubDocIncome => '其它收入';

  @override
  String get financeHubDocBankTransfer => '银行存取款';

  @override
  String get financeHubDocBankTransferSub => '账户间转入';

  @override
  String get financeHubDocCheck => '支票管理';

  @override
  String get financeHubDocCheckSub => '支票账户视图';

  @override
  String get financeHubDocAssets => '资产与待摊';

  @override
  String get financeHubDocAssetsSub => '子账·折旧·期间';

  @override
  String get financeHubReportArAp => '应收应付';

  @override
  String get financeHubReportArApSub => '客户·供应商余额';

  @override
  String get financeHubReportDetail => '明细报表';

  @override
  String get financeHubReportDetailSub => '收款·付款·费用';

  @override
  String get financeHubReportSummary => '汇总报表';

  @override
  String get financeHubReportSummarySub => '收支汇总';

  @override
  String get financeHubReportStatement => '往来对帐单';

  @override
  String get financeHubReportStatementSub => '客户·供应商对账';

  @override
  String get financeHubReportAccountFlow => '账户流水';

  @override
  String get financeHubReportAccountFlowSub => '账户进出流水';

  @override
  String get financeHubReportRecon => '对账单';

  @override
  String get financeHubReportReconSub => '月结对账';

  @override
  String get financeHubReportCost => '成本核算';

  @override
  String get financeHubReportCostSub => '产品·销售成本';

  @override
  String get financeHubReportGl => '总账报表';

  @override
  String get financeHubReportGlSub => '科目·资产·利润';

  @override
  String get warehouseHubTitle => '仓库管理';

  @override
  String get warehouseHubSectionDocs => '出入库单据';

  @override
  String get warehouseHubSectionDocsDesc => '调拨·其它出入库·领退料·产成品进出仓·盘点';

  @override
  String get warehouseHubSectionInventory => '库存查询';

  @override
  String get warehouseHubSectionInventoryDesc => '即时库存·库存查询·出入库流水';

  @override
  String get warehouseHubSectionReports => '仓库报表';

  @override
  String get warehouseHubSectionReportsDesc => '明细(一行一货品)·汇总(一行一单)';

  @override
  String get warehouseHubTaskExpected => '预计到货任务中心';

  @override
  String get warehouseHubTaskExpectedSub => '登记实际到货';

  @override
  String get warehouseHubTaskException => '到货异常任务中心';

  @override
  String get warehouseHubTaskExceptionSub => '超量先隔离';

  @override
  String get warehouseHubTaskPicking => '生产领料任务中心';

  @override
  String get warehouseHubTaskPickingSub => '备料·跟踪领取';

  @override
  String get warehouseHubDocTransfer => '仓库调拨';

  @override
  String get warehouseHubDocTransferSub => '仓库间调拨';

  @override
  String get warehouseHubDocOtherIn => '其它入库';

  @override
  String get warehouseHubDocOtherInSub => '无单据入库';

  @override
  String get warehouseHubDocOtherOut => '其它出库';

  @override
  String get warehouseHubDocOtherOutSub => '无单据出库';

  @override
  String get warehouseHubDocDraw => '生产领料';

  @override
  String get warehouseHubDocDrawSub => '车间领料';

  @override
  String get warehouseHubDocWdraw => '生产退料';

  @override
  String get warehouseHubDocWdrawSub => '退回车间料';

  @override
  String get warehouseHubDocFinishedIn => '产成品进仓';

  @override
  String get warehouseHubDocFinishedInSub => '成品入库';

  @override
  String get warehouseHubDocFinishedOut => '产成品出仓';

  @override
  String get warehouseHubDocFinishedOutSub => '成品出库';

  @override
  String get warehouseHubDocCheck => '盘点';

  @override
  String get warehouseHubDocCheckSub => '盘点盈亏';

  @override
  String get warehouseHubInventoryLive => '即时库存';

  @override
  String get warehouseHubInventoryLiveSub => '实时可用库存';

  @override
  String get warehouseHubInventoryBalance => '库存查询';

  @override
  String get warehouseHubInventoryBalanceSub => '按货品查余额';

  @override
  String get warehouseHubInventoryMovement => '出入库流水';

  @override
  String get warehouseHubInventoryMovementSub => '进出流水明细';

  @override
  String get warehouseHubReportDetail => '仓库明细报表';

  @override
  String get warehouseHubReportSummary => '仓库汇总报表';

  @override
  String get basicDataHubTitle => '基础资料';

  @override
  String get basicDataHubGoods => '货品资料';

  @override
  String get basicDataHubGoodsSub => '物料分类树与货品主档';

  @override
  String get basicDataHubMould => '模具资料';

  @override
  String get basicDataHubMouldSub => '模具系列分类与主档';

  @override
  String get basicDataHubClient => '客户资料';

  @override
  String get basicDataHubClientSub => '客户分类与主档';

  @override
  String get basicDataHubSupplier => '供应商资料';

  @override
  String get basicDataHubSupplierSub => '供应商分类与主档';

  @override
  String get basicDataHubColor => '颜色资料';

  @override
  String get basicDataHubColorSub => '颜色主档';

  @override
  String get basicDataHubUnit => '基本单位';

  @override
  String get basicDataHubUnitSub => '计量单位主档';

  @override
  String get basicDataHubCurrency => '币种资料';

  @override
  String get basicDataHubCurrencySub => '币种·参考汇率';

  @override
  String get basicDataHubWarehouse => '仓库资料';

  @override
  String get basicDataHubWarehouseSub => '仓库主档';

  @override
  String get basicDataHubAccount => '账户资料';

  @override
  String get basicDataHubAccountSub => '账户·期初·余额';

  @override
  String get basicDataHubPaymentStyle => '收付款类别';

  @override
  String get basicDataHubPaymentStyleSub => '资产负债等六大类';

  @override
  String get basicDataHubSettlementMethod => '结算方式';

  @override
  String get basicDataHubSettlementMethodSub => '结账字典·账期口径';

  @override
  String get impersonationSwitchPerson => '切换人';

  @override
  String get impersonationEnterPasswordTitle => '确认切换人';

  @override
  String get impersonationEnterPasswordHint =>
      '为安全验证，请输入你的登录密码。通过后 15 分钟内可自由切换，无需重复输入。';

  @override
  String get impersonationPasswordLabel => '登录密码';

  @override
  String get impersonationConfirm => '确认';

  @override
  String get impersonationTargetPickerTitle => '选择要查看的员工';

  @override
  String get impersonationSearchHint => '搜索姓名 / 工号';

  @override
  String impersonationBannerTitle(String name) {
    return '正在以 $name 身份查看(只读)';
  }

  @override
  String get impersonationBannerSwitch => '切换';

  @override
  String get impersonationBannerExit => '退出模拟';

  @override
  String impersonationRemainingMinutes(int count) {
    return '剩余 $count 分钟';
  }

  @override
  String get impersonationWrongPassword => '密码错误';

  @override
  String get impersonationExited => '已退出模拟身份';

  @override
  String get impersonationWindowExpired => '模拟窗口已到期，已退出';

  @override
  String get impersonationRecent => '最近';

  @override
  String get impersonationNoTargets => '暂无可切换的员工';

  @override
  String get impersonationStartFailed => '切换失败';

  @override
  String get exportDialogTitle => '导出 Excel';

  @override
  String get exportPasswordOptionalHint =>
      '密码可不填。不填将下载普通 Excel；填写 1–128 位密码则加密文件。';

  @override
  String get exportPasswordOptionalLabel => '打开密码(可选，1–128 位)';

  @override
  String get exportPasswordConfirmLabel => '确认密码';

  @override
  String get exportPasswordTooLong => '密码不能超过 128 位';

  @override
  String get exportPasswordMismatch => '两次密码不一致';

  @override
  String get exportDownloadPlain => '直接下载';

  @override
  String get exportDownloadEncrypted => '加密下载';

  @override
  String get exportFailed => '导出失败，请稍后重试';

  @override
  String exportDownloadStarted(String name) {
    return '已开始下载 $name';
  }

  @override
  String exportDownloadSaved(String path) {
    return '已保存：$path';
  }

  @override
  String get profileLoadingMessage => '正在加载员工档案…';

  @override
  String get profileLoadFailed => '员工档案加载失败';

  @override
  String get profileUnboundTitle => '当前账号未绑定员工档案';

  @override
  String get profileUnboundDescription => '请联系管理员或人事完成账号与员工档案绑定。';

  @override
  String get profileSessionUnavailable => '当前未登录或会话不可用';

  @override
  String get profileValueNotProvided => '未填写';

  @override
  String get profileValueNotRegistered => '未登记';

  @override
  String get profileAlternatePhoneLabel => '备用手机号';

  @override
  String get profileContractSummaryTitle => '合同摘要';

  @override
  String get profileTabOrgContract => '组织与合同';

  @override
  String get profileTabContactVehicle => '联系与车辆';

  @override
  String get profileTabMyDocuments => '我的文件';

  @override
  String get profileEmploymentHistoryTitle => '任职记录';

  @override
  String get profileScopeNoticeTitle => '信息范围说明';

  @override
  String get profileCompensationBoundaryDescription =>
      '薪酬与银行信息不会在“我的”页展示；这是有意设置的隐私边界。本人月度收入请从工资条核对，其他问题请联系授权人事。';

  @override
  String get profileMissingEmergencyContact =>
      '尚未登记紧急联系人，请先联系人事登记；登记后可在这里申请修改。';

  @override
  String profileAlternatePhoneCount(int count) {
    return '已登记 $count 个备用号码';
  }

  @override
  String get profileVehiclesPhonesEmptyHint => '登记车辆与备用手机号，按车牌快速找到你';

  @override
  String get historyEventConfirm => '转正';

  @override
  String get accountProvisionPermissionDenied => '你没有开通账号权限，请联系账号支持人员处理';

  @override
  String get accountProvisionAlreadyExists => '该员工已有账号或账号未启用，不能重复开通';

  @override
  String get accountProvisionConfirmTitle => '开通账号确认';

  @override
  String get accountProvisionFailed => '开通账号失败，请稍后重试';

  @override
  String get accountProvisionInProgress => '开通中';

  @override
  String get accountStatusNotProvisioned => '未开通账号';

  @override
  String get accountStatusInactive => '账号未启用';

  @override
  String get pagePermissionAccountNotProvisionedTitle => '此人还未开通账号，暂不能设置权限';

  @override
  String get pagePermissionAccountNotProvisionedCanProvision =>
      '请先开通登录账号；一次性凭据确认保存后，将自动加载此人的权限详情。';

  @override
  String get pagePermissionAccountNotProvisionedNoAccess =>
      '请联系具备“账号支持”权限的人员开通登录账号。';

  @override
  String get employeePermissionSettingsTooltip => '设置员工权限';

  @override
  String get employeeAccountNotProvisionedTooltip => '该员工未开通账号';

  @override
  String get employeeResignedCannotProvision => '该员工已离职，不能开通登录账号';

  @override
  String get employeeAccountNotProvisionedContactSupport =>
      '该员工还未开通账号，请联系账号支持人员处理';
}
