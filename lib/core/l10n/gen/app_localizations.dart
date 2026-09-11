import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ko.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'gen/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('zh'),
    Locale('en'),
    Locale('ko'),
  ];

  /// 应用标题
  ///
  /// In zh, this message translates to:
  /// **'优腾·综合管理平台'**
  String get appTitle;

  /// 应用代号
  ///
  /// In zh, this message translates to:
  /// **'UTEN IMP'**
  String get appName;

  /// No description provided for @commonConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认'**
  String get commonConfirm;

  /// No description provided for @commonCancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get commonCancel;

  /// No description provided for @commonSave.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get commonSave;

  /// No description provided for @commonDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get commonDelete;

  /// No description provided for @commonEdit.
  ///
  /// In zh, this message translates to:
  /// **'编辑'**
  String get commonEdit;

  /// No description provided for @commonAdd.
  ///
  /// In zh, this message translates to:
  /// **'新增'**
  String get commonAdd;

  /// No description provided for @commonSearch.
  ///
  /// In zh, this message translates to:
  /// **'搜索'**
  String get commonSearch;

  /// No description provided for @commonRefresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新'**
  String get commonRefresh;

  /// No description provided for @commonRetry.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get commonRetry;

  /// No description provided for @connectionReconnecting.
  ///
  /// In zh, this message translates to:
  /// **'网络暂时不稳定，正在自动连接…'**
  String get connectionReconnecting;

  /// No description provided for @connectionDisconnected.
  ///
  /// In zh, this message translates to:
  /// **'暂时连不上服务器，系统会继续自动连接'**
  String get connectionDisconnected;

  /// No description provided for @connectionRestored.
  ///
  /// In zh, this message translates to:
  /// **'网络已恢复，可以继续使用'**
  String get connectionRestored;

  /// No description provided for @connectionRetryNow.
  ///
  /// In zh, this message translates to:
  /// **'立即重试'**
  String get connectionRetryNow;

  /// No description provided for @commonClose.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get commonClose;

  /// No description provided for @commonBack.
  ///
  /// In zh, this message translates to:
  /// **'返回'**
  String get commonBack;

  /// No description provided for @commonLoading.
  ///
  /// In zh, this message translates to:
  /// **'加载中…'**
  String get commonLoading;

  /// No description provided for @commonNoData.
  ///
  /// In zh, this message translates to:
  /// **'暂无数据'**
  String get commonNoData;

  /// No description provided for @commonError.
  ///
  /// In zh, this message translates to:
  /// **'出错了，请稍后重试'**
  String get commonError;

  /// No description provided for @commonSuccess.
  ///
  /// In zh, this message translates to:
  /// **'操作成功'**
  String get commonSuccess;

  /// No description provided for @commonFailed.
  ///
  /// In zh, this message translates to:
  /// **'操作失败'**
  String get commonFailed;

  /// No description provided for @commonMore.
  ///
  /// In zh, this message translates to:
  /// **'更多'**
  String get commonMore;

  /// No description provided for @commonViewAll.
  ///
  /// In zh, this message translates to:
  /// **'查看全部'**
  String get commonViewAll;

  /// No description provided for @commonAction.
  ///
  /// In zh, this message translates to:
  /// **'操作'**
  String get commonAction;

  /// No description provided for @loginAccountHint.
  ///
  /// In zh, this message translates to:
  /// **'请输入员工工号或手机号'**
  String get loginAccountHint;

  /// No description provided for @loginAccountRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入账号'**
  String get loginAccountRequired;

  /// No description provided for @loginPasswordHint.
  ///
  /// In zh, this message translates to:
  /// **'请输入密码'**
  String get loginPasswordHint;

  /// No description provided for @loginPasswordRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入密码'**
  String get loginPasswordRequired;

  /// No description provided for @loginForgotPassword.
  ///
  /// In zh, this message translates to:
  /// **'忘记密码？'**
  String get loginForgotPassword;

  /// No description provided for @loginButton.
  ///
  /// In zh, this message translates to:
  /// **'登 录'**
  String get loginButton;

  /// No description provided for @loginLoggingIn.
  ///
  /// In zh, this message translates to:
  /// **'登录中…'**
  String get loginLoggingIn;

  /// No description provided for @loginSuccess.
  ///
  /// In zh, this message translates to:
  /// **'登录成功'**
  String get loginSuccess;

  /// No description provided for @loginFailed.
  ///
  /// In zh, this message translates to:
  /// **'账号或密码错误'**
  String get loginFailed;

  /// No description provided for @loginServerRecoveryAction.
  ///
  /// In zh, this message translates to:
  /// **'恢复自动选择服务器'**
  String get loginServerRecoveryAction;

  /// No description provided for @loginServerRecoveryHint.
  ///
  /// In zh, this message translates to:
  /// **'登录异常或更换网络时使用；只会在此安装包内置的公司与云端地址之间自动选择。'**
  String get loginServerRecoveryHint;

  /// No description provided for @loginServerRecoverySuccess.
  ///
  /// In zh, this message translates to:
  /// **'已恢复自动选择，请重新登录'**
  String get loginServerRecoverySuccess;

  /// No description provided for @loginServerRecoveryFailed.
  ///
  /// In zh, this message translates to:
  /// **'服务器选择恢复失败，请稍后重试或联系管理员'**
  String get loginServerRecoveryFailed;

  /// No description provided for @loginFooter.
  ///
  /// In zh, this message translates to:
  /// **'© {year} 优腾 · 综合管理平台'**
  String loginFooter(int year);

  /// No description provided for @navDashboard.
  ///
  /// In zh, this message translates to:
  /// **'工作台'**
  String get navDashboard;

  /// No description provided for @navNotice.
  ///
  /// In zh, this message translates to:
  /// **'通知'**
  String get navNotice;

  /// No description provided for @navProfile.
  ///
  /// In zh, this message translates to:
  /// **'我的'**
  String get navProfile;

  /// No description provided for @navSettings.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get navSettings;

  /// No description provided for @dashboardWelcome.
  ///
  /// In zh, this message translates to:
  /// **'欢迎，{name}'**
  String dashboardWelcome(Object name);

  /// No description provided for @dashboardWelcomeSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'今天也要加油哦'**
  String get dashboardWelcomeSubtitle;

  /// No description provided for @dashboardTodayStats.
  ///
  /// In zh, this message translates to:
  /// **'今日概览'**
  String get dashboardTodayStats;

  /// No description provided for @dashboardQuickActions.
  ///
  /// In zh, this message translates to:
  /// **'快捷操作'**
  String get dashboardQuickActions;

  /// No description provided for @statTodayOutput.
  ///
  /// In zh, this message translates to:
  /// **'今日产量'**
  String get statTodayOutput;

  /// No description provided for @statOutputUnit.
  ///
  /// In zh, this message translates to:
  /// **'件'**
  String get statOutputUnit;

  /// No description provided for @statInventory.
  ///
  /// In zh, this message translates to:
  /// **'当前库存'**
  String get statInventory;

  /// No description provided for @statOnlineEmployees.
  ///
  /// In zh, this message translates to:
  /// **'在线员工'**
  String get statOnlineEmployees;

  /// No description provided for @statPendingTodos.
  ///
  /// In zh, this message translates to:
  /// **'待办事项'**
  String get statPendingTodos;

  /// No description provided for @statTrendUp.
  ///
  /// In zh, this message translates to:
  /// **'较昨日 +{percent}%'**
  String statTrendUp(Object percent);

  /// No description provided for @statTrendDown.
  ///
  /// In zh, this message translates to:
  /// **'较昨日 {percent}%'**
  String statTrendDown(Object percent);

  /// No description provided for @settingsTitle.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get settingsTitle;

  /// No description provided for @settingsSectionAppearance.
  ///
  /// In zh, this message translates to:
  /// **'外观'**
  String get settingsSectionAppearance;

  /// No description provided for @settingsThemeMode.
  ///
  /// In zh, this message translates to:
  /// **'主题模式'**
  String get settingsThemeMode;

  /// No description provided for @settingsThemeLight.
  ///
  /// In zh, this message translates to:
  /// **'浅色'**
  String get settingsThemeLight;

  /// No description provided for @settingsThemeDark.
  ///
  /// In zh, this message translates to:
  /// **'深色'**
  String get settingsThemeDark;

  /// No description provided for @settingsThemeSystem.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get settingsThemeSystem;

  /// No description provided for @settingsLanguage.
  ///
  /// In zh, this message translates to:
  /// **'语言'**
  String get settingsLanguage;

  /// No description provided for @settingsLanguageZh.
  ///
  /// In zh, this message translates to:
  /// **'简体中文'**
  String get settingsLanguageZh;

  /// No description provided for @settingsLanguageEn.
  ///
  /// In zh, this message translates to:
  /// **'English'**
  String get settingsLanguageEn;

  /// No description provided for @settingsFontSize.
  ///
  /// In zh, this message translates to:
  /// **'字号'**
  String get settingsFontSize;

  /// No description provided for @settingsFontSmall.
  ///
  /// In zh, this message translates to:
  /// **'小'**
  String get settingsFontSmall;

  /// No description provided for @settingsFontMedium.
  ///
  /// In zh, this message translates to:
  /// **'标准'**
  String get settingsFontMedium;

  /// No description provided for @settingsFontLarge.
  ///
  /// In zh, this message translates to:
  /// **'大'**
  String get settingsFontLarge;

  /// No description provided for @settingsFontXLarge.
  ///
  /// In zh, this message translates to:
  /// **'超大'**
  String get settingsFontXLarge;

  /// 字号第 5 档：超超大
  ///
  /// In zh, this message translates to:
  /// **'超超大'**
  String get settingsFontXXLarge;

  /// No description provided for @settingsSectionPerformance.
  ///
  /// In zh, this message translates to:
  /// **'性能'**
  String get settingsSectionPerformance;

  /// No description provided for @settingsPerformanceTier.
  ///
  /// In zh, this message translates to:
  /// **'性能模式'**
  String get settingsPerformanceTier;

  /// No description provided for @settingsPerformanceAuto.
  ///
  /// In zh, this message translates to:
  /// **'自动'**
  String get settingsPerformanceAuto;

  /// No description provided for @settingsPerformanceLite.
  ///
  /// In zh, this message translates to:
  /// **'省电'**
  String get settingsPerformanceLite;

  /// No description provided for @settingsPerformanceStandard.
  ///
  /// In zh, this message translates to:
  /// **'标准'**
  String get settingsPerformanceStandard;

  /// No description provided for @settingsPerformanceRich.
  ///
  /// In zh, this message translates to:
  /// **'极致'**
  String get settingsPerformanceRich;

  /// No description provided for @settingsPerformanceHint.
  ///
  /// In zh, this message translates to:
  /// **'性能差的设备建议选省电模式'**
  String get settingsPerformanceHint;

  /// No description provided for @settingsSectionAbout.
  ///
  /// In zh, this message translates to:
  /// **'关于'**
  String get settingsSectionAbout;

  /// No description provided for @settingsVersion.
  ///
  /// In zh, this message translates to:
  /// **'版本'**
  String get settingsVersion;

  /// No description provided for @settingsLogout.
  ///
  /// In zh, this message translates to:
  /// **'退出登录'**
  String get settingsLogout;

  /// No description provided for @settingsLogoutConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定要退出登录吗？'**
  String get settingsLogoutConfirm;

  /// No description provided for @profileTitle.
  ///
  /// In zh, this message translates to:
  /// **'我的'**
  String get profileTitle;

  /// No description provided for @profileEditProfile.
  ///
  /// In zh, this message translates to:
  /// **'编辑资料'**
  String get profileEditProfile;

  /// No description provided for @profileChangePassword.
  ///
  /// In zh, this message translates to:
  /// **'修改密码'**
  String get profileChangePassword;

  /// No description provided for @profileEmployeeCode.
  ///
  /// In zh, this message translates to:
  /// **'工号'**
  String get profileEmployeeCode;

  /// No description provided for @profileDepartment.
  ///
  /// In zh, this message translates to:
  /// **'部门'**
  String get profileDepartment;

  /// No description provided for @profilePosition.
  ///
  /// In zh, this message translates to:
  /// **'岗位'**
  String get profilePosition;

  /// No description provided for @entryStaff.
  ///
  /// In zh, this message translates to:
  /// **'内部人员登录'**
  String get entryStaff;

  /// No description provided for @entryVisitor.
  ///
  /// In zh, this message translates to:
  /// **'访客登录'**
  String get entryVisitor;

  /// No description provided for @visitorLoginTitle.
  ///
  /// In zh, this message translates to:
  /// **'访客登录'**
  String get visitorLoginTitle;

  /// No description provided for @visitorLoginSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'输入手机号获取验证码'**
  String get visitorLoginSubtitle;

  /// No description provided for @visitorPhoneLabel.
  ///
  /// In zh, this message translates to:
  /// **'手机号'**
  String get visitorPhoneLabel;

  /// No description provided for @visitorPhoneHint.
  ///
  /// In zh, this message translates to:
  /// **'请输入手机号'**
  String get visitorPhoneHint;

  /// No description provided for @visitorCodeLabel.
  ///
  /// In zh, this message translates to:
  /// **'验证码'**
  String get visitorCodeLabel;

  /// No description provided for @visitorCodeHint.
  ///
  /// In zh, this message translates to:
  /// **'请输入验证码'**
  String get visitorCodeHint;

  /// No description provided for @visitorCodeRequired.
  ///
  /// In zh, this message translates to:
  /// **'请输入验证码'**
  String get visitorCodeRequired;

  /// No description provided for @visitorGetCode.
  ///
  /// In zh, this message translates to:
  /// **'获取验证码'**
  String get visitorGetCode;

  /// No description provided for @visitorCodeCountdown.
  ///
  /// In zh, this message translates to:
  /// **'{seconds}s 后重发'**
  String visitorCodeCountdown(Object seconds);

  /// No description provided for @visitorLoginButton.
  ///
  /// In zh, this message translates to:
  /// **'登 录'**
  String get visitorLoginButton;

  /// No description provided for @visitorLoggingIn.
  ///
  /// In zh, this message translates to:
  /// **'登录中…'**
  String get visitorLoggingIn;

  /// No description provided for @visitorCodeSent.
  ///
  /// In zh, this message translates to:
  /// **'验证码已发送'**
  String get visitorCodeSent;

  /// No description provided for @visitorCodeSentDev.
  ///
  /// In zh, this message translates to:
  /// **'验证码：{code}(开发期)'**
  String visitorCodeSentDev(Object code);

  /// No description provided for @visitorIsEmployee.
  ///
  /// In zh, this message translates to:
  /// **'该手机号为优腾员工账号，请走员工通道登录'**
  String get visitorIsEmployee;

  /// No description provided for @visitorPhoneInvalid.
  ///
  /// In zh, this message translates to:
  /// **'请输入正确的手机号'**
  String get visitorPhoneInvalid;

  /// No description provided for @visitorHomeTitle.
  ///
  /// In zh, this message translates to:
  /// **'我的访客预约'**
  String get visitorHomeTitle;

  /// No description provided for @visitorSettingsTitle.
  ///
  /// In zh, this message translates to:
  /// **'访客设置'**
  String get visitorSettingsTitle;

  /// No description provided for @visitorSettingsTooltip.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get visitorSettingsTooltip;

  /// No description provided for @visitorApplyNew.
  ///
  /// In zh, this message translates to:
  /// **'预约来访'**
  String get visitorApplyNew;

  /// No description provided for @visitorFilterAll.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get visitorFilterAll;

  /// No description provided for @visitorFilterPending.
  ///
  /// In zh, this message translates to:
  /// **'申请中'**
  String get visitorFilterPending;

  /// No description provided for @visitorFilterApproved.
  ///
  /// In zh, this message translates to:
  /// **'已批准'**
  String get visitorFilterApproved;

  /// No description provided for @visitorFilterRejected.
  ///
  /// In zh, this message translates to:
  /// **'已拒绝'**
  String get visitorFilterRejected;

  /// No description provided for @visitorApplyTitle.
  ///
  /// In zh, this message translates to:
  /// **'来访预约'**
  String get visitorApplyTitle;

  /// No description provided for @visitorApplyName.
  ///
  /// In zh, this message translates to:
  /// **'姓名'**
  String get visitorApplyName;

  /// No description provided for @visitorApplyNameHint.
  ///
  /// In zh, this message translates to:
  /// **'请输入真实姓名'**
  String get visitorApplyNameHint;

  /// No description provided for @visitorApplyIdCard.
  ///
  /// In zh, this message translates to:
  /// **'身份证号'**
  String get visitorApplyIdCard;

  /// No description provided for @visitorApplyIdCardHint.
  ///
  /// In zh, this message translates to:
  /// **'选填'**
  String get visitorApplyIdCardHint;

  /// No description provided for @visitorApplyCompany.
  ///
  /// In zh, this message translates to:
  /// **'来访单位'**
  String get visitorApplyCompany;

  /// No description provided for @visitorApplyCompanyHint.
  ///
  /// In zh, this message translates to:
  /// **'选填'**
  String get visitorApplyCompanyHint;

  /// No description provided for @visitorApplyPurpose.
  ///
  /// In zh, this message translates to:
  /// **'来访事由'**
  String get visitorApplyPurpose;

  /// No description provided for @visitorApplyPurposeHint.
  ///
  /// In zh, this message translates to:
  /// **'请说明来访目的'**
  String get visitorApplyPurposeHint;

  /// No description provided for @visitorApplyVehicle.
  ///
  /// In zh, this message translates to:
  /// **'是否开车'**
  String get visitorApplyVehicle;

  /// No description provided for @visitorApplyPlate.
  ///
  /// In zh, this message translates to:
  /// **'车牌号'**
  String get visitorApplyPlate;

  /// No description provided for @visitorApplyPlateHint.
  ///
  /// In zh, this message translates to:
  /// **'请输入车牌号'**
  String get visitorApplyPlateHint;

  /// No description provided for @visitorApplyHost.
  ///
  /// In zh, this message translates to:
  /// **'接待人'**
  String get visitorApplyHost;

  /// No description provided for @visitorApplyHostHint.
  ///
  /// In zh, this message translates to:
  /// **'选择要拜访的同事'**
  String get visitorApplyHostHint;

  /// No description provided for @visitorApplyDept.
  ///
  /// In zh, this message translates to:
  /// **'接待部门'**
  String get visitorApplyDept;

  /// No description provided for @visitorApplyVisitTime.
  ///
  /// In zh, this message translates to:
  /// **'计划到访时间'**
  String get visitorApplyVisitTime;

  /// No description provided for @visitorApplySubmit.
  ///
  /// In zh, this message translates to:
  /// **'提交预约'**
  String get visitorApplySubmit;

  /// No description provided for @visitorApplySubmitting.
  ///
  /// In zh, this message translates to:
  /// **'提交中…'**
  String get visitorApplySubmitting;

  /// No description provided for @visitorApplyValidateName.
  ///
  /// In zh, this message translates to:
  /// **'请输入姓名'**
  String get visitorApplyValidateName;

  /// No description provided for @visitorApplyValidateIdCard.
  ///
  /// In zh, this message translates to:
  /// **'请输入正确的 18 位居民身份证号'**
  String get visitorApplyValidateIdCard;

  /// No description provided for @visitorApplyValidatePurpose.
  ///
  /// In zh, this message translates to:
  /// **'请填写来访事由'**
  String get visitorApplyValidatePurpose;

  /// No description provided for @visitorApplyValidateHost.
  ///
  /// In zh, this message translates to:
  /// **'请选择接待人'**
  String get visitorApplyValidateHost;

  /// No description provided for @visitorApplyValidateVisitTime.
  ///
  /// In zh, this message translates to:
  /// **'请选择到访时间'**
  String get visitorApplyValidateVisitTime;

  /// No description provided for @visitorApplyValidateVisitTimeFuture.
  ///
  /// In zh, this message translates to:
  /// **'到访时间需晚于当前时间'**
  String get visitorApplyValidateVisitTimeFuture;

  /// No description provided for @visitorApplyDuplicateTime.
  ///
  /// In zh, this message translates to:
  /// **'您已有相同时段的进行中预约，请换一个时间'**
  String get visitorApplyDuplicateTime;

  /// No description provided for @visitorApplySuccess.
  ///
  /// In zh, this message translates to:
  /// **'预约已提交，等待审批'**
  String get visitorApplySuccess;

  /// No description provided for @visitorStatusPending.
  ///
  /// In zh, this message translates to:
  /// **'申请中'**
  String get visitorStatusPending;

  /// No description provided for @visitorStatusHostReviewing.
  ///
  /// In zh, this message translates to:
  /// **'待接待人确认'**
  String get visitorStatusHostReviewing;

  /// No description provided for @visitorStatusApproved.
  ///
  /// In zh, this message translates to:
  /// **'已批准'**
  String get visitorStatusApproved;

  /// No description provided for @visitorStatusRejected.
  ///
  /// In zh, this message translates to:
  /// **'已拒绝'**
  String get visitorStatusRejected;

  /// No description provided for @visitorStatusCheckedIn.
  ///
  /// In zh, this message translates to:
  /// **'已签到'**
  String get visitorStatusCheckedIn;

  /// No description provided for @visitorStatusCancelled.
  ///
  /// In zh, this message translates to:
  /// **'已取消'**
  String get visitorStatusCancelled;

  /// No description provided for @visitorDetailTitle.
  ///
  /// In zh, this message translates to:
  /// **'预约详情'**
  String get visitorDetailTitle;

  /// No description provided for @visitorDetailHost.
  ///
  /// In zh, this message translates to:
  /// **'接待人'**
  String get visitorDetailHost;

  /// No description provided for @visitorDetailPurpose.
  ///
  /// In zh, this message translates to:
  /// **'来访事由'**
  String get visitorDetailPurpose;

  /// No description provided for @visitorDetailVisitTime.
  ///
  /// In zh, this message translates to:
  /// **'到访时间'**
  String get visitorDetailVisitTime;

  /// No description provided for @visitorDetailVehicle.
  ///
  /// In zh, this message translates to:
  /// **'车辆'**
  String get visitorDetailVehicle;

  /// No description provided for @visitorDetailAppliedAt.
  ///
  /// In zh, this message translates to:
  /// **'提交时间'**
  String get visitorDetailAppliedAt;

  /// No description provided for @visitorDetailApprovedAt.
  ///
  /// In zh, this message translates to:
  /// **'批准时间'**
  String get visitorDetailApprovedAt;

  /// No description provided for @visitorDetailRejectReason.
  ///
  /// In zh, this message translates to:
  /// **'拒绝原因'**
  String get visitorDetailRejectReason;

  /// No description provided for @visitorDetailQr.
  ///
  /// In zh, this message translates to:
  /// **'入厂凭证'**
  String get visitorDetailQr;

  /// No description provided for @visitorDetailQrHint.
  ///
  /// In zh, this message translates to:
  /// **'请向保安出示此二维码核验入厂'**
  String get visitorDetailQrHint;

  /// No description provided for @visitorDetailTimeline.
  ///
  /// In zh, this message translates to:
  /// **'审批轨迹'**
  String get visitorDetailTimeline;

  /// No description provided for @visitorLogout.
  ///
  /// In zh, this message translates to:
  /// **'退出访客'**
  String get visitorLogout;

  /// No description provided for @visitorApprovalTitle.
  ///
  /// In zh, this message translates to:
  /// **'访客审批'**
  String get visitorApprovalTitle;

  /// No description provided for @visitorApprovalPending.
  ///
  /// In zh, this message translates to:
  /// **'待审批'**
  String get visitorApprovalPending;

  /// No description provided for @visitorApprovalProcessed.
  ///
  /// In zh, this message translates to:
  /// **'已处理'**
  String get visitorApprovalProcessed;

  /// No description provided for @visitorApprovalApprove.
  ///
  /// In zh, this message translates to:
  /// **'批准'**
  String get visitorApprovalApprove;

  /// No description provided for @visitorApprovalReject.
  ///
  /// In zh, this message translates to:
  /// **'拒绝'**
  String get visitorApprovalReject;

  /// No description provided for @visitorApprovalForward.
  ///
  /// In zh, this message translates to:
  /// **'转接待人确认'**
  String get visitorApprovalForward;

  /// No description provided for @visitorApprovalRejectReason.
  ///
  /// In zh, this message translates to:
  /// **'拒绝原因'**
  String get visitorApprovalRejectReason;

  /// No description provided for @visitorApprovalRejectReasonHint.
  ///
  /// In zh, this message translates to:
  /// **'请填写拒绝原因(选填)'**
  String get visitorApprovalRejectReasonHint;

  /// No description provided for @visitorApprovalConfirmApprove.
  ///
  /// In zh, this message translates to:
  /// **'确认批准该访客来访？'**
  String get visitorApprovalConfirmApprove;

  /// No description provided for @visitorApprovalConfirmReject.
  ///
  /// In zh, this message translates to:
  /// **'确认拒绝该访客来访？'**
  String get visitorApprovalConfirmReject;

  /// No description provided for @visitorApprovalHostConfirmed.
  ///
  /// In zh, this message translates to:
  /// **'接待人已确认'**
  String get visitorApprovalHostConfirmed;

  /// No description provided for @visitorApprovalEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无待审批的访客'**
  String get visitorApprovalEmpty;

  /// No description provided for @myVisitorsTitle.
  ///
  /// In zh, this message translates to:
  /// **'我的访客'**
  String get myVisitorsTitle;

  /// No description provided for @myVisitorsEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无需要您确认的访客'**
  String get myVisitorsEmpty;

  /// No description provided for @myVisitorsConfirm.
  ///
  /// In zh, this message translates to:
  /// **'同意接待'**
  String get myVisitorsConfirm;

  /// No description provided for @myVisitorsReject.
  ///
  /// In zh, this message translates to:
  /// **'拒绝接待'**
  String get myVisitorsReject;

  /// No description provided for @myVisitorsConfirmHint.
  ///
  /// In zh, this message translates to:
  /// **'确认接待该访客？'**
  String get myVisitorsConfirmHint;

  /// No description provided for @securityTitle.
  ///
  /// In zh, this message translates to:
  /// **'访客核验'**
  String get securityTitle;

  /// No description provided for @securityScanHint.
  ///
  /// In zh, this message translates to:
  /// **'将访客二维码对准扫码框'**
  String get securityScanHint;

  /// No description provided for @securityScanManual.
  ///
  /// In zh, this message translates to:
  /// **'手动输入凭证'**
  String get securityScanManual;

  /// No description provided for @securityManualInputHint.
  ///
  /// In zh, this message translates to:
  /// **'粘贴或输入二维码内容'**
  String get securityManualInputHint;

  /// No description provided for @securityPasscodeHint.
  ///
  /// In zh, this message translates to:
  /// **'输入6位通行码'**
  String get securityPasscodeHint;

  /// No description provided for @visitorPasscodeLabel.
  ///
  /// In zh, this message translates to:
  /// **'通行码'**
  String get visitorPasscodeLabel;

  /// No description provided for @securityVerifying.
  ///
  /// In zh, this message translates to:
  /// **'核验中…'**
  String get securityVerifying;

  /// No description provided for @securityPass.
  ///
  /// In zh, this message translates to:
  /// **'允许通行'**
  String get securityPass;

  /// No description provided for @securityReject.
  ///
  /// In zh, this message translates to:
  /// **'禁止通行'**
  String get securityReject;

  /// No description provided for @securityReasonOk.
  ///
  /// In zh, this message translates to:
  /// **'凭证有效'**
  String get securityReasonOk;

  /// No description provided for @securityReasonInvalid.
  ///
  /// In zh, this message translates to:
  /// **'二维码无效'**
  String get securityReasonInvalid;

  /// No description provided for @securityReasonExpired.
  ///
  /// In zh, this message translates to:
  /// **'凭证已过期'**
  String get securityReasonExpired;

  /// No description provided for @securityReasonUsed.
  ///
  /// In zh, this message translates to:
  /// **'该凭证已使用'**
  String get securityReasonUsed;

  /// No description provided for @securityReasonRejected.
  ///
  /// In zh, this message translates to:
  /// **'该访客已被拒绝'**
  String get securityReasonRejected;

  /// No description provided for @securityCheckIn.
  ///
  /// In zh, this message translates to:
  /// **'确认签到'**
  String get securityCheckIn;

  /// No description provided for @securityCheckInDone.
  ///
  /// In zh, this message translates to:
  /// **'签到成功'**
  String get securityCheckInDone;

  /// No description provided for @securityVisitor.
  ///
  /// In zh, this message translates to:
  /// **'访客'**
  String get securityVisitor;

  /// No description provided for @securityPurpose.
  ///
  /// In zh, this message translates to:
  /// **'事由'**
  String get securityPurpose;

  /// No description provided for @securityHost.
  ///
  /// In zh, this message translates to:
  /// **'接待人'**
  String get securityHost;

  /// No description provided for @securityPlate.
  ///
  /// In zh, this message translates to:
  /// **'车牌'**
  String get securityPlate;

  /// No description provided for @securityVisitTime.
  ///
  /// In zh, this message translates to:
  /// **'到访时间'**
  String get securityVisitTime;

  /// No description provided for @navHrGroup.
  ///
  /// In zh, this message translates to:
  /// **'人事管理'**
  String get navHrGroup;

  /// No description provided for @navHrEmployees.
  ///
  /// In zh, this message translates to:
  /// **'员工档案'**
  String get navHrEmployees;

  /// No description provided for @navHrDepartments.
  ///
  /// In zh, this message translates to:
  /// **'部门管理'**
  String get navHrDepartments;

  /// No description provided for @navHrOnboarding.
  ///
  /// In zh, this message translates to:
  /// **'入职办理'**
  String get navHrOnboarding;

  /// No description provided for @navHrPayrollGenerate.
  ///
  /// In zh, this message translates to:
  /// **'工资条生成'**
  String get navHrPayrollGenerate;

  /// No description provided for @navHrNoticePublish.
  ///
  /// In zh, this message translates to:
  /// **'通知发布'**
  String get navHrNoticePublish;

  /// No description provided for @employeeTitle.
  ///
  /// In zh, this message translates to:
  /// **'员工档案'**
  String get employeeTitle;

  /// No description provided for @employeeFabOnboard.
  ///
  /// In zh, this message translates to:
  /// **'入职'**
  String get employeeFabOnboard;

  /// No description provided for @employeeSearchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索工号 / 姓名 / 车牌'**
  String get employeeSearchHint;

  /// No description provided for @employeeEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无员工'**
  String get employeeEmpty;

  /// No description provided for @employeeEmptyHint.
  ///
  /// In zh, this message translates to:
  /// **'点右下角「入职」添加新员工'**
  String get employeeEmptyHint;

  /// No description provided for @employeeLoadMore.
  ///
  /// In zh, this message translates to:
  /// **'加载更多'**
  String get employeeLoadMore;

  /// No description provided for @employeeDetailTitle.
  ///
  /// In zh, this message translates to:
  /// **'员工详情'**
  String get employeeDetailTitle;

  /// No description provided for @employeeDetailBasic.
  ///
  /// In zh, this message translates to:
  /// **'基本信息'**
  String get employeeDetailBasic;

  /// No description provided for @employeeDetailContact.
  ///
  /// In zh, this message translates to:
  /// **'联系与地址'**
  String get employeeDetailContact;

  /// No description provided for @employeeDetailOrg.
  ///
  /// In zh, this message translates to:
  /// **'组织与用工'**
  String get employeeDetailOrg;

  /// No description provided for @employeeDetailContract.
  ///
  /// In zh, this message translates to:
  /// **'合同 / 薪资(按权限可见)'**
  String get employeeDetailContract;

  /// No description provided for @employeeDetailEmergency.
  ///
  /// In zh, this message translates to:
  /// **'紧急联系人'**
  String get employeeDetailEmergency;

  /// No description provided for @employeeDetailHistory.
  ///
  /// In zh, this message translates to:
  /// **'任职轨迹'**
  String get employeeDetailHistory;

  /// No description provided for @employeeFieldCode.
  ///
  /// In zh, this message translates to:
  /// **'工号'**
  String get employeeFieldCode;

  /// No description provided for @employeeFieldName.
  ///
  /// In zh, this message translates to:
  /// **'姓名'**
  String get employeeFieldName;

  /// No description provided for @employeeFieldGender.
  ///
  /// In zh, this message translates to:
  /// **'性别'**
  String get employeeFieldGender;

  /// No description provided for @employeeFieldIdType.
  ///
  /// In zh, this message translates to:
  /// **'证件类型'**
  String get employeeFieldIdType;

  /// No description provided for @employeeFieldIdNumber.
  ///
  /// In zh, this message translates to:
  /// **'证件号码'**
  String get employeeFieldIdNumber;

  /// No description provided for @employeeFieldBirthDate.
  ///
  /// In zh, this message translates to:
  /// **'出生日期'**
  String get employeeFieldBirthDate;

  /// No description provided for @employeeFieldEthnicity.
  ///
  /// In zh, this message translates to:
  /// **'民族'**
  String get employeeFieldEthnicity;

  /// No description provided for @employeeFieldPoliticalStatus.
  ///
  /// In zh, this message translates to:
  /// **'政治面貌'**
  String get employeeFieldPoliticalStatus;

  /// No description provided for @employeeFieldMaritalStatus.
  ///
  /// In zh, this message translates to:
  /// **'婚姻状况'**
  String get employeeFieldMaritalStatus;

  /// No description provided for @employeeFieldPhone.
  ///
  /// In zh, this message translates to:
  /// **'手机号'**
  String get employeeFieldPhone;

  /// No description provided for @employeeFieldOfficePhone.
  ///
  /// In zh, this message translates to:
  /// **'办公电话'**
  String get employeeFieldOfficePhone;

  /// No description provided for @employeeFieldEmail.
  ///
  /// In zh, this message translates to:
  /// **'企业邮箱'**
  String get employeeFieldEmail;

  /// No description provided for @employeeFieldHujiAddress.
  ///
  /// In zh, this message translates to:
  /// **'户籍地址'**
  String get employeeFieldHujiAddress;

  /// No description provided for @employeeFieldResidenceAddress.
  ///
  /// In zh, this message translates to:
  /// **'现居住地'**
  String get employeeFieldResidenceAddress;

  /// No description provided for @employeeFieldDepartment.
  ///
  /// In zh, this message translates to:
  /// **'所属部门'**
  String get employeeFieldDepartment;

  /// No description provided for @employeeFieldPosition.
  ///
  /// In zh, this message translates to:
  /// **'岗位'**
  String get employeeFieldPosition;

  /// No description provided for @employeeFieldSupervisor.
  ///
  /// In zh, this message translates to:
  /// **'直属上级'**
  String get employeeFieldSupervisor;

  /// No description provided for @employeeFieldHireDate.
  ///
  /// In zh, this message translates to:
  /// **'入职日期'**
  String get employeeFieldHireDate;

  /// No description provided for @employeeFieldWorkYears.
  ///
  /// In zh, this message translates to:
  /// **'工龄'**
  String get employeeFieldWorkYears;

  /// No description provided for @employeeWorkYearsYandM.
  ///
  /// In zh, this message translates to:
  /// **'{years} 年 {months} 个月'**
  String employeeWorkYearsYandM(int years, int months);

  /// No description provided for @employeeWorkYearsMonths.
  ///
  /// In zh, this message translates to:
  /// **'{months} 个月'**
  String employeeWorkYearsMonths(int months);

  /// No description provided for @employeeWorkYearsUnderOneMonth.
  ///
  /// In zh, this message translates to:
  /// **'不足 1 个月'**
  String get employeeWorkYearsUnderOneMonth;

  /// No description provided for @employeeFieldConfirmedDate.
  ///
  /// In zh, this message translates to:
  /// **'转正日期'**
  String get employeeFieldConfirmedDate;

  /// No description provided for @employeeFieldStatus.
  ///
  /// In zh, this message translates to:
  /// **'工作状态'**
  String get employeeFieldStatus;

  /// No description provided for @employeeFieldEmploymentType.
  ///
  /// In zh, this message translates to:
  /// **'用工形式'**
  String get employeeFieldEmploymentType;

  /// No description provided for @employeeFieldWorkLocation.
  ///
  /// In zh, this message translates to:
  /// **'办公地点'**
  String get employeeFieldWorkLocation;

  /// No description provided for @employeeFieldSeatNo.
  ///
  /// In zh, this message translates to:
  /// **'工位号'**
  String get employeeFieldSeatNo;

  /// No description provided for @employeeFieldContractType.
  ///
  /// In zh, this message translates to:
  /// **'合同类型'**
  String get employeeFieldContractType;

  /// No description provided for @employeeFieldContractPeriod.
  ///
  /// In zh, this message translates to:
  /// **'合同起止'**
  String get employeeFieldContractPeriod;

  /// No description provided for @employeeFieldProbation.
  ///
  /// In zh, this message translates to:
  /// **'试用期'**
  String get employeeFieldProbation;

  /// No description provided for @employeeFieldRenewCount.
  ///
  /// In zh, this message translates to:
  /// **'续签次数'**
  String get employeeFieldRenewCount;

  /// No description provided for @employeeFieldBaseSalary.
  ///
  /// In zh, this message translates to:
  /// **'基本工资'**
  String get employeeFieldBaseSalary;

  /// No description provided for @employeeFieldPerfSalary.
  ///
  /// In zh, this message translates to:
  /// **'绩效/补贴'**
  String get employeeFieldPerfSalary;

  /// No description provided for @employeeFieldSocialBase.
  ///
  /// In zh, this message translates to:
  /// **'社保基数'**
  String get employeeFieldSocialBase;

  /// No description provided for @employeeFieldHousingBase.
  ///
  /// In zh, this message translates to:
  /// **'公积金基数'**
  String get employeeFieldHousingBase;

  /// No description provided for @employeeFieldBankBranch.
  ///
  /// In zh, this message translates to:
  /// **'开户银行'**
  String get employeeFieldBankBranch;

  /// No description provided for @employeeFieldBankAccount.
  ///
  /// In zh, this message translates to:
  /// **'银行卡号'**
  String get employeeFieldBankAccount;

  /// No description provided for @employeeContractPeriodValue.
  ///
  /// In zh, this message translates to:
  /// **'{start} ~ {end}'**
  String employeeContractPeriodValue(Object end, Object start);

  /// No description provided for @employeeProbationValue.
  ///
  /// In zh, this message translates to:
  /// **'{months} 个月(至 {end})'**
  String employeeProbationValue(Object end, Object months);

  /// No description provided for @employeeRenewCountValue.
  ///
  /// In zh, this message translates to:
  /// **'{count}'**
  String employeeRenewCountValue(Object count);

  /// No description provided for @employeeFieldAccountStatus.
  ///
  /// In zh, this message translates to:
  /// **'登录账号'**
  String get employeeFieldAccountStatus;

  /// No description provided for @accountStatusActive.
  ///
  /// In zh, this message translates to:
  /// **'正常'**
  String get accountStatusActive;

  /// No description provided for @accountStatusLocked.
  ///
  /// In zh, this message translates to:
  /// **'已锁定'**
  String get accountStatusLocked;

  /// No description provided for @accountStatusDisabled.
  ///
  /// In zh, this message translates to:
  /// **'已停用'**
  String get accountStatusDisabled;

  /// No description provided for @accountStatusNone.
  ///
  /// In zh, this message translates to:
  /// **'未开通'**
  String get accountStatusNone;

  /// No description provided for @employeeProbationExpiring.
  ///
  /// In zh, this message translates to:
  /// **'试用期将于 {date} 到期(剩 {days} 天)，请及时办理转正'**
  String employeeProbationExpiring(Object date, Object days);

  /// No description provided for @employeeProbationExpired.
  ///
  /// In zh, this message translates to:
  /// **'试用期已于 {date} 到期，请尽快办理转正或离职'**
  String employeeProbationExpired(Object date);

  /// No description provided for @employeeContractExpiring.
  ///
  /// In zh, this message translates to:
  /// **'劳动合同将于 {date} 到期(剩 {days} 天)，请及时续签'**
  String employeeContractExpiring(Object date, Object days);

  /// No description provided for @employeeContractExpired.
  ///
  /// In zh, this message translates to:
  /// **'劳动合同已于 {date} 到期，请尽快处理'**
  String employeeContractExpired(Object date);

  /// No description provided for @employeeEditTitle.
  ///
  /// In zh, this message translates to:
  /// **'编辑员工'**
  String get employeeEditTitle;

  /// No description provided for @employeeEditBasic.
  ///
  /// In zh, this message translates to:
  /// **'基本信息'**
  String get employeeEditBasic;

  /// No description provided for @employeeEditOrg.
  ///
  /// In zh, this message translates to:
  /// **'组织信息'**
  String get employeeEditOrg;

  /// No description provided for @employeeEditContact.
  ///
  /// In zh, this message translates to:
  /// **'联系方式'**
  String get employeeEditContact;

  /// No description provided for @employeeEditSalary.
  ///
  /// In zh, this message translates to:
  /// **'薪资与银行'**
  String get employeeEditSalary;

  /// No description provided for @employeeEditFieldPhone.
  ///
  /// In zh, this message translates to:
  /// **'手机'**
  String get employeeEditFieldPhone;

  /// No description provided for @employeeEditFieldDepartment.
  ///
  /// In zh, this message translates to:
  /// **'部门'**
  String get employeeEditFieldDepartment;

  /// No description provided for @employeeEditFieldPosition.
  ///
  /// In zh, this message translates to:
  /// **'岗位'**
  String get employeeEditFieldPosition;

  /// No description provided for @employeeEditFieldEmploymentType.
  ///
  /// In zh, this message translates to:
  /// **'用工性质'**
  String get employeeEditFieldEmploymentType;

  /// No description provided for @employeeEditFieldStatus.
  ///
  /// In zh, this message translates to:
  /// **'员工状态'**
  String get employeeEditFieldStatus;

  /// No description provided for @employeeEditSaved.
  ///
  /// In zh, this message translates to:
  /// **'已保存'**
  String get employeeEditSaved;

  /// No description provided for @employeeEditSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'保存失败，请重试'**
  String get employeeEditSaveFailed;

  /// No description provided for @employeeEditLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载失败：{error}'**
  String employeeEditLoadFailed(Object error);

  /// No description provided for @employeeEditNotFound.
  ///
  /// In zh, this message translates to:
  /// **'员工不存在'**
  String get employeeEditNotFound;

  /// No description provided for @employeeEditRequired.
  ///
  /// In zh, this message translates to:
  /// **'必填'**
  String get employeeEditRequired;

  /// No description provided for @employeeOnboardTitle.
  ///
  /// In zh, this message translates to:
  /// **'新员工入职'**
  String get employeeOnboardTitle;

  /// No description provided for @employeeOnboardGroupProfile.
  ///
  /// In zh, this message translates to:
  /// **'档案'**
  String get employeeOnboardGroupProfile;

  /// No description provided for @employeeOnboardGroupOrg.
  ///
  /// In zh, this message translates to:
  /// **'组织'**
  String get employeeOnboardGroupOrg;

  /// No description provided for @employeeOnboardGroupPay.
  ///
  /// In zh, this message translates to:
  /// **'薪资 / 银行(可选，仅 HR/管理员可见)'**
  String get employeeOnboardGroupPay;

  /// No description provided for @employeeOnboardSubmit.
  ///
  /// In zh, this message translates to:
  /// **'提交入职'**
  String get employeeOnboardSubmit;

  /// No description provided for @employeeOnboardSuccess.
  ///
  /// In zh, this message translates to:
  /// **'入职成功，一次性临时密码已交付'**
  String get employeeOnboardSuccess;

  /// No description provided for @employeeOnboardSubmitFailed.
  ///
  /// In zh, this message translates to:
  /// **'提交失败，请重试'**
  String get employeeOnboardSubmitFailed;

  /// No description provided for @employeeOnboardNote.
  ///
  /// In zh, this message translates to:
  /// **'提交后将自动生成工号(UT 前缀)、以手机号作为登录账号，并生成一次性临时密码(身份证后 6 位)；首次登录必须修改密码。'**
  String get employeeOnboardNote;

  /// No description provided for @employeeOnboardCodeAutoNote.
  ///
  /// In zh, this message translates to:
  /// **'工号提交后自动生成(UT 前缀，唯一递增)'**
  String get employeeOnboardCodeAutoNote;

  /// No description provided for @positionPickerTitle.
  ///
  /// In zh, this message translates to:
  /// **'选择或填写岗位'**
  String get positionPickerTitle;

  /// No description provided for @positionPickerHint.
  ///
  /// In zh, this message translates to:
  /// **'请选择或填写岗位'**
  String get positionPickerHint;

  /// No description provided for @positionPickerDepartmentFirst.
  ///
  /// In zh, this message translates to:
  /// **'请先选择部门'**
  String get positionPickerDepartmentFirst;

  /// No description provided for @positionPickerSearchHint.
  ///
  /// In zh, this message translates to:
  /// **'输入岗位名称、编码或职级'**
  String get positionPickerSearchHint;

  /// No description provided for @positionPickerUseCustom.
  ///
  /// In zh, this message translates to:
  /// **'使用“{name}”作为新岗位'**
  String positionPickerUseCustom(Object name);

  /// No description provided for @positionPickerCustomDescription.
  ///
  /// In zh, this message translates to:
  /// **'确认后将按当前部门保存'**
  String get positionPickerCustomDescription;

  /// No description provided for @positionPickerNoPositions.
  ///
  /// In zh, this message translates to:
  /// **'该部门暂无岗位，可直接填写新岗位'**
  String get positionPickerNoPositions;

  /// No description provided for @positionPickerLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'岗位加载失败，可重试或直接填写新岗位'**
  String get positionPickerLoadFailed;

  /// No description provided for @positionPickerClear.
  ///
  /// In zh, this message translates to:
  /// **'清空'**
  String get positionPickerClear;

  /// No description provided for @employeeOnboardCredentialTitle.
  ///
  /// In zh, this message translates to:
  /// **'账号已创建'**
  String get employeeOnboardCredentialTitle;

  /// No description provided for @employeeOnboardCredentialWarning.
  ///
  /// In zh, this message translates to:
  /// **'临时密码只显示这一次。请立即通过安全方式交给员工；关闭后系统不会再次显示或保存明文。'**
  String get employeeOnboardCredentialWarning;

  /// No description provided for @employeeOnboardAccountLabel.
  ///
  /// In zh, this message translates to:
  /// **'登录账号'**
  String get employeeOnboardAccountLabel;

  /// No description provided for @employeeOnboardTemporaryPasswordLabel.
  ///
  /// In zh, this message translates to:
  /// **'一次性临时密码'**
  String get employeeOnboardTemporaryPasswordLabel;

  /// No description provided for @employeeOnboardCopyTemporaryPassword.
  ///
  /// In zh, this message translates to:
  /// **'复制密码'**
  String get employeeOnboardCopyTemporaryPassword;

  /// No description provided for @employeeOnboardTemporaryPasswordCopied.
  ///
  /// In zh, this message translates to:
  /// **'临时密码已复制'**
  String get employeeOnboardTemporaryPasswordCopied;

  /// No description provided for @employeeOnboardCredentialSaved.
  ///
  /// In zh, this message translates to:
  /// **'我已妥善保存'**
  String get employeeOnboardCredentialSaved;

  /// No description provided for @employeeOnboardHintName.
  ///
  /// In zh, this message translates to:
  /// **'张三'**
  String get employeeOnboardHintName;

  /// No description provided for @employeeOnboardHintIdNumber.
  ///
  /// In zh, this message translates to:
  /// **'请输入身份证号'**
  String get employeeOnboardHintIdNumber;

  /// No description provided for @employeeOnboardIdNumberInvalid.
  ///
  /// In zh, this message translates to:
  /// **'身份证号格式不正确'**
  String get employeeOnboardIdNumberInvalid;

  /// No description provided for @employeeOnboardHintPhone.
  ///
  /// In zh, this message translates to:
  /// **'11 位手机号'**
  String get employeeOnboardHintPhone;

  /// No description provided for @employeeOnboardPhoneRequired.
  ///
  /// In zh, this message translates to:
  /// **'手机号不能为空'**
  String get employeeOnboardPhoneRequired;

  /// No description provided for @employeeOnboardPhoneInvalid.
  ///
  /// In zh, this message translates to:
  /// **'手机号格式不正确'**
  String get employeeOnboardPhoneInvalid;

  /// No description provided for @employeeOnboardEmailOptional.
  ///
  /// In zh, this message translates to:
  /// **'可选'**
  String get employeeOnboardEmailOptional;

  /// No description provided for @employeeOnboardHireDateHint.
  ///
  /// In zh, this message translates to:
  /// **'yyyy-MM-dd'**
  String get employeeOnboardHireDateHint;

  /// No description provided for @employeeOnboardPickHireDate.
  ///
  /// In zh, this message translates to:
  /// **'请选择入职日期'**
  String get employeeOnboardPickHireDate;

  /// No description provided for @employeeOnboardPickDepartment.
  ///
  /// In zh, this message translates to:
  /// **'请选择部门'**
  String get employeeOnboardPickDepartment;

  /// No description provided for @employeeOnboardFieldRequired.
  ///
  /// In zh, this message translates to:
  /// **'{field}不能为空'**
  String employeeOnboardFieldRequired(Object field);

  /// No description provided for @employeeOnboardLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载失败'**
  String get employeeOnboardLoadFailed;

  /// No description provided for @idTypeIdCard.
  ///
  /// In zh, this message translates to:
  /// **'身份证'**
  String get idTypeIdCard;

  /// No description provided for @idTypePassport.
  ///
  /// In zh, this message translates to:
  /// **'护照'**
  String get idTypePassport;

  /// No description provided for @idTypeHmtPermit.
  ///
  /// In zh, this message translates to:
  /// **'港澳台通行证'**
  String get idTypeHmtPermit;

  /// No description provided for @idTypeOther.
  ///
  /// In zh, this message translates to:
  /// **'其他'**
  String get idTypeOther;

  /// No description provided for @employeeOffboardTitle.
  ///
  /// In zh, this message translates to:
  /// **'离职办理'**
  String get employeeOffboardTitle;

  /// No description provided for @employeeOffboardFieldType.
  ///
  /// In zh, this message translates to:
  /// **'离职类型'**
  String get employeeOffboardFieldType;

  /// No description provided for @employeeOffboardFieldDate.
  ///
  /// In zh, this message translates to:
  /// **'离职日期'**
  String get employeeOffboardFieldDate;

  /// No description provided for @employeeOffboardPickDate.
  ///
  /// In zh, this message translates to:
  /// **'选择日期'**
  String get employeeOffboardPickDate;

  /// No description provided for @employeeOffboardFieldReason.
  ///
  /// In zh, this message translates to:
  /// **'离职原因'**
  String get employeeOffboardFieldReason;

  /// No description provided for @employeeOffboardPickDateRequired.
  ///
  /// In zh, this message translates to:
  /// **'请选择离职日期'**
  String get employeeOffboardPickDateRequired;

  /// No description provided for @employeeOffboardChecksRequired.
  ///
  /// In zh, this message translates to:
  /// **'请确认所有回收项'**
  String get employeeOffboardChecksRequired;

  /// No description provided for @employeeOffboardConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认办理离职？'**
  String get employeeOffboardConfirmTitle;

  /// No description provided for @employeeOffboardConfirmBody.
  ///
  /// In zh, this message translates to:
  /// **'该员工账号将被停用。'**
  String get employeeOffboardConfirmBody;

  /// No description provided for @employeeOffboardConfirmAction.
  ///
  /// In zh, this message translates to:
  /// **'确认办理离职'**
  String get employeeOffboardConfirmAction;

  /// No description provided for @employeeOffboardNext.
  ///
  /// In zh, this message translates to:
  /// **'下一步'**
  String get employeeOffboardNext;

  /// No description provided for @employeeOffboardBack.
  ///
  /// In zh, this message translates to:
  /// **'上一步'**
  String get employeeOffboardBack;

  /// No description provided for @employeeOffboardCompleted.
  ///
  /// In zh, this message translates to:
  /// **'离职办理完成'**
  String get employeeOffboardCompleted;

  /// No description provided for @employeeOffboardLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载失败'**
  String get employeeOffboardLoadFailed;

  /// No description provided for @employeeActions.
  ///
  /// In zh, this message translates to:
  /// **'更多操作'**
  String get employeeActions;

  /// No description provided for @employeeActionTransfer.
  ///
  /// In zh, this message translates to:
  /// **'调岗'**
  String get employeeActionTransfer;

  /// No description provided for @employeeActionConfirm.
  ///
  /// In zh, this message translates to:
  /// **'转正'**
  String get employeeActionConfirm;

  /// No description provided for @employeeActionOffboard.
  ///
  /// In zh, this message translates to:
  /// **'办理离职'**
  String get employeeActionOffboard;

  /// No description provided for @employeeActionRehire.
  ///
  /// In zh, this message translates to:
  /// **'复职'**
  String get employeeActionRehire;

  /// No description provided for @employeeActionDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除档案'**
  String get employeeActionDelete;

  /// No description provided for @employeeActionProvision.
  ///
  /// In zh, this message translates to:
  /// **'开通登录账号'**
  String get employeeActionProvision;

  /// No description provided for @employeeActionLockAccount.
  ///
  /// In zh, this message translates to:
  /// **'锁定账号'**
  String get employeeActionLockAccount;

  /// No description provided for @employeeActionUnlockAccount.
  ///
  /// In zh, this message translates to:
  /// **'解锁账号'**
  String get employeeActionUnlockAccount;

  /// No description provided for @employeeLockAccountSuccess.
  ///
  /// In zh, this message translates to:
  /// **'账号已锁定'**
  String get employeeLockAccountSuccess;

  /// No description provided for @employeeUnlockAccountSuccess.
  ///
  /// In zh, this message translates to:
  /// **'账号已解锁'**
  String get employeeUnlockAccountSuccess;

  /// No description provided for @employeeProvisionConfirm.
  ///
  /// In zh, this message translates to:
  /// **'将为该员工开通登录账号：账号默认为手机号，初始密码为身份证号后6位，首次登录需修改。是否继续？'**
  String get employeeProvisionConfirm;

  /// No description provided for @employeeTransferTitle.
  ///
  /// In zh, this message translates to:
  /// **'员工调岗'**
  String get employeeTransferTitle;

  /// No description provided for @employeeTransferFieldDate.
  ///
  /// In zh, this message translates to:
  /// **'生效日期'**
  String get employeeTransferFieldDate;

  /// No description provided for @employeeTransferPickDate.
  ///
  /// In zh, this message translates to:
  /// **'选择日期'**
  String get employeeTransferPickDate;

  /// No description provided for @employeeTransferFieldRemark.
  ///
  /// In zh, this message translates to:
  /// **'备注'**
  String get employeeTransferFieldRemark;

  /// No description provided for @employeeTransferDateRequired.
  ///
  /// In zh, this message translates to:
  /// **'请选择生效日期'**
  String get employeeTransferDateRequired;

  /// No description provided for @employeeTransferSuccess.
  ///
  /// In zh, this message translates to:
  /// **'调岗完成'**
  String get employeeTransferSuccess;

  /// No description provided for @employeeConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认转正？'**
  String get employeeConfirmTitle;

  /// No description provided for @employeeConfirmBody.
  ///
  /// In zh, this message translates to:
  /// **'转正后员工状态将变为「在职」。'**
  String get employeeConfirmBody;

  /// No description provided for @employeeConfirmSuccess.
  ///
  /// In zh, this message translates to:
  /// **'转正完成'**
  String get employeeConfirmSuccess;

  /// No description provided for @employeeRehireTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认复职？'**
  String get employeeRehireTitle;

  /// No description provided for @employeeRehireBody.
  ///
  /// In zh, this message translates to:
  /// **'复职后员工状态将恢复为「在职」，其登录账号将重新启用(需重新登录)。'**
  String get employeeRehireBody;

  /// No description provided for @employeeRehireSuccess.
  ///
  /// In zh, this message translates to:
  /// **'复职完成'**
  String get employeeRehireSuccess;

  /// No description provided for @employeeDeleteTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认删除该员工档案？'**
  String get employeeDeleteTitle;

  /// No description provided for @employeeDeleteBody.
  ///
  /// In zh, this message translates to:
  /// **'删除后其登录账号将被停用，此操作不可恢复。'**
  String get employeeDeleteBody;

  /// No description provided for @employeeDeleteSuccess.
  ///
  /// In zh, this message translates to:
  /// **'员工档案已删除'**
  String get employeeDeleteSuccess;

  /// No description provided for @resignTypeVoluntary.
  ///
  /// In zh, this message translates to:
  /// **'主动辞职'**
  String get resignTypeVoluntary;

  /// No description provided for @resignTypeDismissed.
  ///
  /// In zh, this message translates to:
  /// **'公司辞退'**
  String get resignTypeDismissed;

  /// No description provided for @resignTypeContractEnd.
  ///
  /// In zh, this message translates to:
  /// **'合同到期'**
  String get resignTypeContractEnd;

  /// No description provided for @resignTypeRetire.
  ///
  /// In zh, this message translates to:
  /// **'退休'**
  String get resignTypeRetire;

  /// No description provided for @resignCheckAccess.
  ///
  /// In zh, this message translates to:
  /// **'收回门禁卡'**
  String get resignCheckAccess;

  /// No description provided for @resignCheckAssets.
  ///
  /// In zh, this message translates to:
  /// **'回收公司资产'**
  String get resignCheckAssets;

  /// No description provided for @resignCheckAccount.
  ///
  /// In zh, this message translates to:
  /// **'停用系统账号'**
  String get resignCheckAccount;

  /// No description provided for @resignCheckSocial.
  ///
  /// In zh, this message translates to:
  /// **'停缴社保公积金'**
  String get resignCheckSocial;

  /// No description provided for @employeeStatusActive.
  ///
  /// In zh, this message translates to:
  /// **'在职'**
  String get employeeStatusActive;

  /// No description provided for @employeeStatusProbation.
  ///
  /// In zh, this message translates to:
  /// **'试用'**
  String get employeeStatusProbation;

  /// No description provided for @employeeStatusOnLeave.
  ///
  /// In zh, this message translates to:
  /// **'休假'**
  String get employeeStatusOnLeave;

  /// No description provided for @employeeStatusResigned.
  ///
  /// In zh, this message translates to:
  /// **'离职'**
  String get employeeStatusResigned;

  /// No description provided for @employeeStatusUnknown.
  ///
  /// In zh, this message translates to:
  /// **'未知'**
  String get employeeStatusUnknown;

  /// No description provided for @genderMale.
  ///
  /// In zh, this message translates to:
  /// **'男'**
  String get genderMale;

  /// No description provided for @genderFemale.
  ///
  /// In zh, this message translates to:
  /// **'女'**
  String get genderFemale;

  /// No description provided for @employmentTypeRegular.
  ///
  /// In zh, this message translates to:
  /// **'正式'**
  String get employmentTypeRegular;

  /// No description provided for @employmentTypeDispatch.
  ///
  /// In zh, this message translates to:
  /// **'劳务派遣'**
  String get employmentTypeDispatch;

  /// No description provided for @employmentTypeIntern.
  ///
  /// In zh, this message translates to:
  /// **'实习'**
  String get employmentTypeIntern;

  /// No description provided for @employmentTypeOutsource.
  ///
  /// In zh, this message translates to:
  /// **'外包'**
  String get employmentTypeOutsource;

  /// No description provided for @contractTypeFixed.
  ///
  /// In zh, this message translates to:
  /// **'固定期限'**
  String get contractTypeFixed;

  /// No description provided for @contractTypeOpen.
  ///
  /// In zh, this message translates to:
  /// **'无固定期限'**
  String get contractTypeOpen;

  /// No description provided for @contractTypeTask.
  ///
  /// In zh, this message translates to:
  /// **'任务'**
  String get contractTypeTask;

  /// No description provided for @contractTypeIntern.
  ///
  /// In zh, this message translates to:
  /// **'实习'**
  String get contractTypeIntern;

  /// No description provided for @historyEventOnboard.
  ///
  /// In zh, this message translates to:
  /// **'入职'**
  String get historyEventOnboard;

  /// No description provided for @historyEventTransfer.
  ///
  /// In zh, this message translates to:
  /// **'调岗'**
  String get historyEventTransfer;

  /// No description provided for @historyEventResign.
  ///
  /// In zh, this message translates to:
  /// **'离职'**
  String get historyEventResign;

  /// No description provided for @historyEventRehire.
  ///
  /// In zh, this message translates to:
  /// **'复职'**
  String get historyEventRehire;

  /// No description provided for @departmentTitle.
  ///
  /// In zh, this message translates to:
  /// **'部门管理'**
  String get departmentTitle;

  /// No description provided for @departmentTreeTitle.
  ///
  /// In zh, this message translates to:
  /// **'组织架构'**
  String get departmentTreeTitle;

  /// No description provided for @departmentEmpty.
  ///
  /// In zh, this message translates to:
  /// **'选择部门'**
  String get departmentEmpty;

  /// No description provided for @departmentEmptyHint.
  ///
  /// In zh, this message translates to:
  /// **'点右上角图标打开部门树'**
  String get departmentEmptyHint;

  /// No description provided for @departmentEmptySelect.
  ///
  /// In zh, this message translates to:
  /// **'请选择左侧部门'**
  String get departmentEmptySelect;

  /// No description provided for @departmentTooltipAdd.
  ///
  /// In zh, this message translates to:
  /// **'新增部门'**
  String get departmentTooltipAdd;

  /// No description provided for @departmentTooltipRefresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新'**
  String get departmentTooltipRefresh;

  /// No description provided for @departmentTooltipTree.
  ///
  /// In zh, this message translates to:
  /// **'部门树'**
  String get departmentTooltipTree;

  /// No description provided for @departmentDialogAddTitle.
  ///
  /// In zh, this message translates to:
  /// **'新增部门'**
  String get departmentDialogAddTitle;

  /// No description provided for @departmentDialogDeleteTitle.
  ///
  /// In zh, this message translates to:
  /// **'删除部门'**
  String get departmentDialogDeleteTitle;

  /// No description provided for @departmentFieldCode.
  ///
  /// In zh, this message translates to:
  /// **'部门编码'**
  String get departmentFieldCode;

  /// No description provided for @departmentFieldCodeHint.
  ///
  /// In zh, this message translates to:
  /// **'如 DEPT-XX'**
  String get departmentFieldCodeHint;

  /// No description provided for @departmentFieldName.
  ///
  /// In zh, this message translates to:
  /// **'部门名称'**
  String get departmentFieldName;

  /// No description provided for @departmentFieldLevel.
  ///
  /// In zh, this message translates to:
  /// **'层级'**
  String get departmentFieldLevel;

  /// No description provided for @departmentCreate.
  ///
  /// In zh, this message translates to:
  /// **'创建'**
  String get departmentCreate;

  /// No description provided for @departmentDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get departmentDelete;

  /// No description provided for @departmentRequireCodeAndName.
  ///
  /// In zh, this message translates to:
  /// **'编码与名称必填'**
  String get departmentRequireCodeAndName;

  /// No description provided for @departmentCreated.
  ///
  /// In zh, this message translates to:
  /// **'已创建'**
  String get departmentCreated;

  /// No description provided for @departmentDeleted.
  ///
  /// In zh, this message translates to:
  /// **'已删除'**
  String get departmentDeleted;

  /// No description provided for @departmentDeleteConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认删除「{name}」？仅无子部门且无员工的叶子部门可删。'**
  String departmentDeleteConfirm(Object name);

  /// No description provided for @departmentLevelAndCode.
  ///
  /// In zh, this message translates to:
  /// **'{level} · 编码 {code}'**
  String departmentLevelAndCode(Object level, Object code);

  /// No description provided for @departmentStatEmployees.
  ///
  /// In zh, this message translates to:
  /// **'员工'**
  String get departmentStatEmployees;

  /// No description provided for @departmentStatChildren.
  ///
  /// In zh, this message translates to:
  /// **'子部门'**
  String get departmentStatChildren;

  /// No description provided for @departmentStatManager.
  ///
  /// In zh, this message translates to:
  /// **'负责人'**
  String get departmentStatManager;

  /// No description provided for @departmentStatParent.
  ///
  /// In zh, this message translates to:
  /// **'上级'**
  String get departmentStatParent;

  /// No description provided for @departmentEmployeesHeader.
  ///
  /// In zh, this message translates to:
  /// **'员工({count})'**
  String departmentEmployeesHeader(Object count);

  /// No description provided for @departmentEmployeesEmpty.
  ///
  /// In zh, this message translates to:
  /// **'该部门(含子部门)暂无员工'**
  String get departmentEmployeesEmpty;

  /// No description provided for @departmentStatValue.
  ///
  /// In zh, this message translates to:
  /// **'{label}：{value}'**
  String departmentStatValue(Object label, Object value);

  /// No description provided for @departmentLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载失败'**
  String get departmentLoadFailed;

  /// No description provided for @departmentLevelCompany.
  ///
  /// In zh, this message translates to:
  /// **'公司'**
  String get departmentLevelCompany;

  /// No description provided for @departmentLevelDecision.
  ///
  /// In zh, this message translates to:
  /// **'决策层'**
  String get departmentLevelDecision;

  /// No description provided for @departmentLevelManagement.
  ///
  /// In zh, this message translates to:
  /// **'管理中心'**
  String get departmentLevelManagement;

  /// No description provided for @departmentLevelPrimary.
  ///
  /// In zh, this message translates to:
  /// **'一级部门'**
  String get departmentLevelPrimary;

  /// No description provided for @departmentLevelSecondary.
  ///
  /// In zh, this message translates to:
  /// **'二级班组'**
  String get departmentLevelSecondary;

  /// No description provided for @departmentLevelTertiary.
  ///
  /// In zh, this message translates to:
  /// **'三级科室'**
  String get departmentLevelTertiary;

  /// No description provided for @payrollGenerateTitle.
  ///
  /// In zh, this message translates to:
  /// **'工资条生成'**
  String get payrollGenerateTitle;

  /// No description provided for @payrollStepScope.
  ///
  /// In zh, this message translates to:
  /// **'选择范围'**
  String get payrollStepScope;

  /// No description provided for @payrollStepItems.
  ///
  /// In zh, this message translates to:
  /// **'配置薪酬项'**
  String get payrollStepItems;

  /// No description provided for @payrollStepPreview.
  ///
  /// In zh, this message translates to:
  /// **'预览计算'**
  String get payrollStepPreview;

  /// No description provided for @payrollStepSubmit.
  ///
  /// In zh, this message translates to:
  /// **'提交审核'**
  String get payrollStepSubmit;

  /// No description provided for @payrollFieldMonth.
  ///
  /// In zh, this message translates to:
  /// **'工资月份'**
  String get payrollFieldMonth;

  /// No description provided for @payrollFieldScope.
  ///
  /// In zh, this message translates to:
  /// **'生成范围'**
  String get payrollFieldScope;

  /// No description provided for @payrollItemOvertime.
  ///
  /// In zh, this message translates to:
  /// **'加班费 (+15%)'**
  String get payrollItemOvertime;

  /// No description provided for @payrollItemBonus.
  ///
  /// In zh, this message translates to:
  /// **'绩效奖金 (+10%)'**
  String get payrollItemBonus;

  /// No description provided for @payrollItemSocial.
  ///
  /// In zh, this message translates to:
  /// **'社保公积金 (-10.5%)'**
  String get payrollItemSocial;

  /// No description provided for @payrollItemTax.
  ///
  /// In zh, this message translates to:
  /// **'个人所得税 (-5%)'**
  String get payrollItemTax;

  /// No description provided for @payrollSubmitNote.
  ///
  /// In zh, this message translates to:
  /// **'提交后将进入财务审核流程，审核通过后由人事发布给员工。'**
  String get payrollSubmitNote;

  /// No description provided for @payrollSubmitButton.
  ///
  /// In zh, this message translates to:
  /// **'提交审核'**
  String get payrollSubmitButton;

  /// No description provided for @payrollSubmitted.
  ///
  /// In zh, this message translates to:
  /// **'已提交审核，等待财务审核'**
  String get payrollSubmitted;

  /// No description provided for @payrollLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'加载失败：{error}'**
  String payrollLoadFailed(Object error);

  /// No description provided for @payrollEmptyPreview.
  ///
  /// In zh, this message translates to:
  /// **'该范围无可计算员工'**
  String get payrollEmptyPreview;

  /// No description provided for @payrollTableTotalLabel.
  ///
  /// In zh, this message translates to:
  /// **'合计'**
  String get payrollTableTotalLabel;

  /// No description provided for @payrollTableTotalValue.
  ///
  /// In zh, this message translates to:
  /// **'¥ {total} · {count} 人'**
  String payrollTableTotalValue(Object total, Object count);

  /// No description provided for @payrollTableHeaderName.
  ///
  /// In zh, this message translates to:
  /// **'工号/姓名'**
  String get payrollTableHeaderName;

  /// No description provided for @payrollTableHeaderNet.
  ///
  /// In zh, this message translates to:
  /// **'实发'**
  String get payrollTableHeaderNet;

  /// No description provided for @payrollTableRowName.
  ///
  /// In zh, this message translates to:
  /// **'{name}({code})'**
  String payrollTableRowName(Object name, Object code);

  /// No description provided for @payrollTableRowNet.
  ///
  /// In zh, this message translates to:
  /// **'¥ {net}'**
  String payrollTableRowNet(Object net);

  /// No description provided for @payrollNext.
  ///
  /// In zh, this message translates to:
  /// **'下一步'**
  String get payrollNext;

  /// No description provided for @payrollBack.
  ///
  /// In zh, this message translates to:
  /// **'上一步'**
  String get payrollBack;

  /// No description provided for @payrollDeptAll.
  ///
  /// In zh, this message translates to:
  /// **'全员'**
  String get payrollDeptAll;

  /// No description provided for @payrollDeptProduction.
  ///
  /// In zh, this message translates to:
  /// **'生产部'**
  String get payrollDeptProduction;

  /// No description provided for @payrollDeptQuality.
  ///
  /// In zh, this message translates to:
  /// **'质量部'**
  String get payrollDeptQuality;

  /// No description provided for @payrollDeptHr.
  ///
  /// In zh, this message translates to:
  /// **'人事部'**
  String get payrollDeptHr;

  /// No description provided for @payrollDeptFinance.
  ///
  /// In zh, this message translates to:
  /// **'财务部'**
  String get payrollDeptFinance;

  /// No description provided for @noticePublishTitle.
  ///
  /// In zh, this message translates to:
  /// **'发布通知'**
  String get noticePublishTitle;

  /// No description provided for @noticePublishSaveDraft.
  ///
  /// In zh, this message translates to:
  /// **'存草稿'**
  String get noticePublishSaveDraft;

  /// No description provided for @noticePublishDraftSaved.
  ///
  /// In zh, this message translates to:
  /// **'已保存草稿'**
  String get noticePublishDraftSaved;

  /// No description provided for @noticePublishPublishButton.
  ///
  /// In zh, this message translates to:
  /// **'发布'**
  String get noticePublishPublishButton;

  /// No description provided for @noticePublishTopPriority.
  ///
  /// In zh, this message translates to:
  /// **'置顶'**
  String get noticePublishTopPriority;

  /// No description provided for @noticePublishTitleHint.
  ///
  /// In zh, this message translates to:
  /// **'通知标题(必填)'**
  String get noticePublishTitleHint;

  /// No description provided for @noticePublishContentHint.
  ///
  /// In zh, this message translates to:
  /// **'通知正文……'**
  String get noticePublishContentHint;

  /// No description provided for @noticePublishScopeTitle.
  ///
  /// In zh, this message translates to:
  /// **'可见范围'**
  String get noticePublishScopeTitle;

  /// No description provided for @noticePublishScopeAll.
  ///
  /// In zh, this message translates to:
  /// **'全员'**
  String get noticePublishScopeAll;

  /// No description provided for @noticePublishScopeDept.
  ///
  /// In zh, this message translates to:
  /// **'按部门'**
  String get noticePublishScopeDept;

  /// No description provided for @noticePublishFieldDept.
  ///
  /// In zh, this message translates to:
  /// **'部门'**
  String get noticePublishFieldDept;

  /// No description provided for @noticePublishScopeAllHint.
  ///
  /// In zh, this message translates to:
  /// **'将通知到全公司所有员工'**
  String get noticePublishScopeAllHint;

  /// No description provided for @noticePublishScopeDeptHint.
  ///
  /// In zh, this message translates to:
  /// **'将通知到「{dept}」全体员工'**
  String noticePublishScopeDeptHint(Object dept);

  /// No description provided for @noticePublishValidateTitle.
  ///
  /// In zh, this message translates to:
  /// **'请填写标题'**
  String get noticePublishValidateTitle;

  /// No description provided for @noticePublishValidateContent.
  ///
  /// In zh, this message translates to:
  /// **'请填写正文'**
  String get noticePublishValidateContent;

  /// No description provided for @noticePublishConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认发布？'**
  String get noticePublishConfirmTitle;

  /// No description provided for @noticePublishConfirmBodyAll.
  ///
  /// In zh, this message translates to:
  /// **'将通知到全员'**
  String get noticePublishConfirmBodyAll;

  /// No description provided for @noticePublishConfirmBodyDept.
  ///
  /// In zh, this message translates to:
  /// **'将通知到「{dept}」'**
  String noticePublishConfirmBodyDept(Object dept);

  /// No description provided for @noticePublishPublished.
  ///
  /// In zh, this message translates to:
  /// **'通知已发布'**
  String get noticePublishPublished;

  /// No description provided for @noticePublishPublishing.
  ///
  /// In zh, this message translates to:
  /// **'发布中…'**
  String get noticePublishPublishing;

  /// No description provided for @noticePublishContentSection.
  ///
  /// In zh, this message translates to:
  /// **'通知内容'**
  String get noticePublishContentSection;

  /// No description provided for @noticePublishTypeLabel.
  ///
  /// In zh, this message translates to:
  /// **'通知类型'**
  String get noticePublishTypeLabel;

  /// No description provided for @noticePublishTitleLabel.
  ///
  /// In zh, this message translates to:
  /// **'标题'**
  String get noticePublishTitleLabel;

  /// No description provided for @noticePublishContentLabel.
  ///
  /// In zh, this message translates to:
  /// **'正文'**
  String get noticePublishContentLabel;

  /// No description provided for @noticePublishUrgentHint.
  ///
  /// In zh, this message translates to:
  /// **'紧急通知会使用高优先级提醒，请只用于必须立即关注的事项。'**
  String get noticePublishUrgentHint;

  /// No description provided for @noticePublishTopPriorityHint.
  ///
  /// In zh, this message translates to:
  /// **'置顶后会优先显示，并按重要通知提醒接收人。'**
  String get noticePublishTopPriorityHint;

  /// No description provided for @noticePublishScopeSelected.
  ///
  /// In zh, this message translates to:
  /// **'指定范围'**
  String get noticePublishScopeSelected;

  /// No description provided for @noticePublishScopeSelectedHint.
  ///
  /// In zh, this message translates to:
  /// **'部门与人员可以同时选择；部门包含其下级组织，重复接收人会自动去重。'**
  String get noticePublishScopeSelectedHint;

  /// No description provided for @noticePublishDepartmentsLabel.
  ///
  /// In zh, this message translates to:
  /// **'接收部门(可多选)'**
  String get noticePublishDepartmentsLabel;

  /// No description provided for @noticePublishDepartmentsHint.
  ///
  /// In zh, this message translates to:
  /// **'选择一个或多个部门'**
  String get noticePublishDepartmentsHint;

  /// No description provided for @noticePublishEmployeesLabel.
  ///
  /// In zh, this message translates to:
  /// **'单独添加人员'**
  String get noticePublishEmployeesLabel;

  /// No description provided for @noticePublishEmployeesHint.
  ///
  /// In zh, this message translates to:
  /// **'选择指定人员(可多选)'**
  String get noticePublishEmployeesHint;

  /// No description provided for @noticePublishEmployeePickerTitle.
  ///
  /// In zh, this message translates to:
  /// **'选择接收人员'**
  String get noticePublishEmployeePickerTitle;

  /// No description provided for @noticePublishEmployeeSearchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索姓名 / 工号'**
  String get noticePublishEmployeeSearchHint;

  /// No description provided for @noticePublishEmployeeEmpty.
  ///
  /// In zh, this message translates to:
  /// **'未找到可接收通知的在职账号'**
  String get noticePublishEmployeeEmpty;

  /// No description provided for @noticePublishEmployeeSelectedCount.
  ///
  /// In zh, this message translates to:
  /// **'已选 {count} 人'**
  String noticePublishEmployeeSelectedCount(int count);

  /// No description provided for @noticePublishEmployeeClear.
  ///
  /// In zh, this message translates to:
  /// **'清空'**
  String get noticePublishEmployeeClear;

  /// No description provided for @noticePublishEmployeeConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确定'**
  String get noticePublishEmployeeConfirm;

  /// No description provided for @noticePublishValidateAudience.
  ///
  /// In zh, this message translates to:
  /// **'请至少选择一个部门或人员'**
  String get noticePublishValidateAudience;

  /// No description provided for @noticePublishAudienceSummary.
  ///
  /// In zh, this message translates to:
  /// **'已选 {departmentCount} 个部门、{employeeCount} 人'**
  String noticePublishAudienceSummary(
    Object departmentCount,
    Object employeeCount,
  );

  /// No description provided for @noticePublishAudienceRecalculateHint.
  ///
  /// In zh, this message translates to:
  /// **'发布前会按当前组织与账号状态重新核算实际接收人数。'**
  String get noticePublishAudienceRecalculateHint;

  /// No description provided for @noticePublishConfirmAudience.
  ///
  /// In zh, this message translates to:
  /// **'将发送给 {summary}，实际接收 {count} 人。'**
  String noticePublishConfirmAudience(Object summary, Object count);

  /// No description provided for @noticePublishPublishedTo.
  ///
  /// In zh, this message translates to:
  /// **'通知已发布给 {count} 人'**
  String noticePublishPublishedTo(Object count);

  /// No description provided for @noticeTypeAnnouncement.
  ///
  /// In zh, this message translates to:
  /// **'公告'**
  String get noticeTypeAnnouncement;

  /// No description provided for @noticeTypePolicy.
  ///
  /// In zh, this message translates to:
  /// **'制度'**
  String get noticeTypePolicy;

  /// No description provided for @noticeTypeBenefit.
  ///
  /// In zh, this message translates to:
  /// **'福利'**
  String get noticeTypeBenefit;

  /// No description provided for @noticeTypeSystem.
  ///
  /// In zh, this message translates to:
  /// **'系统'**
  String get noticeTypeSystem;

  /// No description provided for @noticeTypeUrgent.
  ///
  /// In zh, this message translates to:
  /// **'紧急'**
  String get noticeTypeUrgent;

  /// No description provided for @noticeTypeBirthday.
  ///
  /// In zh, this message translates to:
  /// **'生日'**
  String get noticeTypeBirthday;

  /// No description provided for @noticeTypeAnniversary.
  ///
  /// In zh, this message translates to:
  /// **'入职周年'**
  String get noticeTypeAnniversary;

  /// No description provided for @noticeTypeWedding.
  ///
  /// In zh, this message translates to:
  /// **'新婚'**
  String get noticeTypeWedding;

  /// No description provided for @noticeTypeNewborn.
  ///
  /// In zh, this message translates to:
  /// **'新生儿'**
  String get noticeTypeNewborn;

  /// No description provided for @noticeTypeAnnouncementDesc.
  ///
  /// In zh, this message translates to:
  /// **'公司公告，全员可「点击收到」'**
  String get noticeTypeAnnouncementDesc;

  /// No description provided for @noticeTypePolicyDesc.
  ///
  /// In zh, this message translates to:
  /// **'制度发布，全员可「点击收到」'**
  String get noticeTypePolicyDesc;

  /// No description provided for @noticeTypeBenefitDesc.
  ///
  /// In zh, this message translates to:
  /// **'福利通知，全员可「点击收到」'**
  String get noticeTypeBenefitDesc;

  /// No description provided for @noticeTypeSystemDesc.
  ///
  /// In zh, this message translates to:
  /// **'系统通知，全员可「点击收到」'**
  String get noticeTypeSystemDesc;

  /// No description provided for @noticeTypeUrgentDesc.
  ///
  /// In zh, this message translates to:
  /// **'紧急通知，高优先级强提醒'**
  String get noticeTypeUrgentDesc;

  /// No description provided for @noticeTypeBirthdayDesc.
  ///
  /// In zh, this message translates to:
  /// **'为同事庆生，大家可「送上祝福」'**
  String get noticeTypeBirthdayDesc;

  /// No description provided for @noticeTypeAnniversaryDesc.
  ///
  /// In zh, this message translates to:
  /// **'入职周年纪念，大家可「送上祝福」'**
  String get noticeTypeAnniversaryDesc;

  /// No description provided for @noticeTypeWeddingDesc.
  ///
  /// In zh, this message translates to:
  /// **'新婚祝福，大家可「送上祝福」'**
  String get noticeTypeWeddingDesc;

  /// No description provided for @noticeTypeNewbornDesc.
  ///
  /// In zh, this message translates to:
  /// **'喜添新丁，大家可「送上祝福」'**
  String get noticeTypeNewbornDesc;

  /// No description provided for @noticeGroupBroadcast.
  ///
  /// In zh, this message translates to:
  /// **'公告广播'**
  String get noticeGroupBroadcast;

  /// No description provided for @noticeGroupCelebration.
  ///
  /// In zh, this message translates to:
  /// **'庆典祝福'**
  String get noticeGroupCelebration;

  /// No description provided for @noticeInteractionReceive.
  ///
  /// In zh, this message translates to:
  /// **'收到'**
  String get noticeInteractionReceive;

  /// No description provided for @noticeInteractionReceived.
  ///
  /// In zh, this message translates to:
  /// **'已收到'**
  String get noticeInteractionReceived;

  /// No description provided for @noticeClickToReceive.
  ///
  /// In zh, this message translates to:
  /// **'点击收到'**
  String get noticeClickToReceive;

  /// No description provided for @noticeAckCount.
  ///
  /// In zh, this message translates to:
  /// **'{count}人已收到'**
  String noticeAckCount(int count);

  /// No description provided for @noticeAckYouAndCount.
  ///
  /// In zh, this message translates to:
  /// **'你已收到 · 共 {count} 人收到'**
  String noticeAckYouAndCount(int count);

  /// No description provided for @noticeAckRecent.
  ///
  /// In zh, this message translates to:
  /// **'近期已收到'**
  String get noticeAckRecent;

  /// No description provided for @noticeSendBlessing.
  ///
  /// In zh, this message translates to:
  /// **'送上祝福'**
  String get noticeSendBlessing;

  /// No description provided for @noticeBlessingSent.
  ///
  /// In zh, this message translates to:
  /// **'已送祝福'**
  String get noticeBlessingSent;

  /// No description provided for @noticeBlessingCount.
  ///
  /// In zh, this message translates to:
  /// **'{count} 条祝福'**
  String noticeBlessingCount(int count);

  /// No description provided for @noticeBlessingWall.
  ///
  /// In zh, this message translates to:
  /// **'祝福墙'**
  String get noticeBlessingWall;

  /// No description provided for @noticeBlessingReceivedCount.
  ///
  /// In zh, this message translates to:
  /// **'收到 {count} 条祝福'**
  String noticeBlessingReceivedCount(int count);

  /// No description provided for @noticeBlessingWallEmpty.
  ///
  /// In zh, this message translates to:
  /// **'还没有祝福，送上第一份祝福吧'**
  String get noticeBlessingWallEmpty;

  /// No description provided for @noticeBlessingPlaceholder.
  ///
  /// In zh, this message translates to:
  /// **'写下你的祝福…'**
  String get noticeBlessingPlaceholder;

  /// No description provided for @noticeBlessingSendButton.
  ///
  /// In zh, this message translates to:
  /// **'发送祝福'**
  String get noticeBlessingSendButton;

  /// No description provided for @noticeBlessingSending.
  ///
  /// In zh, this message translates to:
  /// **'发送中…'**
  String get noticeBlessingSending;

  /// No description provided for @noticeBlessingWithdraw.
  ///
  /// In zh, this message translates to:
  /// **'撤回'**
  String get noticeBlessingWithdraw;

  /// No description provided for @noticeBlessingViewAll.
  ///
  /// In zh, this message translates to:
  /// **'查看全部 {count} 条'**
  String noticeBlessingViewAll(int count);

  /// No description provided for @noticeBlessingTemplatesTitle.
  ///
  /// In zh, this message translates to:
  /// **'选一句祝福'**
  String get noticeBlessingTemplatesTitle;

  /// No description provided for @noticeBlessingValidateEmpty.
  ///
  /// In zh, this message translates to:
  /// **'请输入祝福内容'**
  String get noticeBlessingValidateEmpty;

  /// No description provided for @noticeCelebrationSubjectLabel.
  ///
  /// In zh, this message translates to:
  /// **'祝福对象'**
  String get noticeCelebrationSubjectLabel;

  /// No description provided for @noticeCelebrationSubjectHint.
  ///
  /// In zh, this message translates to:
  /// **'选择要祝福的同事'**
  String get noticeCelebrationSubjectHint;

  /// No description provided for @noticeCelebrationSubjectRequired.
  ///
  /// In zh, this message translates to:
  /// **'请选择祝福对象'**
  String get noticeCelebrationSubjectRequired;

  /// No description provided for @noticeCelebrationSubjectIsYou.
  ///
  /// In zh, this message translates to:
  /// **'你'**
  String get noticeCelebrationSubjectIsYou;

  /// No description provided for @noticeCelebrationFor.
  ///
  /// In zh, this message translates to:
  /// **'祝 {name} {event}'**
  String noticeCelebrationFor(Object name, Object event);

  /// No description provided for @noticeQuickCelebrationTitle.
  ///
  /// In zh, this message translates to:
  /// **'快捷发布祝福'**
  String get noticeQuickCelebrationTitle;

  /// No description provided for @noticeQuickCelebrationSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'选择类型，系统自动套用模板'**
  String get noticeQuickCelebrationSubtitle;

  /// No description provided for @noticeQuickPublish.
  ///
  /// In zh, this message translates to:
  /// **'发通知'**
  String get noticeQuickPublish;

  /// No description provided for @noticeQuickBirthday.
  ///
  /// In zh, this message translates to:
  /// **'生日'**
  String get noticeQuickBirthday;

  /// No description provided for @noticeQuickAnniversary.
  ///
  /// In zh, this message translates to:
  /// **'入职周年'**
  String get noticeQuickAnniversary;

  /// No description provided for @noticeQuickWedding.
  ///
  /// In zh, this message translates to:
  /// **'新婚'**
  String get noticeQuickWedding;

  /// No description provided for @noticeQuickNewborn.
  ///
  /// In zh, this message translates to:
  /// **'新生儿'**
  String get noticeQuickNewborn;

  /// No description provided for @celebrationPopupBirthday.
  ///
  /// In zh, this message translates to:
  /// **'{name}，今天是你的生日！\n小优祝你生日快乐！'**
  String celebrationPopupBirthday(Object name);

  /// No description provided for @celebrationPopupAnniversary.
  ///
  /// In zh, this message translates to:
  /// **'{name}，今天是你的入职周年！\n小优祝你{label}！'**
  String celebrationPopupAnniversary(Object name, Object label);

  /// No description provided for @celebrationPopupWedding.
  ///
  /// In zh, this message translates to:
  /// **'{name}，新婚大喜！\n小优祝你们百年好合！'**
  String celebrationPopupWedding(Object name);

  /// No description provided for @celebrationPopupNewborn.
  ///
  /// In zh, this message translates to:
  /// **'{name}，恭喜喜添新丁！\n小优祝宝宝健康成长！'**
  String celebrationPopupNewborn(Object name);

  /// No description provided for @celebrationDismiss.
  ///
  /// In zh, this message translates to:
  /// **'谢谢小优'**
  String get celebrationDismiss;

  /// No description provided for @celebrationCardBirthday.
  ///
  /// In zh, this message translates to:
  /// **'今天是 {name} 的生日'**
  String celebrationCardBirthday(Object name);

  /// No description provided for @celebrationCardAnniversary.
  ///
  /// In zh, this message translates to:
  /// **'今天是 {name} 的{label}'**
  String celebrationCardAnniversary(Object name, Object label);

  /// No description provided for @celebrationCardWedding.
  ///
  /// In zh, this message translates to:
  /// **'今天是 {name} 的新婚大喜'**
  String celebrationCardWedding(Object name);

  /// No description provided for @celebrationCardNewborn.
  ///
  /// In zh, this message translates to:
  /// **'{name} 喜添新丁'**
  String celebrationCardNewborn(Object name);

  /// No description provided for @celebrationCardCta.
  ///
  /// In zh, this message translates to:
  /// **'送上祝福'**
  String get celebrationCardCta;

  /// No description provided for @celebrationCardWall.
  ///
  /// In zh, this message translates to:
  /// **'查看祝福墙'**
  String get celebrationCardWall;

  /// No description provided for @noticeAutoCelebrationTitle.
  ///
  /// In zh, this message translates to:
  /// **'自动祝福通知'**
  String get noticeAutoCelebrationTitle;

  /// No description provided for @noticeAutoCelebrationEnabled.
  ///
  /// In zh, this message translates to:
  /// **'每日自动为当天生日 / 入职周年的员工发布全员祝福'**
  String get noticeAutoCelebrationEnabled;

  /// No description provided for @noticeAutoCelebrationTypes.
  ///
  /// In zh, this message translates to:
  /// **'自动类型'**
  String get noticeAutoCelebrationTypes;

  /// No description provided for @noticeAutoCelebrationPublisher.
  ///
  /// In zh, this message translates to:
  /// **'发布人名称'**
  String get noticeAutoCelebrationPublisher;

  /// No description provided for @profileChangeEditTitle.
  ///
  /// In zh, this message translates to:
  /// **'修改个人信息'**
  String get profileChangeEditTitle;

  /// No description provided for @profileChangeEditCta.
  ///
  /// In zh, this message translates to:
  /// **'修改我的信息'**
  String get profileChangeEditCta;

  /// No description provided for @profileChangeEditHrOnlyHint.
  ///
  /// In zh, this message translates to:
  /// **'以下字段请联系人事修改'**
  String get profileChangeEditHrOnlyHint;

  /// No description provided for @profileChangeSectionBasic.
  ///
  /// In zh, this message translates to:
  /// **'基本信息(直改生效)'**
  String get profileChangeSectionBasic;

  /// No description provided for @profileChangeSectionReview.
  ///
  /// In zh, this message translates to:
  /// **'联系方式与重要字段(需 HR 审核)'**
  String get profileChangeSectionReview;

  /// No description provided for @profileChangeSectionIdentity.
  ///
  /// In zh, this message translates to:
  /// **'姓名与紧急联系人(需 HR 审核)'**
  String get profileChangeSectionIdentity;

  /// No description provided for @profileChangeFieldDirect.
  ///
  /// In zh, this message translates to:
  /// **'可直接修改'**
  String get profileChangeFieldDirect;

  /// No description provided for @profileChangeFieldReview.
  ///
  /// In zh, this message translates to:
  /// **'需 HR 审核后生效'**
  String get profileChangeFieldReview;

  /// No description provided for @profileChangeFieldHrOnly.
  ///
  /// In zh, this message translates to:
  /// **'请联系人事修改'**
  String get profileChangeFieldHrOnly;

  /// No description provided for @profileChangePasswordHint.
  ///
  /// In zh, this message translates to:
  /// **'为安全起见，请输入当前登录密码'**
  String get profileChangePasswordHint;

  /// No description provided for @profileChangePasswordLabel.
  ///
  /// In zh, this message translates to:
  /// **'当前密码'**
  String get profileChangePasswordLabel;

  /// No description provided for @profileChangePasswordWrong.
  ///
  /// In zh, this message translates to:
  /// **'密码错误，请重试'**
  String get profileChangePasswordWrong;

  /// No description provided for @profileChangeSubmitSuccess.
  ///
  /// In zh, this message translates to:
  /// **'修改已提交，HR 审核后生效'**
  String get profileChangeSubmitSuccess;

  /// No description provided for @profileChangeSubmitApplied.
  ///
  /// In zh, this message translates to:
  /// **'修改已保存'**
  String get profileChangeSubmitApplied;

  /// No description provided for @profileChangeSubmitFailed.
  ///
  /// In zh, this message translates to:
  /// **'提交失败，请稍后重试'**
  String get profileChangeSubmitFailed;

  /// No description provided for @profileChangeConflict.
  ///
  /// In zh, this message translates to:
  /// **'档案已被他人更新，请刷新后再试'**
  String get profileChangeConflict;

  /// No description provided for @profileChangeRateLimited.
  ///
  /// In zh, this message translates to:
  /// **'24h 内已提交过该字段的修改，请等待处理'**
  String get profileChangeRateLimited;

  /// No description provided for @profileChangeListTitle.
  ///
  /// In zh, this message translates to:
  /// **'我的修改申请'**
  String get profileChangeListTitle;

  /// No description provided for @profileChangeListCta.
  ///
  /// In zh, this message translates to:
  /// **'查看申请记录'**
  String get profileChangeListCta;

  /// No description provided for @profileChangeListEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无修改申请'**
  String get profileChangeListEmpty;

  /// No description provided for @profileChangeFilterAll.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get profileChangeFilterAll;

  /// No description provided for @profileChangeFilterPending.
  ///
  /// In zh, this message translates to:
  /// **'待审核'**
  String get profileChangeFilterPending;

  /// No description provided for @profileChangeFilterApplied.
  ///
  /// In zh, this message translates to:
  /// **'已生效'**
  String get profileChangeFilterApplied;

  /// No description provided for @profileChangeFilterApproved.
  ///
  /// In zh, this message translates to:
  /// **'已通过'**
  String get profileChangeFilterApproved;

  /// No description provided for @profileChangeFilterRejected.
  ///
  /// In zh, this message translates to:
  /// **'已驳回'**
  String get profileChangeFilterRejected;

  /// No description provided for @profileChangeFilterCancelled.
  ///
  /// In zh, this message translates to:
  /// **'已撤销'**
  String get profileChangeFilterCancelled;

  /// No description provided for @profileChangeStatusPending.
  ///
  /// In zh, this message translates to:
  /// **'待 HR 审核'**
  String get profileChangeStatusPending;

  /// No description provided for @profileChangeStatusApplied.
  ///
  /// In zh, this message translates to:
  /// **'已生效'**
  String get profileChangeStatusApplied;

  /// No description provided for @profileChangeStatusApproved.
  ///
  /// In zh, this message translates to:
  /// **'已通过'**
  String get profileChangeStatusApproved;

  /// No description provided for @profileChangeStatusRejected.
  ///
  /// In zh, this message translates to:
  /// **'已驳回'**
  String get profileChangeStatusRejected;

  /// No description provided for @profileChangeStatusCancelled.
  ///
  /// In zh, this message translates to:
  /// **'已撤销'**
  String get profileChangeStatusCancelled;

  /// No description provided for @profileChangeCancel.
  ///
  /// In zh, this message translates to:
  /// **'撤销'**
  String get profileChangeCancel;

  /// No description provided for @profileChangeCancelledByMe.
  ///
  /// In zh, this message translates to:
  /// **'已由我撤销'**
  String get profileChangeCancelledByMe;

  /// No description provided for @profileChangeFieldLabel.
  ///
  /// In zh, this message translates to:
  /// **'字段'**
  String get profileChangeFieldLabel;

  /// No description provided for @profileChangeBefore.
  ///
  /// In zh, this message translates to:
  /// **'修改前'**
  String get profileChangeBefore;

  /// No description provided for @profileChangeAfter.
  ///
  /// In zh, this message translates to:
  /// **'修改后'**
  String get profileChangeAfter;

  /// No description provided for @profileChangeSubmittedAt.
  ///
  /// In zh, this message translates to:
  /// **'提交时间'**
  String get profileChangeSubmittedAt;

  /// No description provided for @profileChangeReviewer.
  ///
  /// In zh, this message translates to:
  /// **'审核人'**
  String get profileChangeReviewer;

  /// No description provided for @profileChangeReviewComment.
  ///
  /// In zh, this message translates to:
  /// **'审核意见'**
  String get profileChangeReviewComment;

  /// No description provided for @profileChangeDiffTitle.
  ///
  /// In zh, this message translates to:
  /// **'本次修改'**
  String get profileChangeDiffTitle;

  /// No description provided for @profileChangeBatchItems.
  ///
  /// In zh, this message translates to:
  /// **'共 {count} 项'**
  String profileChangeBatchItems(Object count);

  /// No description provided for @profileChangeHrQueueTitle.
  ///
  /// In zh, this message translates to:
  /// **'员工修改审批'**
  String get profileChangeHrQueueTitle;

  /// No description provided for @profileChangeHrQueueEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无待审申请'**
  String get profileChangeHrQueueEmpty;

  /// No description provided for @profileChangeReviewApprove.
  ///
  /// In zh, this message translates to:
  /// **'批准'**
  String get profileChangeReviewApprove;

  /// No description provided for @profileChangeReviewReject.
  ///
  /// In zh, this message translates to:
  /// **'驳回'**
  String get profileChangeReviewReject;

  /// No description provided for @profileChangeRejectDialogTitle.
  ///
  /// In zh, this message translates to:
  /// **'驳回申请'**
  String get profileChangeRejectDialogTitle;

  /// No description provided for @profileChangeRejectReasonRequired.
  ///
  /// In zh, this message translates to:
  /// **'请填写驳回原因'**
  String get profileChangeRejectReasonRequired;

  /// No description provided for @profileChangeRejectReasonHint.
  ///
  /// In zh, this message translates to:
  /// **'请说明驳回原因，员工会看到'**
  String get profileChangeRejectReasonHint;

  /// No description provided for @profileChangeApproveDialogTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认批准？'**
  String get profileChangeApproveDialogTitle;

  /// No description provided for @profileChangeApproveDialogBody.
  ///
  /// In zh, this message translates to:
  /// **'批准后将立即合并到员工档案'**
  String get profileChangeApproveDialogBody;

  /// No description provided for @profileChangeConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认'**
  String get profileChangeConfirm;

  /// No description provided for @profileChangeCancel2.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get profileChangeCancel2;

  /// No description provided for @profileChangeRejectSuccess.
  ///
  /// In zh, this message translates to:
  /// **'已驳回'**
  String get profileChangeRejectSuccess;

  /// No description provided for @profileChangeApproveSuccess.
  ///
  /// In zh, this message translates to:
  /// **'已批准'**
  String get profileChangeApproveSuccess;

  /// No description provided for @profileChangeFieldPhone.
  ///
  /// In zh, this message translates to:
  /// **'手机'**
  String get profileChangeFieldPhone;

  /// No description provided for @profileChangeFieldFullName.
  ///
  /// In zh, this message translates to:
  /// **'姓名'**
  String get profileChangeFieldFullName;

  /// No description provided for @profileChangeFieldHujiAddress.
  ///
  /// In zh, this message translates to:
  /// **'户籍地址'**
  String get profileChangeFieldHujiAddress;

  /// No description provided for @profileChangeFieldEmergencyName.
  ///
  /// In zh, this message translates to:
  /// **'紧急联系人姓名'**
  String get profileChangeFieldEmergencyName;

  /// No description provided for @profileChangeFieldEmergencyPhone.
  ///
  /// In zh, this message translates to:
  /// **'紧急联系人电话'**
  String get profileChangeFieldEmergencyPhone;

  /// No description provided for @profileChangeFieldEmergencyRelationship.
  ///
  /// In zh, this message translates to:
  /// **'与本人关系'**
  String get profileChangeFieldEmergencyRelationship;

  /// No description provided for @profilePendingBadge.
  ///
  /// In zh, this message translates to:
  /// **'{count} 项待审'**
  String profilePendingBadge(Object count);

  /// No description provided for @profilePendingSectionTitle.
  ///
  /// In zh, this message translates to:
  /// **'待我审核的修改申请'**
  String get profilePendingSectionTitle;

  /// No description provided for @profilePendingSectionEmpty.
  ///
  /// In zh, this message translates to:
  /// **'该员工暂无待审申请'**
  String get profilePendingSectionEmpty;

  /// No description provided for @profilePendingSectionViewAll.
  ///
  /// In zh, this message translates to:
  /// **'全部 →'**
  String get profilePendingSectionViewAll;

  /// No description provided for @profileFieldPhoneMask.
  ///
  /// In zh, this message translates to:
  /// **'138****1234'**
  String get profileFieldPhoneMask;

  /// No description provided for @profileFieldIdCardMask.
  ///
  /// In zh, this message translates to:
  /// **'****'**
  String get profileFieldIdCardMask;

  /// No description provided for @profileFieldBankAccountMask.
  ///
  /// In zh, this message translates to:
  /// **'****1234'**
  String get profileFieldBankAccountMask;

  /// No description provided for @profileFieldGroupIdentity.
  ///
  /// In zh, this message translates to:
  /// **'身份信息'**
  String get profileFieldGroupIdentity;

  /// No description provided for @profileFieldGroupContact.
  ///
  /// In zh, this message translates to:
  /// **'联系方式'**
  String get profileFieldGroupContact;

  /// No description provided for @profileFieldGroupAddress.
  ///
  /// In zh, this message translates to:
  /// **'地址'**
  String get profileFieldGroupAddress;

  /// No description provided for @profileFieldGroupEmergency.
  ///
  /// In zh, this message translates to:
  /// **'紧急联系人'**
  String get profileFieldGroupEmergency;

  /// No description provided for @profileFieldGroupOrganization.
  ///
  /// In zh, this message translates to:
  /// **'组织信息'**
  String get profileFieldGroupOrganization;

  /// No description provided for @profileEditPolicyHint.
  ///
  /// In zh, this message translates to:
  /// **'绿色「可直接修改」提交后立即生效；黄色「需 HR 审核」由人事核对后生效；其余字段由人事统一维护。'**
  String get profileEditPolicyHint;

  /// No description provided for @profileEditPendingConflictHint.
  ///
  /// In zh, this message translates to:
  /// **'你有 {count} 条待审申请；相关字段在审核通过前再次修改，可能与在途申请冲突。'**
  String profileEditPendingConflictHint(int count);

  /// No description provided for @profileEditFieldAction.
  ///
  /// In zh, this message translates to:
  /// **'修改'**
  String get profileEditFieldAction;

  /// No description provided for @profileFieldGroupOrg.
  ///
  /// In zh, this message translates to:
  /// **'组织与入职'**
  String get profileFieldGroupOrg;

  /// No description provided for @profileFieldGroupCompensation.
  ///
  /// In zh, this message translates to:
  /// **'薪资与银行'**
  String get profileFieldGroupCompensation;

  /// No description provided for @profileFieldWorkLocation.
  ///
  /// In zh, this message translates to:
  /// **'工作地'**
  String get profileFieldWorkLocation;

  /// No description provided for @profileFieldSeatNo.
  ///
  /// In zh, this message translates to:
  /// **'工位'**
  String get profileFieldSeatNo;

  /// No description provided for @profileFieldOfficePhone.
  ///
  /// In zh, this message translates to:
  /// **'办公电话'**
  String get profileFieldOfficePhone;

  /// No description provided for @profileFieldMobile.
  ///
  /// In zh, this message translates to:
  /// **'手机号'**
  String get profileFieldMobile;

  /// No description provided for @profileFieldEmail.
  ///
  /// In zh, this message translates to:
  /// **'邮箱'**
  String get profileFieldEmail;

  /// No description provided for @profileFieldResidenceAddress.
  ///
  /// In zh, this message translates to:
  /// **'现住址'**
  String get profileFieldResidenceAddress;

  /// No description provided for @profileFieldHujiAddress.
  ///
  /// In zh, this message translates to:
  /// **'户籍地址'**
  String get profileFieldHujiAddress;

  /// No description provided for @profileFieldEthnicity.
  ///
  /// In zh, this message translates to:
  /// **'民族'**
  String get profileFieldEthnicity;

  /// No description provided for @profileFieldPoliticalStatus.
  ///
  /// In zh, this message translates to:
  /// **'政治面貌'**
  String get profileFieldPoliticalStatus;

  /// No description provided for @profileFieldMaritalStatus.
  ///
  /// In zh, this message translates to:
  /// **'婚姻状况'**
  String get profileFieldMaritalStatus;

  /// No description provided for @profileFieldBirthDate.
  ///
  /// In zh, this message translates to:
  /// **'出生日期'**
  String get profileFieldBirthDate;

  /// No description provided for @profileFieldGender.
  ///
  /// In zh, this message translates to:
  /// **'性别'**
  String get profileFieldGender;

  /// No description provided for @profileFieldIdType.
  ///
  /// In zh, this message translates to:
  /// **'证件类型'**
  String get profileFieldIdType;

  /// No description provided for @profileFieldIdNumber.
  ///
  /// In zh, this message translates to:
  /// **'身份证号'**
  String get profileFieldIdNumber;

  /// No description provided for @profileFieldSupervisor.
  ///
  /// In zh, this message translates to:
  /// **'直属主管'**
  String get profileFieldSupervisor;

  /// No description provided for @profileFieldHireDate.
  ///
  /// In zh, this message translates to:
  /// **'入职日期'**
  String get profileFieldHireDate;

  /// No description provided for @profileFieldConfirmedAt.
  ///
  /// In zh, this message translates to:
  /// **'转正日期'**
  String get profileFieldConfirmedAt;

  /// No description provided for @profileFieldEmploymentType.
  ///
  /// In zh, this message translates to:
  /// **'用工性质'**
  String get profileFieldEmploymentType;

  /// No description provided for @profileFieldAttendanceGroup.
  ///
  /// In zh, this message translates to:
  /// **'考勤组'**
  String get profileFieldAttendanceGroup;

  /// No description provided for @profileFieldPaperArchiveNo.
  ///
  /// In zh, this message translates to:
  /// **'纸质档案号'**
  String get profileFieldPaperArchiveNo;

  /// No description provided for @profileFieldBaseSalary.
  ///
  /// In zh, this message translates to:
  /// **'基本工资'**
  String get profileFieldBaseSalary;

  /// No description provided for @profileFieldPerfSalary.
  ///
  /// In zh, this message translates to:
  /// **'绩效工资'**
  String get profileFieldPerfSalary;

  /// No description provided for @profileFieldSocialInsuranceBase.
  ///
  /// In zh, this message translates to:
  /// **'社保基数'**
  String get profileFieldSocialInsuranceBase;

  /// No description provided for @profileFieldSocialInsuranceLocation.
  ///
  /// In zh, this message translates to:
  /// **'社保缴纳地'**
  String get profileFieldSocialInsuranceLocation;

  /// No description provided for @profileFieldHousingFundBase.
  ///
  /// In zh, this message translates to:
  /// **'公积金基数'**
  String get profileFieldHousingFundBase;

  /// No description provided for @profileFieldAllowanceStandard.
  ///
  /// In zh, this message translates to:
  /// **'补贴标准'**
  String get profileFieldAllowanceStandard;

  /// No description provided for @profileFieldBankBranch.
  ///
  /// In zh, this message translates to:
  /// **'开户行'**
  String get profileFieldBankBranch;

  /// No description provided for @profileFieldBankAccount.
  ///
  /// In zh, this message translates to:
  /// **'银行账号'**
  String get profileFieldBankAccount;

  /// No description provided for @profileFieldContractType.
  ///
  /// In zh, this message translates to:
  /// **'合同类型'**
  String get profileFieldContractType;

  /// No description provided for @profileFieldContractStart.
  ///
  /// In zh, this message translates to:
  /// **'合同起始'**
  String get profileFieldContractStart;

  /// No description provided for @profileFieldContractEnd.
  ///
  /// In zh, this message translates to:
  /// **'合同截止'**
  String get profileFieldContractEnd;

  /// No description provided for @profileFieldProbationMonths.
  ///
  /// In zh, this message translates to:
  /// **'试用期(月)'**
  String get profileFieldProbationMonths;

  /// No description provided for @profileFieldRenewCount.
  ///
  /// In zh, this message translates to:
  /// **'续签次数'**
  String get profileFieldRenewCount;

  /// 未启用单据卡片上的角标
  ///
  /// In zh, this message translates to:
  /// **'未启用'**
  String get hubDisabledChip;

  /// No description provided for @hubSectionTaskCenter.
  ///
  /// In zh, this message translates to:
  /// **'任务中心'**
  String get hubSectionTaskCenter;

  /// No description provided for @hubDisabledDocNotice.
  ///
  /// In zh, this message translates to:
  /// **'该单据类型暂未启用(老库无数据)'**
  String get hubDisabledDocNotice;

  /// 明细报表共享副标题：一行一货品
  ///
  /// In zh, this message translates to:
  /// **'一行一货品'**
  String get hubSubDetailPerItem;

  /// 汇总报表共享副标题：一行一整单
  ///
  /// In zh, this message translates to:
  /// **'一行一单'**
  String get hubSubSummaryPerDoc;

  /// No description provided for @hubSubPendingReturnQty.
  ///
  /// In zh, this message translates to:
  /// **'待入库的退货量'**
  String get hubSubPendingReturnQty;

  /// No description provided for @hubSubReadOnlyPlan.
  ///
  /// In zh, this message translates to:
  /// **'计划只读'**
  String get hubSubReadOnlyPlan;

  /// No description provided for @salesHubTitle.
  ///
  /// In zh, this message translates to:
  /// **'销售管理'**
  String get salesHubTitle;

  /// No description provided for @salesHubSectionReports.
  ///
  /// In zh, this message translates to:
  /// **'销售报表'**
  String get salesHubSectionReports;

  /// No description provided for @salesHubSectionScarcity.
  ///
  /// In zh, this message translates to:
  /// **'稀缺仲裁'**
  String get salesHubSectionScarcity;

  /// No description provided for @salesHubTaskOrderProgress.
  ///
  /// In zh, this message translates to:
  /// **'订单进度查询'**
  String get salesHubTaskOrderProgress;

  /// No description provided for @salesHubTaskOrderProgressSub.
  ///
  /// In zh, this message translates to:
  /// **'出货与完工进度'**
  String get salesHubTaskOrderProgressSub;

  /// No description provided for @salesHubDocQuote.
  ///
  /// In zh, this message translates to:
  /// **'销售报价单'**
  String get salesHubDocQuote;

  /// No description provided for @salesHubDocQuoteSub.
  ///
  /// In zh, this message translates to:
  /// **'报价·有效期'**
  String get salesHubDocQuoteSub;

  /// No description provided for @salesHubDocOrder.
  ///
  /// In zh, this message translates to:
  /// **'销售订货单'**
  String get salesHubDocOrder;

  /// No description provided for @salesHubDocOrderSub.
  ///
  /// In zh, this message translates to:
  /// **'客户下单'**
  String get salesHubDocOrderSub;

  /// No description provided for @salesHubDocShipment.
  ///
  /// In zh, this message translates to:
  /// **'销售出货单'**
  String get salesHubDocShipment;

  /// No description provided for @salesHubDocShipmentSub.
  ///
  /// In zh, this message translates to:
  /// **'发货·立应收'**
  String get salesHubDocShipmentSub;

  /// No description provided for @salesHubDocOtherShipment.
  ///
  /// In zh, this message translates to:
  /// **'其它出货单'**
  String get salesHubDocOtherShipment;

  /// No description provided for @salesHubDocOtherShipmentSub.
  ///
  /// In zh, this message translates to:
  /// **'直接出库'**
  String get salesHubDocOtherShipmentSub;

  /// No description provided for @salesHubDocReturn.
  ///
  /// In zh, this message translates to:
  /// **'销售退货单'**
  String get salesHubDocReturn;

  /// No description provided for @salesHubDocReturnSub.
  ///
  /// In zh, this message translates to:
  /// **'退货·红字应收'**
  String get salesHubDocReturnSub;

  /// No description provided for @salesHubReportDetail.
  ///
  /// In zh, this message translates to:
  /// **'销售明细报表'**
  String get salesHubReportDetail;

  /// No description provided for @salesHubReportSummary.
  ///
  /// In zh, this message translates to:
  /// **'销售汇总报表'**
  String get salesHubReportSummary;

  /// No description provided for @salesHubScarcity.
  ///
  /// In zh, this message translates to:
  /// **'稀缺库存让单'**
  String get salesHubScarcity;

  /// No description provided for @salesHubScarcitySub.
  ///
  /// In zh, this message translates to:
  /// **'释放低优先级占用'**
  String get salesHubScarcitySub;

  /// No description provided for @purchaseHubTitle.
  ///
  /// In zh, this message translates to:
  /// **'采购管理'**
  String get purchaseHubTitle;

  /// No description provided for @purchaseHubSectionReports.
  ///
  /// In zh, this message translates to:
  /// **'采购报表'**
  String get purchaseHubSectionReports;

  /// No description provided for @purchaseHubTaskCenter.
  ///
  /// In zh, this message translates to:
  /// **'采购任务中心'**
  String get purchaseHubTaskCenter;

  /// No description provided for @purchaseHubTaskCenterSub.
  ///
  /// In zh, this message translates to:
  /// **'按供应商拆订货'**
  String get purchaseHubTaskCenterSub;

  /// No description provided for @purchaseHubReturnVendor.
  ///
  /// In zh, this message translates to:
  /// **'待退回供应商'**
  String get purchaseHubReturnVendor;

  /// No description provided for @purchaseHubDocRequest.
  ///
  /// In zh, this message translates to:
  /// **'计划下达的采购申请'**
  String get purchaseHubDocRequest;

  /// No description provided for @purchaseHubDocOrder.
  ///
  /// In zh, this message translates to:
  /// **'采购订货单'**
  String get purchaseHubDocOrder;

  /// No description provided for @purchaseHubDocOrderSub.
  ///
  /// In zh, this message translates to:
  /// **'下单·跟踪到货'**
  String get purchaseHubDocOrderSub;

  /// No description provided for @purchaseHubDocReceipt.
  ///
  /// In zh, this message translates to:
  /// **'采购收货单'**
  String get purchaseHubDocReceipt;

  /// No description provided for @purchaseHubDocReceiptSub.
  ///
  /// In zh, this message translates to:
  /// **'收货·入库'**
  String get purchaseHubDocReceiptSub;

  /// No description provided for @purchaseHubDocReturn.
  ///
  /// In zh, this message translates to:
  /// **'采购退货单'**
  String get purchaseHubDocReturn;

  /// No description provided for @purchaseHubDocReturnSub.
  ///
  /// In zh, this message translates to:
  /// **'退货·出库'**
  String get purchaseHubDocReturnSub;

  /// No description provided for @purchaseHubReportDetail.
  ///
  /// In zh, this message translates to:
  /// **'采购明细报表'**
  String get purchaseHubReportDetail;

  /// No description provided for @purchaseHubReportSummary.
  ///
  /// In zh, this message translates to:
  /// **'采购汇总报表'**
  String get purchaseHubReportSummary;

  /// No description provided for @purchaseHubReportExpediting.
  ///
  /// In zh, this message translates to:
  /// **'采购催料单'**
  String get purchaseHubReportExpediting;

  /// No description provided for @purchaseHubReportExpeditingSub.
  ///
  /// In zh, this message translates to:
  /// **'订货未收·库存'**
  String get purchaseHubReportExpeditingSub;

  /// No description provided for @subcontractHubTitle.
  ///
  /// In zh, this message translates to:
  /// **'委外管理'**
  String get subcontractHubTitle;

  /// No description provided for @subcontractHubSectionReports.
  ///
  /// In zh, this message translates to:
  /// **'委外报表'**
  String get subcontractHubSectionReports;

  /// No description provided for @subcontractHubTaskCenter.
  ///
  /// In zh, this message translates to:
  /// **'委外任务中心'**
  String get subcontractHubTaskCenter;

  /// No description provided for @subcontractHubTaskCenterSub.
  ///
  /// In zh, this message translates to:
  /// **'按委外商拆订货'**
  String get subcontractHubTaskCenterSub;

  /// No description provided for @subcontractHubReturnVendor.
  ///
  /// In zh, this message translates to:
  /// **'待退回供应商'**
  String get subcontractHubReturnVendor;

  /// No description provided for @subcontractHubReportDetail.
  ///
  /// In zh, this message translates to:
  /// **'委外明细报表'**
  String get subcontractHubReportDetail;

  /// No description provided for @subcontractHubReportSummary.
  ///
  /// In zh, this message translates to:
  /// **'委外汇总报表'**
  String get subcontractHubReportSummary;

  /// No description provided for @subcontractHubReportInOut.
  ///
  /// In zh, this message translates to:
  /// **'委外出入状况表'**
  String get subcontractHubReportInOut;

  /// No description provided for @subcontractHubReportInOutSub.
  ///
  /// In zh, this message translates to:
  /// **'进出综合状况'**
  String get subcontractHubReportInOutSub;

  /// No description provided for @productionHubTitle.
  ///
  /// In zh, this message translates to:
  /// **'生产管理'**
  String get productionHubTitle;

  /// No description provided for @productionHubSectionReports.
  ///
  /// In zh, this message translates to:
  /// **'生产报表'**
  String get productionHubSectionReports;

  /// No description provided for @productionHubSchedule.
  ///
  /// In zh, this message translates to:
  /// **'生产调度与进度'**
  String get productionHubSchedule;

  /// No description provided for @productionHubScheduleSub.
  ///
  /// In zh, this message translates to:
  /// **'待排产·在产·完工'**
  String get productionHubScheduleSub;

  /// No description provided for @productionHubPlan.
  ///
  /// In zh, this message translates to:
  /// **'新建生产计划单'**
  String get productionHubPlan;

  /// No description provided for @productionHubPlanSub.
  ///
  /// In zh, this message translates to:
  /// **'引用销售订单或手工新建·历史记录'**
  String get productionHubPlanSub;

  /// No description provided for @productionHubPlanHistory.
  ///
  /// In zh, this message translates to:
  /// **'生产计划历史'**
  String get productionHubPlanHistory;

  /// No description provided for @productionHubPlanHistorySub.
  ///
  /// In zh, this message translates to:
  /// **'查看计划、审批与分批记录'**
  String get productionHubPlanHistorySub;

  /// No description provided for @productionHubMaterialAnalysis.
  ///
  /// In zh, this message translates to:
  /// **'物料分析准备'**
  String get productionHubMaterialAnalysis;

  /// No description provided for @productionHubMaterialAnalysisSub.
  ///
  /// In zh, this message translates to:
  /// **'齐套分析·路线确认·分批生成'**
  String get productionHubMaterialAnalysisSub;

  /// No description provided for @productionHubDaily.
  ///
  /// In zh, this message translates to:
  /// **'生产日报表'**
  String get productionHubDaily;

  /// No description provided for @productionHubDailySub.
  ///
  /// In zh, this message translates to:
  /// **'完工日报·红冲'**
  String get productionHubDailySub;

  /// No description provided for @productionHubReportPlanDetail.
  ///
  /// In zh, this message translates to:
  /// **'计划明细'**
  String get productionHubReportPlanDetail;

  /// No description provided for @productionHubReportPlanDetailSub.
  ///
  /// In zh, this message translates to:
  /// **'日期·货品·状态'**
  String get productionHubReportPlanDetailSub;

  /// No description provided for @productionHubReportPlanSummary.
  ///
  /// In zh, this message translates to:
  /// **'计划汇总'**
  String get productionHubReportPlanSummary;

  /// No description provided for @productionHubReportPlanSummarySub.
  ///
  /// In zh, this message translates to:
  /// **'单号·制单·审核'**
  String get productionHubReportPlanSummarySub;

  /// No description provided for @productionHubWhereUsed.
  ///
  /// In zh, this message translates to:
  /// **'物料反查产成品'**
  String get productionHubWhereUsed;

  /// No description provided for @productionHubWhereUsedSub.
  ///
  /// In zh, this message translates to:
  /// **'材料用在哪些产品'**
  String get productionHubWhereUsedSub;

  /// No description provided for @financeHubTitle.
  ///
  /// In zh, this message translates to:
  /// **'钱流管理'**
  String get financeHubTitle;

  /// No description provided for @financeHubSectionReports.
  ///
  /// In zh, this message translates to:
  /// **'钱流报表'**
  String get financeHubSectionReports;

  /// No description provided for @financeHubApprovalOwners.
  ///
  /// In zh, this message translates to:
  /// **'审批负责人设置'**
  String get financeHubApprovalOwners;

  /// No description provided for @financeHubTaskApproval.
  ///
  /// In zh, this message translates to:
  /// **'订货审批任务中心'**
  String get financeHubTaskApproval;

  /// No description provided for @financeSalesAllQueueLabel.
  ///
  /// In zh, this message translates to:
  /// **'销售订单财务确认'**
  String get financeSalesAllQueueLabel;

  /// No description provided for @financeSalesInitialQueueLabel.
  ///
  /// In zh, this message translates to:
  /// **'销售订单首次财务确认'**
  String get financeSalesInitialQueueLabel;

  /// No description provided for @financeSalesChangesQueueLabel.
  ///
  /// In zh, this message translates to:
  /// **'销售订单修改'**
  String get financeSalesChangesQueueLabel;

  /// No description provided for @financeSalesQueueCountLoading.
  ///
  /// In zh, this message translates to:
  /// **'正在加载{queue}待办数量'**
  String financeSalesQueueCountLoading(String queue);

  /// No description provided for @financeSalesQueueCountFailed.
  ///
  /// In zh, this message translates to:
  /// **'{queue}待办数量加载失败，请进入任务页重试'**
  String financeSalesQueueCountFailed(String queue);

  /// No description provided for @financeSalesQueueCountEmpty.
  ///
  /// In zh, this message translates to:
  /// **'没有待处理的{queue}'**
  String financeSalesQueueCountEmpty(String queue);

  /// No description provided for @financeSalesQueueCountPending.
  ///
  /// In zh, this message translates to:
  /// **'待处理{queue}：{count}项'**
  String financeSalesQueueCountPending(String queue, int count);

  /// No description provided for @financeHubTaskApprovalSub.
  ///
  /// In zh, this message translates to:
  /// **'采购与委外订货审批'**
  String get financeHubTaskApprovalSub;

  /// No description provided for @financeHubTaskOverDelivery.
  ///
  /// In zh, this message translates to:
  /// **'超量到货审批'**
  String get financeHubTaskOverDelivery;

  /// No description provided for @financeHubTaskOverDeliverySub.
  ///
  /// In zh, this message translates to:
  /// **'审核超量到货'**
  String get financeHubTaskOverDeliverySub;

  /// No description provided for @financeHubDocReceipt.
  ///
  /// In zh, this message translates to:
  /// **'销售收款'**
  String get financeHubDocReceipt;

  /// No description provided for @financeHubDocReceiptSub.
  ///
  /// In zh, this message translates to:
  /// **'登记客户付款，核对尚未收清的款项'**
  String get financeHubDocReceiptSub;

  /// No description provided for @financeHubDocPayment.
  ///
  /// In zh, this message translates to:
  /// **'采购付款'**
  String get financeHubDocPayment;

  /// No description provided for @financeHubDocPaymentSub.
  ///
  /// In zh, this message translates to:
  /// **'支付供应商欠款，核对付款记录'**
  String get financeHubDocPaymentSub;

  /// No description provided for @financeHubDocExpense.
  ///
  /// In zh, this message translates to:
  /// **'一般费用'**
  String get financeHubDocExpense;

  /// No description provided for @financeHubSubAllocatedByDept.
  ///
  /// In zh, this message translates to:
  /// **'按部门分摊'**
  String get financeHubSubAllocatedByDept;

  /// No description provided for @financeHubDocIncome.
  ///
  /// In zh, this message translates to:
  /// **'其它收入'**
  String get financeHubDocIncome;

  /// No description provided for @financeHubDocBankTransfer.
  ///
  /// In zh, this message translates to:
  /// **'银行存取款'**
  String get financeHubDocBankTransfer;

  /// No description provided for @financeHubDocBankTransferSub.
  ///
  /// In zh, this message translates to:
  /// **'账户之间转账'**
  String get financeHubDocBankTransferSub;

  /// No description provided for @financeHubDocCheck.
  ///
  /// In zh, this message translates to:
  /// **'支票管理'**
  String get financeHubDocCheck;

  /// No description provided for @financeHubDocCheckSub.
  ///
  /// In zh, this message translates to:
  /// **'支票账户视图'**
  String get financeHubDocCheckSub;

  /// No description provided for @financeHubDocAssets.
  ///
  /// In zh, this message translates to:
  /// **'资产与待摊'**
  String get financeHubDocAssets;

  /// No description provided for @financeHubDocAssetsSub.
  ///
  /// In zh, this message translates to:
  /// **'管理资产价值及每月费用'**
  String get financeHubDocAssetsSub;

  /// No description provided for @financeHubReportArAp.
  ///
  /// In zh, this message translates to:
  /// **'应收应付'**
  String get financeHubReportArAp;

  /// No description provided for @financeHubReportArApSub.
  ///
  /// In zh, this message translates to:
  /// **'客户·供应商余额'**
  String get financeHubReportArApSub;

  /// No description provided for @financeHubReportDetail.
  ///
  /// In zh, this message translates to:
  /// **'明细报表'**
  String get financeHubReportDetail;

  /// No description provided for @financeHubReportDetailSub.
  ///
  /// In zh, this message translates to:
  /// **'收款·付款·费用'**
  String get financeHubReportDetailSub;

  /// No description provided for @financeHubReportSummary.
  ///
  /// In zh, this message translates to:
  /// **'汇总报表'**
  String get financeHubReportSummary;

  /// No description provided for @financeHubReportSummarySub.
  ///
  /// In zh, this message translates to:
  /// **'收支汇总'**
  String get financeHubReportSummarySub;

  /// No description provided for @financeHubReportStatement.
  ///
  /// In zh, this message translates to:
  /// **'往来对帐单'**
  String get financeHubReportStatement;

  /// No description provided for @financeHubReportStatementSub.
  ///
  /// In zh, this message translates to:
  /// **'客户·供应商对账'**
  String get financeHubReportStatementSub;

  /// No description provided for @financeHubReportAccountFlow.
  ///
  /// In zh, this message translates to:
  /// **'账户流水'**
  String get financeHubReportAccountFlow;

  /// No description provided for @financeHubReportAccountFlowSub.
  ///
  /// In zh, this message translates to:
  /// **'账户进出流水'**
  String get financeHubReportAccountFlowSub;

  /// No description provided for @financeHubReportRecon.
  ///
  /// In zh, this message translates to:
  /// **'对账单'**
  String get financeHubReportRecon;

  /// No description provided for @financeHubReportReconSub.
  ///
  /// In zh, this message translates to:
  /// **'月结对账'**
  String get financeHubReportReconSub;

  /// No description provided for @financeHubReportCost.
  ///
  /// In zh, this message translates to:
  /// **'成本核算'**
  String get financeHubReportCost;

  /// No description provided for @financeHubReportCostSub.
  ///
  /// In zh, this message translates to:
  /// **'产品·销售成本'**
  String get financeHubReportCostSub;

  /// No description provided for @financeHubReportGl.
  ///
  /// In zh, this message translates to:
  /// **'总账报表'**
  String get financeHubReportGl;

  /// No description provided for @financeHubReportGlSub.
  ///
  /// In zh, this message translates to:
  /// **'科目·资产·利润'**
  String get financeHubReportGlSub;

  /// No description provided for @warehouseHubTitle.
  ///
  /// In zh, this message translates to:
  /// **'仓库管理'**
  String get warehouseHubTitle;

  /// No description provided for @warehouseHubSectionDocs.
  ///
  /// In zh, this message translates to:
  /// **'出入库单据'**
  String get warehouseHubSectionDocs;

  /// No description provided for @warehouseHubSectionDocsDesc.
  ///
  /// In zh, this message translates to:
  /// **'调拨·其它出入库·领退料·产成品进出仓·盘点'**
  String get warehouseHubSectionDocsDesc;

  /// No description provided for @warehouseHubSectionInventory.
  ///
  /// In zh, this message translates to:
  /// **'库存查询'**
  String get warehouseHubSectionInventory;

  /// No description provided for @warehouseHubSectionInventoryDesc.
  ///
  /// In zh, this message translates to:
  /// **'即时库存·库存查询·出入库流水'**
  String get warehouseHubSectionInventoryDesc;

  /// No description provided for @warehouseHubSectionReports.
  ///
  /// In zh, this message translates to:
  /// **'仓库报表'**
  String get warehouseHubSectionReports;

  /// No description provided for @warehouseHubSectionReportsDesc.
  ///
  /// In zh, this message translates to:
  /// **'明细(一行一货品)·汇总(一行一单)'**
  String get warehouseHubSectionReportsDesc;

  /// No description provided for @warehouseHubTaskExpected.
  ///
  /// In zh, this message translates to:
  /// **'预计到货任务中心'**
  String get warehouseHubTaskExpected;

  /// No description provided for @warehouseHubTaskExpectedSub.
  ///
  /// In zh, this message translates to:
  /// **'登记实际到货'**
  String get warehouseHubTaskExpectedSub;

  /// No description provided for @warehouseHubTaskException.
  ///
  /// In zh, this message translates to:
  /// **'到货异常任务中心'**
  String get warehouseHubTaskException;

  /// No description provided for @warehouseHubTaskExceptionSub.
  ///
  /// In zh, this message translates to:
  /// **'超量先隔离'**
  String get warehouseHubTaskExceptionSub;

  /// No description provided for @warehouseHubTaskPicking.
  ///
  /// In zh, this message translates to:
  /// **'生产领料任务中心'**
  String get warehouseHubTaskPicking;

  /// No description provided for @warehouseHubTaskPickingSub.
  ///
  /// In zh, this message translates to:
  /// **'备料·跟踪领取'**
  String get warehouseHubTaskPickingSub;

  /// No description provided for @warehouseHubDocTransfer.
  ///
  /// In zh, this message translates to:
  /// **'仓库调拨'**
  String get warehouseHubDocTransfer;

  /// No description provided for @warehouseHubDocTransferSub.
  ///
  /// In zh, this message translates to:
  /// **'仓库间调拨'**
  String get warehouseHubDocTransferSub;

  /// No description provided for @warehouseHubDocOtherIn.
  ///
  /// In zh, this message translates to:
  /// **'其它入库'**
  String get warehouseHubDocOtherIn;

  /// No description provided for @warehouseHubDocOtherInSub.
  ///
  /// In zh, this message translates to:
  /// **'无单据入库'**
  String get warehouseHubDocOtherInSub;

  /// No description provided for @warehouseHubDocOtherOut.
  ///
  /// In zh, this message translates to:
  /// **'其它出库'**
  String get warehouseHubDocOtherOut;

  /// No description provided for @warehouseHubDocOtherOutSub.
  ///
  /// In zh, this message translates to:
  /// **'无单据出库'**
  String get warehouseHubDocOtherOutSub;

  /// No description provided for @warehouseHubDocDraw.
  ///
  /// In zh, this message translates to:
  /// **'生产领料'**
  String get warehouseHubDocDraw;

  /// No description provided for @warehouseHubDocDrawSub.
  ///
  /// In zh, this message translates to:
  /// **'车间领料'**
  String get warehouseHubDocDrawSub;

  /// No description provided for @warehouseHubDocWdraw.
  ///
  /// In zh, this message translates to:
  /// **'生产退料'**
  String get warehouseHubDocWdraw;

  /// No description provided for @warehouseHubDocWdrawSub.
  ///
  /// In zh, this message translates to:
  /// **'退回车间料'**
  String get warehouseHubDocWdrawSub;

  /// No description provided for @warehouseHubDocFinishedIn.
  ///
  /// In zh, this message translates to:
  /// **'产成品进仓'**
  String get warehouseHubDocFinishedIn;

  /// No description provided for @warehouseHubDocFinishedInSub.
  ///
  /// In zh, this message translates to:
  /// **'成品入库'**
  String get warehouseHubDocFinishedInSub;

  /// No description provided for @warehouseHubDocFinishedOut.
  ///
  /// In zh, this message translates to:
  /// **'产成品出仓'**
  String get warehouseHubDocFinishedOut;

  /// No description provided for @warehouseHubDocFinishedOutSub.
  ///
  /// In zh, this message translates to:
  /// **'成品出库'**
  String get warehouseHubDocFinishedOutSub;

  /// No description provided for @warehouseHubDocCheck.
  ///
  /// In zh, this message translates to:
  /// **'盘点'**
  String get warehouseHubDocCheck;

  /// No description provided for @warehouseHubDocCheckSub.
  ///
  /// In zh, this message translates to:
  /// **'盘点盈亏'**
  String get warehouseHubDocCheckSub;

  /// No description provided for @warehouseHubInventoryLive.
  ///
  /// In zh, this message translates to:
  /// **'即时库存'**
  String get warehouseHubInventoryLive;

  /// No description provided for @warehouseHubInventoryLiveSub.
  ///
  /// In zh, this message translates to:
  /// **'实时可用库存'**
  String get warehouseHubInventoryLiveSub;

  /// No description provided for @warehouseHubInventoryBalance.
  ///
  /// In zh, this message translates to:
  /// **'库存查询'**
  String get warehouseHubInventoryBalance;

  /// No description provided for @warehouseHubInventoryBalanceSub.
  ///
  /// In zh, this message translates to:
  /// **'按货品查余额'**
  String get warehouseHubInventoryBalanceSub;

  /// No description provided for @warehouseHubInventoryMovement.
  ///
  /// In zh, this message translates to:
  /// **'出入库流水'**
  String get warehouseHubInventoryMovement;

  /// No description provided for @warehouseHubInventoryMovementSub.
  ///
  /// In zh, this message translates to:
  /// **'进出流水明细'**
  String get warehouseHubInventoryMovementSub;

  /// No description provided for @warehouseHubReportDetail.
  ///
  /// In zh, this message translates to:
  /// **'仓库明细报表'**
  String get warehouseHubReportDetail;

  /// No description provided for @warehouseHubReportSummary.
  ///
  /// In zh, this message translates to:
  /// **'仓库汇总报表'**
  String get warehouseHubReportSummary;

  /// No description provided for @basicDataHubTitle.
  ///
  /// In zh, this message translates to:
  /// **'基础资料'**
  String get basicDataHubTitle;

  /// No description provided for @basicDataHubGoods.
  ///
  /// In zh, this message translates to:
  /// **'货品资料'**
  String get basicDataHubGoods;

  /// No description provided for @basicDataHubGoodsSub.
  ///
  /// In zh, this message translates to:
  /// **'物料分类树与货品主档'**
  String get basicDataHubGoodsSub;

  /// No description provided for @basicDataHubMould.
  ///
  /// In zh, this message translates to:
  /// **'模具资料'**
  String get basicDataHubMould;

  /// No description provided for @basicDataHubMouldSub.
  ///
  /// In zh, this message translates to:
  /// **'模具系列分类与主档'**
  String get basicDataHubMouldSub;

  /// No description provided for @basicDataHubClient.
  ///
  /// In zh, this message translates to:
  /// **'客户资料'**
  String get basicDataHubClient;

  /// No description provided for @basicDataHubClientSub.
  ///
  /// In zh, this message translates to:
  /// **'客户分类与主档'**
  String get basicDataHubClientSub;

  /// No description provided for @basicDataHubSupplier.
  ///
  /// In zh, this message translates to:
  /// **'供应商资料'**
  String get basicDataHubSupplier;

  /// No description provided for @basicDataHubSupplierSub.
  ///
  /// In zh, this message translates to:
  /// **'供应商分类与主档'**
  String get basicDataHubSupplierSub;

  /// No description provided for @basicDataHubColor.
  ///
  /// In zh, this message translates to:
  /// **'颜色资料'**
  String get basicDataHubColor;

  /// No description provided for @basicDataHubColorSub.
  ///
  /// In zh, this message translates to:
  /// **'颜色主档'**
  String get basicDataHubColorSub;

  /// No description provided for @basicDataHubUnit.
  ///
  /// In zh, this message translates to:
  /// **'基本单位'**
  String get basicDataHubUnit;

  /// No description provided for @basicDataHubUnitSub.
  ///
  /// In zh, this message translates to:
  /// **'计量单位主档'**
  String get basicDataHubUnitSub;

  /// No description provided for @basicDataHubCurrency.
  ///
  /// In zh, this message translates to:
  /// **'币种资料'**
  String get basicDataHubCurrency;

  /// No description provided for @basicDataHubCurrencySub.
  ///
  /// In zh, this message translates to:
  /// **'币种·参考汇率'**
  String get basicDataHubCurrencySub;

  /// No description provided for @basicDataHubWarehouse.
  ///
  /// In zh, this message translates to:
  /// **'仓库资料'**
  String get basicDataHubWarehouse;

  /// No description provided for @basicDataHubWarehouseSub.
  ///
  /// In zh, this message translates to:
  /// **'仓库主档'**
  String get basicDataHubWarehouseSub;

  /// No description provided for @basicDataHubAccount.
  ///
  /// In zh, this message translates to:
  /// **'账户资料'**
  String get basicDataHubAccount;

  /// No description provided for @basicDataHubAccountSub.
  ///
  /// In zh, this message translates to:
  /// **'账户·期初·余额'**
  String get basicDataHubAccountSub;

  /// No description provided for @basicDataHubPaymentStyle.
  ///
  /// In zh, this message translates to:
  /// **'收付款类别'**
  String get basicDataHubPaymentStyle;

  /// No description provided for @basicDataHubPaymentStyleSub.
  ///
  /// In zh, this message translates to:
  /// **'资产负债等六大类'**
  String get basicDataHubPaymentStyleSub;

  /// No description provided for @basicDataHubSettlementMethod.
  ///
  /// In zh, this message translates to:
  /// **'结算方式'**
  String get basicDataHubSettlementMethod;

  /// No description provided for @basicDataHubSettlementMethodSub.
  ///
  /// In zh, this message translates to:
  /// **'结账字典·账期口径'**
  String get basicDataHubSettlementMethodSub;

  /// No description provided for @impersonationSwitchPerson.
  ///
  /// In zh, this message translates to:
  /// **'切换人'**
  String get impersonationSwitchPerson;

  /// No description provided for @impersonationEnterPasswordTitle.
  ///
  /// In zh, this message translates to:
  /// **'确认切换人'**
  String get impersonationEnterPasswordTitle;

  /// No description provided for @impersonationEnterPasswordHint.
  ///
  /// In zh, this message translates to:
  /// **'为安全验证，请输入你的登录密码。通过后 15 分钟内可自由切换，无需重复输入。'**
  String get impersonationEnterPasswordHint;

  /// No description provided for @impersonationPasswordLabel.
  ///
  /// In zh, this message translates to:
  /// **'登录密码'**
  String get impersonationPasswordLabel;

  /// No description provided for @impersonationConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认'**
  String get impersonationConfirm;

  /// No description provided for @impersonationTargetPickerTitle.
  ///
  /// In zh, this message translates to:
  /// **'选择要查看的员工'**
  String get impersonationTargetPickerTitle;

  /// No description provided for @impersonationSearchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索姓名 / 工号'**
  String get impersonationSearchHint;

  /// No description provided for @impersonationBannerTitle.
  ///
  /// In zh, this message translates to:
  /// **'正在以 {name} 身份查看(只读)'**
  String impersonationBannerTitle(String name);

  /// No description provided for @impersonationBannerSwitch.
  ///
  /// In zh, this message translates to:
  /// **'切换'**
  String get impersonationBannerSwitch;

  /// No description provided for @impersonationBannerExit.
  ///
  /// In zh, this message translates to:
  /// **'退出模拟'**
  String get impersonationBannerExit;

  /// No description provided for @impersonationRemainingMinutes.
  ///
  /// In zh, this message translates to:
  /// **'剩余 {count} 分钟'**
  String impersonationRemainingMinutes(int count);

  /// No description provided for @impersonationWrongPassword.
  ///
  /// In zh, this message translates to:
  /// **'密码错误'**
  String get impersonationWrongPassword;

  /// No description provided for @impersonationExited.
  ///
  /// In zh, this message translates to:
  /// **'已退出模拟身份'**
  String get impersonationExited;

  /// No description provided for @impersonationWindowExpired.
  ///
  /// In zh, this message translates to:
  /// **'模拟窗口已到期，已退出'**
  String get impersonationWindowExpired;

  /// No description provided for @impersonationRecent.
  ///
  /// In zh, this message translates to:
  /// **'最近'**
  String get impersonationRecent;

  /// No description provided for @impersonationNoTargets.
  ///
  /// In zh, this message translates to:
  /// **'暂无可切换的员工'**
  String get impersonationNoTargets;

  /// No description provided for @impersonationStartFailed.
  ///
  /// In zh, this message translates to:
  /// **'切换失败'**
  String get impersonationStartFailed;

  /// No description provided for @exportDialogTitle.
  ///
  /// In zh, this message translates to:
  /// **'导出 Excel'**
  String get exportDialogTitle;

  /// No description provided for @exportPasswordOptionalHint.
  ///
  /// In zh, this message translates to:
  /// **'密码可不填。不填将下载普通 Excel；填写 1–128 位密码则加密文件。'**
  String get exportPasswordOptionalHint;

  /// No description provided for @exportPasswordOptionalLabel.
  ///
  /// In zh, this message translates to:
  /// **'打开密码(可选，1–128 位)'**
  String get exportPasswordOptionalLabel;

  /// No description provided for @exportPasswordConfirmLabel.
  ///
  /// In zh, this message translates to:
  /// **'确认密码'**
  String get exportPasswordConfirmLabel;

  /// No description provided for @exportPasswordTooLong.
  ///
  /// In zh, this message translates to:
  /// **'密码不能超过 128 位'**
  String get exportPasswordTooLong;

  /// No description provided for @exportPasswordMismatch.
  ///
  /// In zh, this message translates to:
  /// **'两次密码不一致'**
  String get exportPasswordMismatch;

  /// No description provided for @exportDownloadPlain.
  ///
  /// In zh, this message translates to:
  /// **'直接下载'**
  String get exportDownloadPlain;

  /// No description provided for @exportDownloadEncrypted.
  ///
  /// In zh, this message translates to:
  /// **'加密下载'**
  String get exportDownloadEncrypted;

  /// No description provided for @exportFailed.
  ///
  /// In zh, this message translates to:
  /// **'导出失败，请稍后重试'**
  String get exportFailed;

  /// No description provided for @exportDownloadStarted.
  ///
  /// In zh, this message translates to:
  /// **'已开始下载 {name}'**
  String exportDownloadStarted(String name);

  /// No description provided for @exportDownloadSaved.
  ///
  /// In zh, this message translates to:
  /// **'已保存：{path}'**
  String exportDownloadSaved(String path);

  /// No description provided for @profileLoadingMessage.
  ///
  /// In zh, this message translates to:
  /// **'正在加载员工档案…'**
  String get profileLoadingMessage;

  /// No description provided for @profileLoadFailed.
  ///
  /// In zh, this message translates to:
  /// **'员工档案加载失败'**
  String get profileLoadFailed;

  /// No description provided for @profileUnboundTitle.
  ///
  /// In zh, this message translates to:
  /// **'当前账号未绑定员工档案'**
  String get profileUnboundTitle;

  /// No description provided for @profileUnboundDescription.
  ///
  /// In zh, this message translates to:
  /// **'请联系管理员或人事完成账号与员工档案绑定。'**
  String get profileUnboundDescription;

  /// No description provided for @profileSessionUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'当前未登录或会话不可用'**
  String get profileSessionUnavailable;

  /// No description provided for @profileValueNotProvided.
  ///
  /// In zh, this message translates to:
  /// **'未填写'**
  String get profileValueNotProvided;

  /// No description provided for @profileValueNotRegistered.
  ///
  /// In zh, this message translates to:
  /// **'未登记'**
  String get profileValueNotRegistered;

  /// No description provided for @profileAlternatePhoneLabel.
  ///
  /// In zh, this message translates to:
  /// **'备用手机号'**
  String get profileAlternatePhoneLabel;

  /// No description provided for @profileContractSummaryTitle.
  ///
  /// In zh, this message translates to:
  /// **'合同摘要'**
  String get profileContractSummaryTitle;

  /// No description provided for @profileTabOrgContract.
  ///
  /// In zh, this message translates to:
  /// **'组织与合同'**
  String get profileTabOrgContract;

  /// No description provided for @profileTabContactVehicle.
  ///
  /// In zh, this message translates to:
  /// **'联系与车辆'**
  String get profileTabContactVehicle;

  /// No description provided for @profileTabMyDocuments.
  ///
  /// In zh, this message translates to:
  /// **'我的文件'**
  String get profileTabMyDocuments;

  /// No description provided for @profileEmploymentHistoryTitle.
  ///
  /// In zh, this message translates to:
  /// **'任职记录'**
  String get profileEmploymentHistoryTitle;

  /// No description provided for @profileScopeNoticeTitle.
  ///
  /// In zh, this message translates to:
  /// **'信息范围说明'**
  String get profileScopeNoticeTitle;

  /// No description provided for @profileCompensationBoundaryDescription.
  ///
  /// In zh, this message translates to:
  /// **'薪酬与银行信息不会在“我的”页展示；这是有意设置的隐私边界。本人月度收入请从工资条核对，其他问题请联系授权人事。'**
  String get profileCompensationBoundaryDescription;

  /// No description provided for @profileMissingEmergencyContact.
  ///
  /// In zh, this message translates to:
  /// **'尚未登记紧急联系人，请先联系人事登记；登记后可在这里申请修改。'**
  String get profileMissingEmergencyContact;

  /// No description provided for @profileAlternatePhoneCount.
  ///
  /// In zh, this message translates to:
  /// **'已登记 {count} 个备用号码'**
  String profileAlternatePhoneCount(int count);

  /// No description provided for @profileVehiclesPhonesEmptyHint.
  ///
  /// In zh, this message translates to:
  /// **'登记车辆与备用手机号，按车牌快速找到你'**
  String get profileVehiclesPhonesEmptyHint;

  /// No description provided for @historyEventConfirm.
  ///
  /// In zh, this message translates to:
  /// **'转正'**
  String get historyEventConfirm;

  /// No description provided for @accountProvisionPermissionDenied.
  ///
  /// In zh, this message translates to:
  /// **'你没有开通账号权限，请联系账号支持人员处理'**
  String get accountProvisionPermissionDenied;

  /// No description provided for @accountProvisionAlreadyExists.
  ///
  /// In zh, this message translates to:
  /// **'该员工已有账号或账号未启用，不能重复开通'**
  String get accountProvisionAlreadyExists;

  /// No description provided for @accountProvisionConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'开通账号确认'**
  String get accountProvisionConfirmTitle;

  /// No description provided for @accountProvisionFailed.
  ///
  /// In zh, this message translates to:
  /// **'开通账号失败，请稍后重试'**
  String get accountProvisionFailed;

  /// No description provided for @accountProvisionInProgress.
  ///
  /// In zh, this message translates to:
  /// **'开通中'**
  String get accountProvisionInProgress;

  /// No description provided for @accountStatusNotProvisioned.
  ///
  /// In zh, this message translates to:
  /// **'未开通账号'**
  String get accountStatusNotProvisioned;

  /// No description provided for @accountStatusInactive.
  ///
  /// In zh, this message translates to:
  /// **'账号未启用'**
  String get accountStatusInactive;

  /// No description provided for @pagePermissionAccountNotProvisionedTitle.
  ///
  /// In zh, this message translates to:
  /// **'此人还未开通账号，暂不能设置权限'**
  String get pagePermissionAccountNotProvisionedTitle;

  /// No description provided for @pagePermissionAccountNotProvisionedCanProvision.
  ///
  /// In zh, this message translates to:
  /// **'请先开通登录账号；一次性凭据确认保存后，将自动加载此人的权限详情。'**
  String get pagePermissionAccountNotProvisionedCanProvision;

  /// No description provided for @pagePermissionAccountNotProvisionedNoAccess.
  ///
  /// In zh, this message translates to:
  /// **'请联系具备“账号支持”权限的人员开通登录账号。'**
  String get pagePermissionAccountNotProvisionedNoAccess;

  /// No description provided for @employeePermissionSettingsTooltip.
  ///
  /// In zh, this message translates to:
  /// **'设置员工权限'**
  String get employeePermissionSettingsTooltip;

  /// No description provided for @employeeAccountNotProvisionedTooltip.
  ///
  /// In zh, this message translates to:
  /// **'该员工未开通账号'**
  String get employeeAccountNotProvisionedTooltip;

  /// No description provided for @employeeResignedCannotProvision.
  ///
  /// In zh, this message translates to:
  /// **'该员工已离职，不能开通登录账号'**
  String get employeeResignedCannotProvision;

  /// No description provided for @employeeAccountNotProvisionedContactSupport.
  ///
  /// In zh, this message translates to:
  /// **'该员工还未开通账号，请联系账号支持人员处理'**
  String get employeeAccountNotProvisionedContactSupport;

  /// No description provided for @materialMainWarehouse.
  ///
  /// In zh, this message translates to:
  /// **'主仓库'**
  String get materialMainWarehouse;

  /// No description provided for @materialWarehouseScopeExplanation.
  ///
  /// In zh, this message translates to:
  /// **'按主仓库合计备料，实际领料由仓库安排。'**
  String get materialWarehouseScopeExplanation;

  /// No description provided for @materialSearchHint.
  ///
  /// In zh, this message translates to:
  /// **'查找产品或物料'**
  String get materialSearchHint;

  /// No description provided for @materialByProduct.
  ///
  /// In zh, this message translates to:
  /// **'按产品看'**
  String get materialByProduct;

  /// No description provided for @materialByMaterial.
  ///
  /// In zh, this message translates to:
  /// **'按物料汇总'**
  String get materialByMaterial;

  /// No description provided for @materialIdentityByMaterial.
  ///
  /// In zh, this message translates to:
  /// **'物料 / 来源'**
  String get materialIdentityByMaterial;

  /// No description provided for @materialIdentityByProduct.
  ///
  /// In zh, this message translates to:
  /// **'产品 / BOM 层级'**
  String get materialIdentityByProduct;

  /// No description provided for @materialRoute.
  ///
  /// In zh, this message translates to:
  /// **'供应方式'**
  String get materialRoute;

  /// No description provided for @materialRequired.
  ///
  /// In zh, this message translates to:
  /// **'需要数量'**
  String get materialRequired;

  /// No description provided for @materialAllocated.
  ///
  /// In zh, this message translates to:
  /// **'已备数量'**
  String get materialAllocated;

  /// No description provided for @materialPreparedQuantityHint.
  ///
  /// In zh, this message translates to:
  /// **'已分配给本批的合格物料，含本批正式预留和已领用量。合格到货已包含在分配中，不重复相加；待检与在途不计入。本批已备数量不等于仓库即时余额。'**
  String get materialPreparedQuantityHint;

  /// No description provided for @materialShortage.
  ///
  /// In zh, this message translates to:
  /// **'还缺数量'**
  String get materialShortage;

  /// No description provided for @materialPhysicalShortageHint.
  ///
  /// In zh, this message translates to:
  /// **'本批需求扣除已覆盖本批的合格物料后仍缺的数量。下达采购、委外或车间计划不会减少实物缺口；合格入库并归属本批后才减少。待补数量另外扣除在途，避免重复下达。'**
  String get materialPhysicalShortageHint;

  /// No description provided for @materialSupplyProgressHint.
  ///
  /// In zh, this message translates to:
  /// **'跟踪下单、财务审批、收货、检验与入库进度；双击行查看明细。下达后仍保留实物缺口，合格入库后更新。'**
  String get materialSupplyProgressHint;

  /// No description provided for @materialToSupply.
  ///
  /// In zh, this message translates to:
  /// **'建议下单'**
  String get materialToSupply;

  /// No description provided for @materialFutureSupply.
  ///
  /// In zh, this message translates to:
  /// **'在途未到'**
  String get materialFutureSupply;

  /// No description provided for @materialProgress.
  ///
  /// In zh, this message translates to:
  /// **'进度 / 待办'**
  String get materialProgress;

  /// No description provided for @materialMixedRoutes.
  ///
  /// In zh, this message translates to:
  /// **'多种路线'**
  String get materialMixedRoutes;

  /// No description provided for @materialAggregateSources.
  ///
  /// In zh, this message translates to:
  /// **'{products} 个产品 · {paths} 条路径'**
  String materialAggregateSources(int products, int paths);

  /// No description provided for @materialCreateRoutes.
  ///
  /// In zh, this message translates to:
  /// **'确认路线({count})'**
  String materialCreateRoutes(int count);

  /// No description provided for @materialRouteReasonTitle.
  ///
  /// In zh, this message translates to:
  /// **'路线原因(选填)'**
  String get materialRouteReasonTitle;

  /// No description provided for @materialRouteChangedRetry.
  ///
  /// In zh, this message translates to:
  /// **'分析已更新，请核对当前所选路线后重试'**
  String get materialRouteChangedRetry;

  /// No description provided for @materialWarehouseFacts.
  ///
  /// In zh, this message translates to:
  /// **'仓库与供给明细'**
  String get materialWarehouseFacts;

  /// No description provided for @materialExactStock.
  ///
  /// In zh, this message translates to:
  /// **'本节点合格绑定'**
  String get materialExactStock;

  /// No description provided for @materialPublicStock.
  ///
  /// In zh, this message translates to:
  /// **'公共现货'**
  String get materialPublicStock;

  /// No description provided for @materialClaimedSupply.
  ///
  /// In zh, this message translates to:
  /// **'本节点已采用'**
  String get materialClaimedSupply;

  /// No description provided for @materialTaskBuy.
  ///
  /// In zh, this message translates to:
  /// **'下达采购'**
  String get materialTaskBuy;

  /// No description provided for @materialTaskSubcontract.
  ///
  /// In zh, this message translates to:
  /// **'下达委外'**
  String get materialTaskSubcontract;

  /// No description provided for @materialTaskWorkshop.
  ///
  /// In zh, this message translates to:
  /// **'下达车间'**
  String get materialTaskWorkshop;

  /// No description provided for @materialTaskIssued.
  ///
  /// In zh, this message translates to:
  /// **'已下达'**
  String get materialTaskIssued;

  /// No description provided for @materialTaskBlocked.
  ///
  /// In zh, this message translates to:
  /// **'需处理'**
  String get materialTaskBlocked;

  /// No description provided for @materialTaskEmpty.
  ///
  /// In zh, this message translates to:
  /// **'当前筛选没有任务'**
  String get materialTaskEmpty;

  /// No description provided for @materialTaskBuyHint.
  ///
  /// In zh, this message translates to:
  /// **'按剩余需求下达采购，已下达任务可查看订货、到货和质检进度。'**
  String get materialTaskBuyHint;

  /// No description provided for @materialTaskSubcontractHint.
  ///
  /// In zh, this message translates to:
  /// **'按剩余需求下达委外，有子层物料先形成车间备料任务，进度可继续跟踪。'**
  String get materialTaskSubcontractHint;

  /// No description provided for @materialTaskWorkshopHint.
  ///
  /// In zh, this message translates to:
  /// **'填写数量、车间和负责人后下达；缺料任务先进入待料，齐套并领料后才能开工。'**
  String get materialTaskWorkshopHint;

  /// No description provided for @materialTaskSectionHint.
  ///
  /// In zh, this message translates to:
  /// **'按供料路线集中处理，查看未下达、已下达与待处理任务。'**
  String get materialTaskSectionHint;

  /// No description provided for @materialWarehouseLimit.
  ///
  /// In zh, this message translates to:
  /// **'本次分析最多支持 100 个实际仓库，当前主仓范围超出限制，请调整仓库范围后再分析'**
  String get materialWarehouseLimit;

  /// No description provided for @materialRoutesNext.
  ///
  /// In zh, this message translates to:
  /// **'下一步：核对 {count} 条待确认路线，勾选后点击“确认路线”。每条路线按当前选择保存。'**
  String materialRoutesNext(int count);

  /// No description provided for @materialIssueNext.
  ///
  /// In zh, this message translates to:
  /// **'下一步：进入“下达采购 / 下达委外 / 下达车间”，按未下达余量办理并查看已下达进度。'**
  String get materialIssueNext;

  /// No description provided for @materialWorkshopNext.
  ///
  /// In zh, this message translates to:
  /// **'下一步：{count} 个产品可先下达车间。填写数量、车间和负责人；缺料批次等待齐套和领料后开工。'**
  String materialWorkshopNext(int count);

  /// No description provided for @materialPreparedChildCreated.
  ///
  /// In zh, this message translates to:
  /// **'已创建 {count} 个备料子任务，尚未下达车间'**
  String materialPreparedChildCreated(int count);

  /// No description provided for @materialPreparedChildNext.
  ///
  /// In zh, this message translates to:
  /// **'核对下方已选行的数量、车间和负责人，再点击“生成生产计划”；无审核权限时将提交审批。'**
  String get materialPreparedChildNext;

  /// No description provided for @materialPreparedChildNeedPlanner.
  ///
  /// In zh, this message translates to:
  /// **'请由有生成生产计划权限的员工填写数量、车间和负责人并提交计划。'**
  String get materialPreparedChildNeedPlanner;

  /// No description provided for @materialRouteMemoryLoading.
  ///
  /// In zh, this message translates to:
  /// **'正在读取上次路线，请稍后确认'**
  String get materialRouteMemoryLoading;

  /// No description provided for @materialRouteMemoryUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'上次路线读取失败，请核对当前路线后确认'**
  String get materialRouteMemoryUnavailable;

  /// No description provided for @materialRootSupply.
  ///
  /// In zh, this message translates to:
  /// **'顶层供料任务'**
  String get materialRootSupply;

  /// No description provided for @materialRootRoutePending.
  ///
  /// In zh, this message translates to:
  /// **'路线待确认'**
  String get materialRootRoutePending;

  /// No description provided for @materialRootExternalRoute.
  ///
  /// In zh, this message translates to:
  /// **'顶层已选择采购或委外，请到对应入口下达'**
  String get materialRootExternalRoute;

  /// No description provided for @materialRootExistingStock.
  ///
  /// In zh, this message translates to:
  /// **'将优先交接已分配现货 {quantity}，下方只填写剩余的追加供料数量。'**
  String materialRootExistingStock(String quantity);

  /// No description provided for @materialRootSupplyCompleted.
  ///
  /// In zh, this message translates to:
  /// **'供料需求已完成'**
  String get materialRootSupplyCompleted;

  /// No description provided for @materialRootOutputHistory.
  ///
  /// In zh, this message translates to:
  /// **'顶层供料交接记录'**
  String get materialRootOutputHistory;

  /// No description provided for @materialRootStockAllocation.
  ///
  /// In zh, this message translates to:
  /// **'现货交接'**
  String get materialRootStockAllocation;

  /// No description provided for @materialRootReceivedSupply.
  ///
  /// In zh, this message translates to:
  /// **'合格到货交接'**
  String get materialRootReceivedSupply;

  /// No description provided for @materialRootOutputReversed.
  ///
  /// In zh, this message translates to:
  /// **'交接已撤回'**
  String get materialRootOutputReversed;

  /// No description provided for @materialSupplyTasksAndReversals.
  ///
  /// In zh, this message translates to:
  /// **'供给任务与撤回记录'**
  String get materialSupplyTasksAndReversals;

  /// No description provided for @materialNotificationReversalReconcile.
  ///
  /// In zh, this message translates to:
  /// **'同步撤回'**
  String get materialNotificationReversalReconcile;

  /// No description provided for @materialRevokeRootStock.
  ///
  /// In zh, this message translates to:
  /// **'撤回现货交接'**
  String get materialRevokeRootStock;

  /// No description provided for @materialRootRevokeFailed.
  ///
  /// In zh, this message translates to:
  /// **'现货交接撤回失败，请刷新后核对'**
  String get materialRootRevokeFailed;

  /// No description provided for @materialRootSupplyProcessed.
  ///
  /// In zh, this message translates to:
  /// **'本批供料已处理，现货交接和追加需求请查看对应记录'**
  String get materialRootSupplyProcessed;

  /// 订货单批准后改量按钮（采购/委外）
  ///
  /// In zh, this message translates to:
  /// **'改量'**
  String get orderChangeQtyButton;

  /// 改量弹窗标题
  ///
  /// In zh, this message translates to:
  /// **'订单改量'**
  String get orderChangeQtyTitle;

  /// 改量弹窗顶部红色警示
  ///
  /// In zh, this message translates to:
  /// **'批准后改量立即生效，并自动重回财务复核；财务将看到修改清单（以前→现在）。驳回不会自动还原数量。'**
  String get orderChangeQtyWarning;

  /// 改量弹窗行内当前数量前缀
  ///
  /// In zh, this message translates to:
  /// **'现 {qty}'**
  String orderChangeQtyCurrent(String qty);

  /// 改量弹窗输入框标签
  ///
  /// In zh, this message translates to:
  /// **'新数量'**
  String get orderChangeQtyNewQty;

  /// 改量弹窗确认按钮
  ///
  /// In zh, this message translates to:
  /// **'确认改量'**
  String get orderChangeQtyConfirm;

  /// 改量行内校验失败提示
  ///
  /// In zh, this message translates to:
  /// **'存在无效数量（必须大于 0），请检查'**
  String get orderChangeQtyInvalid;

  /// 改量成功提示
  ///
  /// In zh, this message translates to:
  /// **'已改量，订货单已重回财务复核'**
  String get orderChangeQtySuccess;

  /// 改量失败提示
  ///
  /// In zh, this message translates to:
  /// **'改量失败，请稍后重试'**
  String get orderChangeQtyFailed;

  /// 修改清单旧行前缀（删除线）
  ///
  /// In zh, this message translates to:
  /// **'以前 {value}'**
  String orderQtyChangeOld(String value);

  /// 修改清单新值前缀（加粗）
  ///
  /// In zh, this message translates to:
  /// **'现在 {value}'**
  String orderQtyChangeNew(String value);

  /// 订货审批任务列表默认状态
  ///
  /// In zh, this message translates to:
  /// **'待财务复核'**
  String get procurementApprovalStatusPending;

  /// 订货审批任务列表改量徽标
  ///
  /// In zh, this message translates to:
  /// **'改后待复核 · 改量 {count} 处'**
  String procurementApprovalStatusChanged(int count);

  /// 订货审批审核详情修改清单卡片标题
  ///
  /// In zh, this message translates to:
  /// **'修改清单 · 改量 {count} 处'**
  String procurementApprovalQtyChangesTitle(int count);

  /// 修改清单卡片说明
  ///
  /// In zh, this message translates to:
  /// **'订货单在财务批准后修改过数量，已自动重回财务复核；请逐行核对 以前→现在 后再复核。'**
  String get procurementApprovalQtyChangesHint;

  /// No description provided for @productionMaterialRecheck.
  ///
  /// In zh, this message translates to:
  /// **'重新核对备料'**
  String get productionMaterialRecheck;

  /// No description provided for @productionMaterialRecheckReady.
  ///
  /// In zh, this message translates to:
  /// **'物料已齐套，已按实际子仓生成领料单。请仓库发料完成后开工。'**
  String get productionMaterialRecheckReady;

  /// No description provided for @productionMaterialRecheckWaiting.
  ///
  /// In zh, this message translates to:
  /// **'已重新检查，当前仍有物料未满足，请核对实际入库和其他任务的预留。'**
  String get productionMaterialRecheckWaiting;

  /// No description provided for @fieldAutofilledReview.
  ///
  /// In zh, this message translates to:
  /// **'已自动带出上次记录或默认值，请核对后使用'**
  String get fieldAutofilledReview;

  /// No description provided for @workflowQuantityHint.
  ///
  /// In zh, this message translates to:
  /// **'按本行单位填写本次数量，箱、个、千克不要混填；引用来源时不能超过当前可用数量。'**
  String get workflowQuantityHint;

  /// No description provided for @workflowOrderQuantityHint.
  ///
  /// In zh, this message translates to:
  /// **'按本行单位填写客户订购数量。财务正在审核时不能修改；财务通过后再改会重新送审。'**
  String get workflowOrderQuantityHint;

  /// No description provided for @workflowReturnQuantityHint.
  ///
  /// In zh, this message translates to:
  /// **'按原出货明细的单位填写实际退回量，不能超过尚可退数量。退回实物审核后先待检，不会直接成为可销售库存。'**
  String get workflowReturnQuantityHint;

  /// No description provided for @workflowPriceHint.
  ///
  /// In zh, this message translates to:
  /// **'单价按本行单位和币种填写，金额随数量重新计算。不要把整行总金额填成单价。'**
  String get workflowPriceHint;

  /// No description provided for @workflowReturnPriceHint.
  ///
  /// In zh, this message translates to:
  /// **'退货贷项在审核时按原发运事实和累计已退金额计算，参考价格不能提高可退金额。'**
  String get workflowReturnPriceHint;

  /// No description provided for @workflowDiscountHint.
  ///
  /// In zh, this message translates to:
  /// **'折扣填小数：1是不打折，0.9是九折；不要填9或90。'**
  String get workflowDiscountHint;

  /// No description provided for @workflowExchangeRateHint.
  ///
  /// In zh, this message translates to:
  /// **'填写1单位原币折合多少本币，最多6位小数。自动带出的汇率也要核对本次单据。'**
  String get workflowExchangeRateHint;

  /// No description provided for @workflowTaxRateHint.
  ///
  /// In zh, this message translates to:
  /// **'填百分数，例如13表示13%；不要填0.13。'**
  String get workflowTaxRateHint;

  /// No description provided for @workflowCurrencyHint.
  ///
  /// In zh, this message translates to:
  /// **'币种决定本行单价和金额的含义；更换前请核对来源单据，不能只改显示名称。'**
  String get workflowCurrencyHint;

  /// No description provided for @workflowSettlementHint.
  ///
  /// In zh, this message translates to:
  /// **'按与供应商约定的结算方式选择。不同供应商、币种或结算条款可能拆成不同订货单。'**
  String get workflowSettlementHint;

  /// No description provided for @workflowPlanningQuantityHint.
  ///
  /// In zh, this message translates to:
  /// **'这是本次要安排的数量，不是实收数量。已安排的在途货还未成为库存，下达任务也不代表车间已经可以开工。'**
  String get workflowPlanningQuantityHint;

  /// No description provided for @workflowWorkshopQuantityHint.
  ///
  /// In zh, this message translates to:
  /// **'填写本次交给车间的数量。任务可先下达，但开工和领料仍须满足物料及状态条件。'**
  String get workflowWorkshopQuantityHint;

  /// No description provided for @workflowReportQuantityHint.
  ///
  /// In zh, this message translates to:
  /// **'按计划行单位填写本次实际完成量，不填累计产量。审核报工后还要经仓库登记、品质检查和入库。'**
  String get workflowReportQuantityHint;

  /// No description provided for @workflowArrivalQuantityHint.
  ///
  /// In zh, this message translates to:
  /// **'按本行单位填写本次实到数量。少到、多到都按实物登记；超出批准量的部分进入异常处理，不直接计入可用库存。'**
  String get workflowArrivalQuantityHint;

  /// No description provided for @workflowIqcPassHint.
  ///
  /// In zh, this message translates to:
  /// **'只填本次判定合格的数量，与本次不合格量合计不能超过剩余待检量。品质通过后仍需仓库确认入库。'**
  String get workflowIqcPassHint;

  /// No description provided for @workflowIqcFailHint.
  ///
  /// In zh, this message translates to:
  /// **'只填本次判定不合格的数量。它不会进入可用库存，后续还要处理退回、返工或其它处置。'**
  String get workflowIqcFailHint;

  /// No description provided for @workflowPrepaymentAmountHint.
  ///
  /// In zh, this message translates to:
  /// **'填写本次实际收到的预收款，按订单币种计。登记到账只记一次；以后用预收抵扣应收时不会再次记收款。'**
  String get workflowPrepaymentAmountHint;

  /// No description provided for @workflowReceiptAllocationHint.
  ///
  /// In zh, this message translates to:
  /// **'把本次到账款分配到这张应收单，按应收币种填写，不能超过当前可收余额。同一笔到账款不要重复分配。'**
  String get workflowReceiptAllocationHint;

  /// No description provided for @workflowBankFeeHint.
  ///
  /// In zh, this message translates to:
  /// **'填写本次实际银行手续费。到账中已经扣除的费用，不要再作为另付费用重复登记。'**
  String get workflowBankFeeHint;

  /// No description provided for @workflowOtherFeeHint.
  ///
  /// In zh, this message translates to:
  /// **'只填写银行手续费以外的本次费用，并选择对应费用项目；同一笔费用不要重复记录。'**
  String get workflowOtherFeeHint;

  /// No description provided for @workflowReturnReasonHint.
  ///
  /// In zh, this message translates to:
  /// **'写清退货原因和原出货来源。审核退货会形成待处理贷项，实物先待检；退款、换货等客户处理方案须另行确认。'**
  String get workflowReturnReasonHint;

  /// No description provided for @workflowPrepaymentOrderHint.
  ///
  /// In zh, this message translates to:
  /// **'先选这笔预收所属的销售订单，客户和币种会随订单确定；选错时请更换订单。'**
  String get workflowPrepaymentOrderHint;

  /// No description provided for @workflowPrepaymentApplyHint.
  ///
  /// In zh, this message translates to:
  /// **'说明用哪笔预收抵扣哪些欠款及依据。抵扣只调整预收和应收余额，不会再次增加实收现金。'**
  String get workflowPrepaymentApplyHint;

  /// No description provided for @workflowFinanceReviewHint.
  ///
  /// In zh, this message translates to:
  /// **'写下核对结果；订单有修改时先对照修改前后内容。财务确认不等于已经收款、出货或开工。'**
  String get workflowFinanceReviewHint;

  /// No description provided for @workflowFinanceRejectHint.
  ///
  /// In zh, this message translates to:
  /// **'写明哪里不对、需要怎样修改。原因会通知销售，修改后再送财务审核。'**
  String get workflowFinanceRejectHint;

  /// No description provided for @workflowOptionalDetails.
  ///
  /// In zh, this message translates to:
  /// **'补充信息(选填)'**
  String get workflowOptionalDetails;

  /// No description provided for @workflowReceiptEvidence.
  ///
  /// In zh, this message translates to:
  /// **'汇率与到账凭证'**
  String get workflowReceiptEvidence;

  /// No description provided for @workflowReceiptNoFees.
  ///
  /// In zh, this message translates to:
  /// **'没有手续费，无需再填费用明细'**
  String get workflowReceiptNoFees;

  /// No description provided for @workflowUnitUnknown.
  ///
  /// In zh, this message translates to:
  /// **'验收单位待核对'**
  String get workflowUnitUnknown;

  /// No description provided for @workflowIqcUnitHint.
  ///
  /// In zh, this message translates to:
  /// **'原单1{sourceUnit} = {rate}{baseUnit}；这里按{baseUnit}验收，不要把原单包装数直接填进来。'**
  String workflowIqcUnitHint(String sourceUnit, String rate, String baseUnit);

  /// No description provided for @moneySummaryCustomerPaid.
  ///
  /// In zh, this message translates to:
  /// **'客户已付'**
  String get moneySummaryCustomerPaid;

  /// No description provided for @moneySummaryGrossShipped.
  ///
  /// In zh, this message translates to:
  /// **'已发货金额'**
  String get moneySummaryGrossShipped;

  /// No description provided for @moneySummaryReturned.
  ///
  /// In zh, this message translates to:
  /// **'退货金额'**
  String get moneySummaryReturned;

  /// No description provided for @moneySummaryUnusedReturns.
  ///
  /// In zh, this message translates to:
  /// **'尚未处理的退货金额'**
  String get moneySummaryUnusedReturns;

  /// No description provided for @moneySummaryNetReceivable.
  ///
  /// In zh, this message translates to:
  /// **'当前还需收款'**
  String get moneySummaryNetReceivable;

  /// No description provided for @moneySummaryPendingBalance.
  ///
  /// In zh, this message translates to:
  /// **'客户待处理余额'**
  String get moneySummaryPendingBalance;

  /// No description provided for @moneySummaryFutureShipment.
  ///
  /// In zh, this message translates to:
  /// **'后续发货金额'**
  String get moneySummaryFutureShipment;

  /// No description provided for @moneySummaryExpectedNewCash.
  ///
  /// In zh, this message translates to:
  /// **'预计还需新收'**
  String get moneySummaryExpectedNewCash;

  /// No description provided for @moneySummaryBalanceHint.
  ///
  /// In zh, this message translates to:
  /// **'待处理余额需财务确认抵扣或退款，不表示已退款。'**
  String get moneySummaryBalanceHint;

  /// No description provided for @moneySummaryCollectionHint.
  ///
  /// In zh, this message translates to:
  /// **'按当前应收、后续发货及未使用预收估算，不会自动抵扣或退款。'**
  String get moneySummaryCollectionHint;

  /// No description provided for @moneySummarySourceHint.
  ///
  /// In zh, this message translates to:
  /// **'金额来自已审核单据。客户已付可能含代扣费用，银行实际到账以账户流水为准。'**
  String get moneySummarySourceHint;

  /// No description provided for @moneySummaryUnallocatedHint.
  ///
  /// In zh, this message translates to:
  /// **'部分付款尚未对应到订单，请财务核对。'**
  String get moneySummaryUnallocatedHint;

  /// No description provided for @warehouseArrivalSourceLabel.
  ///
  /// In zh, this message translates to:
  /// **'到货来源'**
  String get warehouseArrivalSourceLabel;

  /// No description provided for @warehouseArrivalSourceAutomatic.
  ///
  /// In zh, this message translates to:
  /// **'自动识别'**
  String get warehouseArrivalSourceAutomatic;

  /// No description provided for @warehouseArrivalSourceNormal.
  ///
  /// In zh, this message translates to:
  /// **'正常到货'**
  String get warehouseArrivalSourceNormal;

  /// No description provided for @warehouseArrivalSourceReplacement.
  ///
  /// In zh, this message translates to:
  /// **'先补退货'**
  String get warehouseArrivalSourceReplacement;

  /// No description provided for @warehouseArrivalSourceHint.
  ///
  /// In zh, this message translates to:
  /// **'只有一种待收来源时，系统自动识别。同时有正常待到货和已退未补数量时，请按这批实物选择。选“先补退货”会先补回已退数量，超出的部分按正常到货处理；免费补回或重新计款由原退货处理结果决定。'**
  String get warehouseArrivalSourceHint;

  /// No description provided for @subcontractPreparationWarehouse.
  ///
  /// In zh, this message translates to:
  /// **'内部生产入库仓库'**
  String get subcontractPreparationWarehouse;

  /// No description provided for @subcontractPreparationWarehouseHint.
  ///
  /// In zh, this message translates to:
  /// **'直接下单的委外件有子件且现货不够时，需要先选内部生产的入库仓库。系统把缺口交给计划部，做好并实际入库后才能提交财务；没有子件或现货足够时可不选。'**
  String get subcontractPreparationWarehouseHint;

  /// No description provided for @subcontractInternalProduction.
  ///
  /// In zh, this message translates to:
  /// **'内部生产'**
  String get subcontractInternalProduction;

  /// No description provided for @subcontractPreparedQuantity.
  ///
  /// In zh, this message translates to:
  /// **'已备齐'**
  String get subcontractPreparedQuantity;

  /// No description provided for @subcontractPreparationShortage.
  ///
  /// In zh, this message translates to:
  /// **'还需生产'**
  String get subcontractPreparationShortage;

  /// No description provided for @subcontractOpenPreparation.
  ///
  /// In zh, this message translates to:
  /// **'查看生产安排'**
  String get subcontractOpenPreparation;

  /// No description provided for @subcontractDraftPreparationHint.
  ///
  /// In zh, this message translates to:
  /// **'先由计划安排内部生产，备齐入库后再提交财务。'**
  String get subcontractDraftPreparationHint;

  /// No description provided for @subcontractWaitingPlan.
  ///
  /// In zh, this message translates to:
  /// **'等待计划安排'**
  String get subcontractWaitingPlan;

  /// No description provided for @subcontractReadyForFinance.
  ///
  /// In zh, this message translates to:
  /// **'已备齐，可提交财务'**
  String get subcontractReadyForFinance;

  /// No description provided for @materialIssuedPlanSyncPending.
  ///
  /// In zh, this message translates to:
  /// **'已下达，计划进度待同步'**
  String get materialIssuedPlanSyncPending;

  /// No description provided for @subcontractOrderBlockedProducing.
  ///
  /// In zh, this message translates to:
  /// **'正在生产，暂时不能下委外单'**
  String get subcontractOrderBlockedProducing;

  /// No description provided for @subcontractOrderBlockedPreparation.
  ///
  /// In zh, this message translates to:
  /// **'前置生产尚未完成，暂时不能下委外单'**
  String get subcontractOrderBlockedPreparation;

  /// No description provided for @subcontractOrderBlockedNotification.
  ///
  /// In zh, this message translates to:
  /// **'前置生产已完成，请先通知委外后再下单'**
  String get subcontractOrderBlockedNotification;

  /// No description provided for @subcontractOrderBlockedCancelled.
  ///
  /// In zh, this message translates to:
  /// **'生产任务已取消，暂时不能下委外单'**
  String get subcontractOrderBlockedCancelled;

  /// No description provided for @subcontractPlanIssuedDate.
  ///
  /// In zh, this message translates to:
  /// **'计划下达日期'**
  String get subcontractPlanIssuedDate;

  /// No description provided for @subcontractPlanIssuedDateHint.
  ///
  /// In zh, this message translates to:
  /// **'计划部门首次下达这项委外任务的日期'**
  String get subcontractPlanIssuedDateHint;

  /// No description provided for @subcontractOrderBlockedRefresh.
  ///
  /// In zh, this message translates to:
  /// **'已通知委外，请刷新任务列表后下单'**
  String get subcontractOrderBlockedRefresh;

  /// No description provided for @serverStatusTitle.
  ///
  /// In zh, this message translates to:
  /// **'服务器状态'**
  String get serverStatusTitle;

  /// No description provided for @serverStatusRefresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新'**
  String get serverStatusRefresh;

  /// No description provided for @serverStatusAccessRequired.
  ///
  /// In zh, this message translates to:
  /// **'没有服务器状态查看权限'**
  String get serverStatusAccessRequired;

  /// No description provided for @serverStatusResources.
  ///
  /// In zh, this message translates to:
  /// **'运行资源'**
  String get serverStatusResources;

  /// No description provided for @serverStatusStorage.
  ///
  /// In zh, this message translates to:
  /// **'磁盘空间'**
  String get serverStatusStorage;

  /// No description provided for @serverStatusDataProtection.
  ///
  /// In zh, this message translates to:
  /// **'数据库与备份'**
  String get serverStatusDataProtection;

  /// No description provided for @serverStatusOverview.
  ///
  /// In zh, this message translates to:
  /// **'运行总览'**
  String get serverStatusOverview;

  /// No description provided for @serverStatusOverviewHint.
  ///
  /// In zh, this message translates to:
  /// **'根据服务器最近一次采集的数据展示运行情况。'**
  String get serverStatusOverviewHint;

  /// No description provided for @serverStatusCollecting.
  ///
  /// In zh, this message translates to:
  /// **'正在等待服务器采集运行数据。'**
  String get serverStatusCollecting;

  /// No description provided for @serverStatusStale.
  ///
  /// In zh, this message translates to:
  /// **'数据已过期，正在等待新的采集结果。'**
  String get serverStatusStale;

  /// No description provided for @serverStatusRefreshFailed.
  ///
  /// In zh, this message translates to:
  /// **'暂时无法更新。上次数据仅供参考，请稍后刷新。'**
  String get serverStatusRefreshFailed;

  /// No description provided for @serverStatusUpdatedAt.
  ///
  /// In zh, this message translates to:
  /// **'采集时间'**
  String get serverStatusUpdatedAt;

  /// No description provided for @serverStatusEnvironment.
  ///
  /// In zh, this message translates to:
  /// **'运行环境'**
  String get serverStatusEnvironment;

  /// No description provided for @serverStatusVersion.
  ///
  /// In zh, this message translates to:
  /// **'应用版本'**
  String get serverStatusVersion;

  /// No description provided for @serverStatusUptime.
  ///
  /// In zh, this message translates to:
  /// **'已运行'**
  String get serverStatusUptime;

  /// No description provided for @serverStatusPolling.
  ///
  /// In zh, this message translates to:
  /// **'每 {seconds} 秒自动刷新，离开页面后暂停'**
  String serverStatusPolling(int seconds);

  /// No description provided for @serverStatusCpu.
  ///
  /// In zh, this message translates to:
  /// **'处理器(CPU)'**
  String get serverStatusCpu;

  /// No description provided for @serverStatusMemory.
  ///
  /// In zh, this message translates to:
  /// **'系统内存'**
  String get serverStatusMemory;

  /// No description provided for @serverStatusAppMemory.
  ///
  /// In zh, this message translates to:
  /// **'应用内存'**
  String get serverStatusAppMemory;

  /// No description provided for @serverStatusDbPool.
  ///
  /// In zh, this message translates to:
  /// **'数据库连接池'**
  String get serverStatusDbPool;

  /// No description provided for @serverStatusDisk.
  ///
  /// In zh, this message translates to:
  /// **'磁盘'**
  String get serverStatusDisk;

  /// No description provided for @serverStatusUsed.
  ///
  /// In zh, this message translates to:
  /// **'已使用'**
  String get serverStatusUsed;

  /// No description provided for @serverStatusFree.
  ///
  /// In zh, this message translates to:
  /// **'可用空间'**
  String get serverStatusFree;

  /// No description provided for @serverStatusCapacity.
  ///
  /// In zh, this message translates to:
  /// **'总容量'**
  String get serverStatusCapacity;

  /// No description provided for @serverStatusDatabase.
  ///
  /// In zh, this message translates to:
  /// **'数据库'**
  String get serverStatusDatabase;

  /// No description provided for @serverStatusDatabaseHint.
  ///
  /// In zh, this message translates to:
  /// **'查看数据库是否能够响应，以及当前连接数量。'**
  String get serverStatusDatabaseHint;

  /// No description provided for @serverStatusResponse.
  ///
  /// In zh, this message translates to:
  /// **'响应耗时'**
  String get serverStatusResponse;

  /// No description provided for @serverStatusConnections.
  ///
  /// In zh, this message translates to:
  /// **'当前 / 最大连接数'**
  String get serverStatusConnections;

  /// No description provided for @serverStatusBackup.
  ///
  /// In zh, this message translates to:
  /// **'最近备份'**
  String get serverStatusBackup;

  /// No description provided for @serverStatusHours.
  ///
  /// In zh, this message translates to:
  /// **'小时'**
  String get serverStatusHours;

  /// No description provided for @serverStatusLastBackup.
  ///
  /// In zh, this message translates to:
  /// **'最近成功时间'**
  String get serverStatusLastBackup;

  /// No description provided for @serverStatusAttention.
  ///
  /// In zh, this message translates to:
  /// **'需要留意'**
  String get serverStatusAttention;

  /// No description provided for @serverStatusNotCollected.
  ///
  /// In zh, this message translates to:
  /// **'尚未采集到这项数据'**
  String get serverStatusNotCollected;

  /// No description provided for @serverStatusUptimeValue.
  ///
  /// In zh, this message translates to:
  /// **'{days}天 {hours}小时 {minutes}分钟'**
  String serverStatusUptimeValue(int days, int hours, int minutes);

  /// No description provided for @serverStatusThresholdUnknown.
  ///
  /// In zh, this message translates to:
  /// **'暂无可用提醒阈值'**
  String get serverStatusThresholdUnknown;

  /// No description provided for @serverStatusThresholds.
  ///
  /// In zh, this message translates to:
  /// **'黄色提醒 ≥ {warning}；红色告警 ≥ {critical}'**
  String serverStatusThresholds(String warning, String critical);

  /// No description provided for @serverStatusNormal.
  ///
  /// In zh, this message translates to:
  /// **'正常'**
  String get serverStatusNormal;

  /// No description provided for @serverStatusWarning.
  ///
  /// In zh, this message translates to:
  /// **'留意'**
  String get serverStatusWarning;

  /// No description provided for @serverStatusCritical.
  ///
  /// In zh, this message translates to:
  /// **'需处理'**
  String get serverStatusCritical;

  /// No description provided for @serverStatusUnknown.
  ///
  /// In zh, this message translates to:
  /// **'未知'**
  String get serverStatusUnknown;

  /// No description provided for @attachmentUploadFormatsHint.
  ///
  /// In zh, this message translates to:
  /// **'支持图片 / PDF / Office / zip / txt，单个不超过 25MB'**
  String get attachmentUploadFormatsHint;

  /// No description provided for @attachmentUploadedFile.
  ///
  /// In zh, this message translates to:
  /// **'已上传 {fileName}'**
  String attachmentUploadedFile(String fileName);

  /// No description provided for @attachmentUploadedFiles.
  ///
  /// In zh, this message translates to:
  /// **'已上传 {count} 个文件'**
  String attachmentUploadedFiles(int count);

  /// No description provided for @productionMaterialRecheckHelp.
  ///
  /// In zh, this message translates to:
  /// **'重新核对本任务已合格到货和可用库存；不能代替仓库入库或登记实耗。'**
  String get productionMaterialRecheckHelp;

  /// No description provided for @productionMaterialRegisterUsage.
  ///
  /// In zh, this message translates to:
  /// **'登记实际用料'**
  String get productionMaterialRegisterUsage;

  /// No description provided for @productionMaterialViewUsage.
  ///
  /// In zh, this message translates to:
  /// **'查看用料记录'**
  String get productionMaterialViewUsage;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ko', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ko':
      return AppLocalizationsKo();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
