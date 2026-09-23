// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Uten Integrated Management Platform';

  @override
  String get commonConfirm => 'Confirm';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonSave => 'Save';

  @override
  String get commonRefresh => 'Refresh';

  @override
  String get commonRetry => 'Retry';

  @override
  String get connectionReconnecting => 'The network is unstable. Reconnecting…';

  @override
  String get connectionDisconnected =>
      'The server is temporarily unavailable. Reconnecting automatically';

  @override
  String get connectionRestored => 'Connection restored. You can continue.';

  @override
  String get connectionRetryNow => 'Retry now';

  @override
  String get commonBack => 'Back';

  @override
  String get commonLoading => 'Loading…';

  @override
  String get commonNoData => 'No data';

  @override
  String get commonError => 'Something went wrong, please try again';

  @override
  String get commonSuccess => 'Success';

  @override
  String get loginAccountHint => 'Employee code or phone number';

  @override
  String get loginAccountRequired => 'Please enter your account';

  @override
  String get loginPasswordHint => 'Enter your password';

  @override
  String get loginPasswordRequired => 'Please enter your password';

  @override
  String get loginButton => 'Sign In';

  @override
  String get loginLoggingIn => 'Signing in…';

  @override
  String get loginServerRecoveryAction => 'Restore automatic server selection';

  @override
  String get loginServerRecoveryHint =>
      'Use this after changing networks or if sign-in fails. Only the trusted office and cloud addresses built into this app are used.';

  @override
  String get loginServerRecoverySuccess =>
      'Automatic server selection restored. Please sign in again.';

  @override
  String get loginServerRecoveryFailed =>
      'Could not restore server selection. Try again or contact an administrator.';

  @override
  String loginFooter(int year) {
    return '© $year Uten Integrated Management Platform';
  }

  @override
  String get navDashboard => 'Dashboard';

  @override
  String get navNotice => 'Notices';

  @override
  String get navProfile => 'Me';

  @override
  String get navSettings => 'Settings';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsSectionAppearance => 'Appearance';

  @override
  String get settingsThemeMode => 'Theme mode';

  @override
  String get settingsLanguage => 'Language';

  @override
  String get settingsFontSize => 'Font size';

  @override
  String get settingsFontSizeHint =>
      'Scales the whole interface together (text, icons, cards, spacing); phones scale text only';

  @override
  String get settingsSectionPerformance => 'Performance';

  @override
  String get settingsPerformanceTier => 'Performance mode';

  @override
  String get settingsPerformanceHint => 'Choose Lite for low-end devices';

  @override
  String get settingsSectionAbout => 'About';

  @override
  String get settingsVersion => 'Version';

  @override
  String get settingsLogout => 'Sign out';

  @override
  String get settingsLogoutConfirm => 'Are you sure you want to sign out?';

  @override
  String get profileChangePassword => 'Change password';

  @override
  String get entryStaff => 'Staff Sign In';

  @override
  String get entryVisitor => 'Visitor Sign In';

  @override
  String get visitorLoginTitle => 'Visitor Sign In';

  @override
  String get visitorLoginSubtitle => 'Enter your phone to get a code';

  @override
  String get visitorPhoneLabel => 'Phone';

  @override
  String get visitorPhoneHint => 'Enter your phone number';

  @override
  String get visitorCodeLabel => 'Code';

  @override
  String get visitorCodeHint => 'Enter the verification code';

  @override
  String get visitorCodeRequired => 'Please enter the verification code';

  @override
  String get visitorGetCode => 'Get code';

  @override
  String visitorCodeCountdown(Object seconds) {
    return 'Resend in ${seconds}s';
  }

  @override
  String get visitorLoginButton => 'Sign In';

  @override
  String get visitorLoggingIn => 'Signing in…';

  @override
  String visitorCodeSentDev(Object code) {
    return 'Code: $code (dev)';
  }

  @override
  String get visitorIsEmployee =>
      'This phone is a Uten employee account, please use staff sign in';

  @override
  String get visitorPhoneInvalid => 'Please enter a valid phone number';

  @override
  String get visitorHomeTitle => 'My Appointments';

  @override
  String get visitorSettingsTitle => 'Visitor Settings';

  @override
  String get visitorSettingsTooltip => 'Settings';

  @override
  String get visitorApplyNew => 'New Visit';

  @override
  String get visitorFilterAll => 'All';

  @override
  String get visitorFilterPending => 'Pending';

  @override
  String get visitorFilterApproved => 'Approved';

  @override
  String get visitorFilterRejected => 'Rejected';

  @override
  String get visitorApplyTitle => 'Visit Appointment';

  @override
  String get visitorApplyName => 'Name';

  @override
  String get visitorApplyNameHint => 'Enter your full name';

  @override
  String get visitorApplyIdCard => 'ID Number';

  @override
  String get visitorApplyIdCardHint => 'Optional';

  @override
  String get visitorApplyCompany => 'Company';

  @override
  String get visitorApplyCompanyHint => 'Optional';

  @override
  String get visitorApplyPurpose => 'Purpose';

  @override
  String get visitorApplyPurposeHint => 'State your visit purpose';

  @override
  String get visitorApplyVehicle => 'Driving';

  @override
  String get visitorApplyPlate => 'Plate No.';

  @override
  String get visitorApplyPlateHint => 'Enter plate number';

  @override
  String get visitorApplyHost => 'Host';

  @override
  String get visitorApplyVisitTime => 'Planned visit time';

  @override
  String get visitorApplySubmit => 'Submit';

  @override
  String get visitorApplySubmitting => 'Submitting…';

  @override
  String get visitorApplyValidateName => 'Please enter your name';

  @override
  String get visitorApplyValidateIdCard =>
      'Please enter a valid 18-digit resident ID number';

  @override
  String get visitorApplyValidatePurpose => 'Please fill in the purpose';

  @override
  String get visitorApplyValidateHost => 'Please select a host';

  @override
  String get visitorApplyValidateVisitTime => 'Please select visit time';

  @override
  String get visitorApplyValidateVisitTimeFuture =>
      'Visit time must be later than now';

  @override
  String get visitorApplyValidatePlate =>
      'Plate number is required when visiting by car';

  @override
  String get visitorApplyDuplicateTime =>
      'You already have an active visit at this time';

  @override
  String get visitorApplySuccess => 'Submitted, awaiting approval';

  @override
  String get visitorStatusPending => 'Pending';

  @override
  String get visitorStatusHostReviewing => 'Awaiting host confirm';

  @override
  String get visitorStatusApproved => 'Approved';

  @override
  String get visitorStatusRejected => 'Rejected';

  @override
  String get visitorStatusCheckedIn => 'Checked in';

  @override
  String get visitorStatusCancelled => 'Cancelled';

  @override
  String get visitorDetailTitle => 'Appointment Detail';

  @override
  String get visitorDetailHost => 'Host';

  @override
  String get visitorDetailPurpose => 'Purpose';

  @override
  String get visitorDetailVisitTime => 'Visit time';

  @override
  String get visitorDetailAppliedAt => 'Submitted';

  @override
  String get visitorDetailApprovedAt => 'Approved';

  @override
  String get visitorDetailRejectReason => 'Reject reason';

  @override
  String get visitorDetailQr => 'Entry Pass';

  @override
  String get visitorDetailQrHint => 'Show this QR to the security guard';

  @override
  String get visitorDetailTimeline => 'Timeline';

  @override
  String get visitorLogout => 'Sign out';

  @override
  String get visitorApprovalTitle => 'Visitor Approval';

  @override
  String get visitorApprovalPending => 'Pending';

  @override
  String get visitorApprovalApprove => 'Approve';

  @override
  String get visitorApprovalReject => 'Reject';

  @override
  String get visitorApprovalForward => 'Forward to host';

  @override
  String get visitorApprovalRejectReasonHint => 'Optional';

  @override
  String get visitorApprovalConfirmApprove => 'Approve this visitor?';

  @override
  String get visitorApprovalEmpty => 'No visitors to approve';

  @override
  String get myVisitorsTitle => 'My Visitors';

  @override
  String get myVisitorsEmpty => 'No visitors need your confirmation';

  @override
  String get myVisitorsConfirm => 'Accept';

  @override
  String get myVisitorsReject => 'Decline';

  @override
  String get securityTitle => 'Visitor Check';

  @override
  String get securityScanHint => 'Point the visitor QR at the frame';

  @override
  String get securityScanManual => 'Enter code manually';

  @override
  String get securityPasscodeHint => 'Enter the 6-digit pass code';

  @override
  String get securityPasscodeInvalid =>
      'Please enter the 6-digit numeric pass code';

  @override
  String get visitorPasscodeLabel => 'Pass code';

  @override
  String get securityPass => 'Allow entry';

  @override
  String get securityReject => 'Deny entry';

  @override
  String get securityReasonOk => 'Valid pass';

  @override
  String get securityReasonInvalid => 'Invalid QR';

  @override
  String get securityReasonExpired => 'Pass expired';

  @override
  String get securityReasonUsed => 'Pass already used';

  @override
  String get securityReasonRejected => 'Visitor rejected';

  @override
  String get securityCheckIn => 'Check in';

  @override
  String get securityCheckInDone => 'Checked in';

  @override
  String get securityVisitor => 'Visitor';

  @override
  String get securityPurpose => 'Purpose';

  @override
  String get securityHost => 'Host';

  @override
  String get securityPlate => 'Plate';

  @override
  String get securityVisitTime => 'Visit time';

  @override
  String get employeeTitle => 'Employees';

  @override
  String get employeeFabOnboard => 'Onboard';

  @override
  String get employeeSearchHint => 'Search by code, name or plate';

  @override
  String get employeeEmpty => 'No employees yet';

  @override
  String get employeeDetailTitle => 'Employee Detail';

  @override
  String get employeeDetailBasic => 'Basic info';

  @override
  String get employeeDetailOrg => 'Organization';

  @override
  String get employeeDetailContract => 'Contract & Pay (role-restricted)';

  @override
  String get employeeDetailEmergency => 'Emergency contacts';

  @override
  String get employeeDetailHistory => 'Employment history';

  @override
  String get employeeFieldCode => 'Employee code';

  @override
  String get employeeFieldName => 'Full name';

  @override
  String get employeeFieldGender => 'Gender';

  @override
  String get employeeFieldIdType => 'ID type';

  @override
  String get employeeFieldIdNumber => 'ID number';

  @override
  String get employeeFieldBirthDate => 'Date of birth';

  @override
  String get employeeFieldEthnicity => 'Ethnicity';

  @override
  String get employeeFieldPoliticalStatus => 'Political status';

  @override
  String get employeeFieldMaritalStatus => 'Marital status';

  @override
  String get employeeFieldPhone => 'Mobile';

  @override
  String get employeeFieldOfficePhone => 'Office phone';

  @override
  String get employeeFieldEmail => 'Company email';

  @override
  String get employeeFieldHujiAddress => 'Hukou address';

  @override
  String get employeeFieldResidenceAddress => 'Current address';

  @override
  String get employeeFieldDepartment => 'Department';

  @override
  String get employeeFieldPosition => 'Position';

  @override
  String get employeeFieldSupervisor => 'Supervisor';

  @override
  String get employeeFieldHireDate => 'Hire date';

  @override
  String get employeeFieldWorkYears => 'Seniority';

  @override
  String employeeWorkYearsYandM(int years, int months) {
    return '$years yr $months mo';
  }

  @override
  String employeeWorkYearsMonths(int months) {
    return '$months mo';
  }

  @override
  String get employeeWorkYearsUnderOneMonth => 'Under 1 month';

  @override
  String get employeeFieldConfirmedDate => 'Confirmed date';

  @override
  String get employeeFieldStatus => 'Status';

  @override
  String get employeeFieldEmploymentType => 'Employment type';

  @override
  String get employeeFieldWorkLocation => 'Work location';

  @override
  String get employeeFieldSeatNo => 'Seat';

  @override
  String get employeeFieldContractType => 'Contract type';

  @override
  String get employeeFieldContractPeriod => 'Contract period';

  @override
  String get employeeFieldProbation => 'Probation';

  @override
  String get employeeFieldRenewCount => 'Renewals';

  @override
  String get employeeFieldBaseSalary => 'Base salary';

  @override
  String get employeeFieldPerfSalary => 'Bonus/Allowance';

  @override
  String get employeeFieldSocialBase => 'Social base';

  @override
  String get employeeFieldHousingBase => 'Housing fund base';

  @override
  String get employeeFieldBankBranch => 'Bank branch';

  @override
  String get employeeFieldBankAccount => 'Bank account';

  @override
  String employeeContractPeriodValue(Object end, Object start) {
    return '$start ~ $end';
  }

  @override
  String employeeProbationValue(Object end, Object months) {
    return '$months months (until $end)';
  }

  @override
  String employeeRenewCountValue(Object count) {
    return '$count';
  }

  @override
  String get employeeFieldAccountStatus => 'Login account';

  @override
  String get accountStatusActive => 'Active';

  @override
  String get accountStatusLocked => 'Locked';

  @override
  String get accountStatusDisabled => 'Disabled';

  @override
  String get accountStatusNone => 'Not provisioned';

  @override
  String employeeProbationExpiring(Object date, Object days) {
    return 'Probation ends on $date ($days days left) — confirm employment in time';
  }

  @override
  String employeeProbationExpired(Object date) {
    return 'Probation ended on $date — please confirm employment or offboard';
  }

  @override
  String employeeContractExpiring(Object date, Object days) {
    return 'Contract ends on $date ($days days left) — please renew in time';
  }

  @override
  String employeeContractExpired(Object date) {
    return 'Contract expired on $date — please handle it';
  }

  @override
  String get employeeEditTitle => 'Edit employee';

  @override
  String get employeeEditBasic => 'Basic info';

  @override
  String get employeeEditOrg => 'Organization';

  @override
  String get employeeEditContact => 'Contact';

  @override
  String get employeeEditSalary => 'Salary & Bank';

  @override
  String get employeeEditSaved => 'Saved';

  @override
  String get employeeEditSaveFailed => 'Save failed, please try again';

  @override
  String employeeEditLoadFailed(Object error) {
    return 'Failed to load: $error';
  }

  @override
  String get employeeEditRequired => 'Required';

  @override
  String get employeeOnboardTitle => 'New Employee Onboarding';

  @override
  String get employeeOnboardGroupProfile => 'Profile';

  @override
  String get employeeOnboardGroupOrg => 'Organization';

  @override
  String get employeeOnboardGroupPay => 'Pay & Bank (optional, HR/admin only)';

  @override
  String get employeeOnboardSubmit => 'Submit Onboarding';

  @override
  String get employeeOnboardSuccess =>
      'Onboarding completed and the one-time password was delivered';

  @override
  String get employeeOnboardSubmitFailed => 'Submit failed, please try again';

  @override
  String get employeeOnboardNote =>
      'Submitting auto-generates the employee code (UT prefix), uses the phone number as the login account, and issues a random one-time password (shown once, time-limited). It must be changed at first sign-in.';

  @override
  String get employeeOnboardCodeAutoNote =>
      'Employee code is auto-generated on submit (UT prefix, unique and incremental)';

  @override
  String get positionPickerTitle => 'Select or enter a position';

  @override
  String get positionPickerHint => 'Select or enter a position';

  @override
  String get positionPickerDepartmentFirst => 'Select a department first';

  @override
  String get positionPickerSearchHint =>
      'Search by position name, code, or level';

  @override
  String positionPickerUseCustom(Object name) {
    return 'Use “$name” as a new position';
  }

  @override
  String get positionPickerCustomDescription =>
      'It will be saved under the selected department after confirmation';

  @override
  String get positionPickerNoPositions =>
      'This department has no positions; enter a new one directly';

  @override
  String get positionPickerLoadFailed =>
      'Positions could not be loaded; retry or enter a new one directly';

  @override
  String get positionPickerClear => 'Clear';

  @override
  String get employeeOnboardCredentialTitle => 'Account created';

  @override
  String get employeeOnboardCredentialWarning =>
      'This temporary password is shown only once. Deliver it securely now; the plaintext cannot be retrieved after closing.';

  @override
  String get employeeOnboardAccountLabel => 'Login account';

  @override
  String get employeeOnboardTemporaryPasswordLabel =>
      'One-time temporary password';

  @override
  String get employeeOnboardCopyTemporaryPassword => 'Copy password';

  @override
  String get employeeOnboardTemporaryPasswordCopied =>
      'Temporary password copied';

  @override
  String get employeeOnboardCredentialSaved => 'I saved it securely';

  @override
  String get employeeOnboardHintName => 'Full name';

  @override
  String get employeeOnboardHintIdNumber => 'Enter ID number';

  @override
  String get employeeOnboardIdNumberInvalid => 'Invalid ID number format';

  @override
  String get employeeOnboardHintPhone => '11-digit phone';

  @override
  String get employeeOnboardPhoneRequired => 'Phone is required';

  @override
  String get employeeOnboardPhoneInvalid => 'Invalid phone format';

  @override
  String get employeeOnboardEmailOptional => 'Optional';

  @override
  String get employeeOnboardHireDateHint => 'yyyy-MM-dd';

  @override
  String get employeeOnboardPickHireDate => 'Please pick a hire date';

  @override
  String get employeeOnboardPickDepartment => 'Please select a department';

  @override
  String employeeOnboardFieldRequired(Object field) {
    return '$field is required';
  }

  @override
  String get employeeOnboardLoadFailed => 'Failed to load';

  @override
  String get idTypeIdCard => 'ID card';

  @override
  String get idTypePassport => 'Passport';

  @override
  String get idTypeHmtPermit => 'HK/Macao/Taiwan permit';

  @override
  String get idTypeOther => 'Other';

  @override
  String get employeeOffboardLoadFailed => 'Failed to load';

  @override
  String get employeeActionTransfer => 'Transfer';

  @override
  String get employeeActionConfirm => 'Confirm employment';

  @override
  String get employeeActionOffboard => 'Offboard';

  @override
  String get employeeActionRehire => 'Rehire';

  @override
  String get employeeActionProvision => 'Provision login account';

  @override
  String get employeeActionLockAccount => 'Lock account';

  @override
  String get employeeActionUnlockAccount => 'Unlock account';

  @override
  String get employeeLockAccountSuccess => 'Account locked';

  @override
  String get employeeUnlockAccountSuccess => 'Account unlocked';

  @override
  String get employeeProvisionConfirm =>
      'This creates a login account for the employee. The account defaults to the phone number, the initial password is randomly generated (shown once, time-limited), and it must be changed on first login. Continue?';

  @override
  String get employeeTransferTitle => 'Employee transfer';

  @override
  String get employeeTransferFieldDate => 'Effective date';

  @override
  String get employeeTransferFieldRemark => 'Remark';

  @override
  String get employeeTransferSuccess => 'Transfer completed';

  @override
  String get employeeConfirmTitle => 'Confirm regular employment?';

  @override
  String get employeeConfirmBody => 'The employee status will become Active.';

  @override
  String get employeeConfirmSuccess => 'Employment confirmed';

  @override
  String get employeeRehireTitle => 'Confirm rehire?';

  @override
  String get employeeRehireBody =>
      'The employee will become Active again and the login account will be re-enabled. The old password was voided at departure: ask account support to reset it and hand the new temporary password to the employee in person.';

  @override
  String get employeeRehireSuccess => 'Rehired';

  @override
  String get employeeStatusActive => 'Active';

  @override
  String get employeeStatusProbation => 'Probation';

  @override
  String get employeeStatusOnLeave => 'On leave';

  @override
  String get employeeStatusResigned => 'Resigned';

  @override
  String get employeeStatusUnknown => 'Unknown';

  @override
  String get genderMale => 'Male';

  @override
  String get genderFemale => 'Female';

  @override
  String get employmentTypeRegular => 'Regular';

  @override
  String get employmentTypeDispatch => 'Dispatch';

  @override
  String get employmentTypeIntern => 'Intern';

  @override
  String get employmentTypeOutsource => 'Outsource';

  @override
  String get contractTypeFixed => 'Fixed-term';

  @override
  String get contractTypeOpen => 'Open-ended';

  @override
  String get contractTypeTask => 'Task-based';

  @override
  String get contractTypeIntern => 'Intern';

  @override
  String get historyEventOnboard => 'Onboard';

  @override
  String get historyEventTransfer => 'Transfer';

  @override
  String get historyEventResign => 'Resign';

  @override
  String get historyEventRehire => 'Rehire';

  @override
  String get departmentTitle => 'Departments';

  @override
  String get departmentEmpty => 'Select a department';

  @override
  String get departmentEmptyHint => 'Tap the icon to open the org tree';

  @override
  String get departmentEmptySelect => 'Pick a department on the left';

  @override
  String get departmentTooltipRefresh => 'Refresh';

  @override
  String get departmentTooltipTree => 'Tree';

  @override
  String get departmentDialogDeleteTitle => 'Delete department';

  @override
  String get departmentCreate => 'Create';

  @override
  String get departmentDelete => 'Delete';

  @override
  String get departmentCreated => 'Created';

  @override
  String get departmentDeleted => 'Deleted';

  @override
  String departmentDeleteConfirm(Object name) {
    return 'Delete \"$name\"? Only leaf departments without sub-departments or employees can be removed.';
  }

  @override
  String departmentLevelAndCode(Object level, Object code) {
    return '$level · Code $code';
  }

  @override
  String get departmentEmployeesEmpty =>
      'No employees in this department (or its sub-departments)';

  @override
  String get departmentLoadFailed => 'Failed to load';

  @override
  String get payrollGenerateTitle => 'Payslip Generation';

  @override
  String get payrollStepScope => 'Scope';

  @override
  String get payrollStepItems => 'Pay items';

  @override
  String get payrollStepPreview => 'Preview';

  @override
  String get payrollStepSubmit => 'Submit for review';

  @override
  String get payrollFieldMonth => 'Pay month';

  @override
  String get payrollFieldScope => 'Scope';

  @override
  String get payrollItemOvertime => 'Overtime (+15%)';

  @override
  String get payrollItemBonus => 'Performance bonus (+10%)';

  @override
  String get payrollItemSocial => 'Social & housing (-10.5%)';

  @override
  String get payrollItemTax => 'Income tax (-5%)';

  @override
  String get payrollSubmitNote =>
      'After submission it enters finance review. Once approved, HR releases the slips to employees.';

  @override
  String get payrollSubmitButton => 'Submit for review';

  @override
  String get payrollNext => 'Next';

  @override
  String get payrollBack => 'Back';

  @override
  String get payrollDeptAll => 'All employees';

  @override
  String get noticePublishTitle => 'Publish Notice';

  @override
  String get noticePublishPublishButton => 'Publish';

  @override
  String get noticePublishTopPriority => 'Pin to top';

  @override
  String get noticePublishTitleHint => 'Notice title (required)';

  @override
  String get noticePublishContentHint => 'Notice body…';

  @override
  String get noticePublishScopeTitle => 'Audience';

  @override
  String get noticePublishScopeAll => 'Everyone';

  @override
  String get noticePublishScopeAllHint =>
      'Notify every employee in the company';

  @override
  String get noticePublishValidateTitle => 'Please enter a title';

  @override
  String get noticePublishValidateContent => 'Please enter the body';

  @override
  String get noticePublishConfirmTitle => 'Confirm publish?';

  @override
  String get noticePublishConfirmBodyAll => 'Notify all employees';

  @override
  String get noticePublishPublished => 'Notice published';

  @override
  String get noticePublishPublishing => 'Publishing…';

  @override
  String get noticePublishContentSection => 'Notice content';

  @override
  String get noticePublishTypeLabel => 'Notice type';

  @override
  String get noticePublishTitleLabel => 'Title';

  @override
  String get noticePublishContentLabel => 'Body';

  @override
  String get noticePublishUrgentHint =>
      'Urgent notices use a high-priority alert. Use this only for items requiring immediate attention.';

  @override
  String get noticePublishTopPriorityHint =>
      'Pinned notices appear first and alert recipients as important.';

  @override
  String get noticePublishScopeSelected => 'Selected audience';

  @override
  String get noticePublishScopeSelectedHint =>
      'Departments and people can be combined. Departments include descendants and duplicate recipients are removed.';

  @override
  String get noticePublishDepartmentsLabel => 'Departments (multiple)';

  @override
  String get noticePublishDepartmentsHint => 'Choose one or more departments';

  @override
  String get noticePublishEmployeesLabel => 'Add individual people';

  @override
  String get noticePublishEmployeesHint => 'Choose specific people (multiple)';

  @override
  String get noticePublishEmployeePickerTitle => 'Choose recipients';

  @override
  String get noticePublishEmployeeSearchHint => 'Search name / employee code';

  @override
  String get noticePublishEmployeeEmpty => 'No active recipient account found';

  @override
  String noticePublishEmployeeSelectedCount(int count) {
    return '$count selected';
  }

  @override
  String get noticePublishEmployeeClear => 'Clear';

  @override
  String get noticePublishEmployeeConfirm => 'Done';

  @override
  String get noticePublishValidateAudience =>
      'Choose at least one department or person';

  @override
  String noticePublishAudienceSummary(
    Object departmentCount,
    Object employeeCount,
  ) {
    return '$departmentCount departments and $employeeCount people selected';
  }

  @override
  String get noticePublishAudienceRecalculateHint =>
      'The server recalculates the actual recipient count from the current organisation and account status before publishing.';

  @override
  String noticePublishConfirmAudience(Object summary, Object count) {
    return 'Send to $summary; $count actual recipients.';
  }

  @override
  String noticePublishPublishedTo(Object count) {
    return 'Notice published to $count people';
  }

  @override
  String get noticeTypeAnnouncement => 'Announcement';

  @override
  String get noticeTypePolicy => 'Policy';

  @override
  String get noticeTypeBenefit => 'Benefit';

  @override
  String get noticeTypeSystem => 'System';

  @override
  String get noticeTypeUrgent => 'Urgent';

  @override
  String get noticeTypeBirthday => 'Birthday';

  @override
  String get noticeTypeAnniversary => 'Anniversary';

  @override
  String get noticeTypeWedding => 'Wedding';

  @override
  String get noticeTypeNewborn => 'Newborn';

  @override
  String get noticeTypeAnnouncementDesc =>
      'Company announcement; everyone can tap “Acknowledge”';

  @override
  String get noticeTypePolicyDesc =>
      'Policy release; everyone can tap “Acknowledge”';

  @override
  String get noticeTypeBenefitDesc =>
      'Benefit notice; everyone can tap “Acknowledge”';

  @override
  String get noticeTypeSystemDesc =>
      'System notice; everyone can tap “Acknowledge”';

  @override
  String get noticeTypeUrgentDesc => 'Urgent notice with high-priority alert';

  @override
  String get noticeTypeBirthdayDesc =>
      'Celebrate a birthday; everyone can “Send blessing”';

  @override
  String get noticeTypeAnniversaryDesc =>
      'Work anniversary; everyone can “Send blessing”';

  @override
  String get noticeTypeWeddingDesc =>
      'Wedding blessing; everyone can “Send blessing”';

  @override
  String get noticeTypeNewbornDesc =>
      'Newborn blessing; everyone can “Send blessing”';

  @override
  String get noticeGroupBroadcast => 'Broadcast';

  @override
  String get noticeGroupCelebration => 'Celebration';

  @override
  String get noticeInteractionReceive => 'Acknowledge';

  @override
  String get noticeInteractionReceived => 'Acknowledged';

  @override
  String get noticeClickToReceive => 'Tap to acknowledge';

  @override
  String noticeAckCount(int count) {
    return '$count acknowledged';
  }

  @override
  String noticeAckYouAndCount(int count) {
    return 'You acknowledged · $count total';
  }

  @override
  String get noticeSendBlessing => 'Send blessing';

  @override
  String get noticeBlessingSent => 'Blessing sent';

  @override
  String noticeBlessingCount(int count) {
    return '$count blessings';
  }

  @override
  String get noticeBlessingWall => 'Blessing Wall';

  @override
  String noticeBlessingReceivedCount(int count) {
    return '$count blessings received';
  }

  @override
  String get noticeBlessingWallEmpty => 'No blessings yet — send the first one';

  @override
  String get noticeBlessingPlaceholder => 'Write your blessing…';

  @override
  String get noticeBlessingSendButton => 'Send blessing';

  @override
  String get noticeBlessingSending => 'Sending…';

  @override
  String noticeBlessingViewAll(int count) {
    return 'View all $count';
  }

  @override
  String get noticeBlessingTemplatesTitle => 'Pick a blessing';

  @override
  String get noticeBlessingValidateEmpty => 'Please enter a blessing';

  @override
  String get noticeCelebrationSubjectLabel => 'Honoree';

  @override
  String get noticeCelebrationSubjectHint =>
      'Choose the colleague to celebrate';

  @override
  String get noticeCelebrationSubjectRequired => 'Please choose an honoree';

  @override
  String get noticeQuickCelebrationTitle => 'Quick celebration';

  @override
  String get noticeQuickCelebrationSubtitle =>
      'Pick a type; the template fills automatically';

  @override
  String get noticeQuickPublish => 'New notice';

  @override
  String get noticeQuickWedding => 'Wedding';

  @override
  String get noticeQuickNewborn => 'Newborn';

  @override
  String celebrationPopupBirthday(Object name) {
    return '$name, today is your birthday!\nXiao You wishes you a happy birthday!';
  }

  @override
  String celebrationPopupAnniversary(Object name, Object label) {
    return '$name, today is your work anniversary!\nXiao You wishes you $label!';
  }

  @override
  String celebrationPopupWedding(Object name) {
    return '$name, congratulations on your wedding!\nXiao You wishes you a lifetime of happiness!';
  }

  @override
  String celebrationPopupNewborn(Object name) {
    return '$name, congratulations on the new baby!\nXiao You wishes your little one health and joy!';
  }

  @override
  String get celebrationDismiss => 'Thanks, Xiao You';

  @override
  String celebrationCardBirthday(Object name) {
    return 'Today is $name\'s birthday';
  }

  @override
  String celebrationCardAnniversary(Object name, Object label) {
    return 'Today is $name\'s $label';
  }

  @override
  String celebrationCardWedding(Object name) {
    return 'Today is $name\'s wedding day';
  }

  @override
  String celebrationCardNewborn(Object name) {
    return '$name welcomes a new baby';
  }

  @override
  String get celebrationCardWall => 'View blessing wall';

  @override
  String get profileChangeEditTitle => 'Edit profile';

  @override
  String get profileChangeEditCta => 'Edit my profile';

  @override
  String get profileChangeFieldDirect => 'Direct edit';

  @override
  String get profileChangeFieldReview => 'Requires HR review';

  @override
  String get profileChangeFieldHrOnly => 'Contact HR';

  @override
  String get profileChangePasswordHint =>
      'For your safety, please enter your current password';

  @override
  String get profileChangePasswordLabel => 'Current password';

  @override
  String get profileChangePasswordWrong => 'Incorrect password';

  @override
  String get profileChangeSubmitSuccess => 'Submitted, pending HR review';

  @override
  String get profileChangeSubmitApplied => 'Changes saved';

  @override
  String get profileChangeSubmitFailed => 'Submit failed, please retry';

  @override
  String get profileChangeConflict =>
      'Profile has been updated by someone else, please refresh';

  @override
  String get profileChangeRateLimited =>
      'You already submitted a change for this field in the last 24 hours';

  @override
  String get profileChangeListTitle => 'My change requests';

  @override
  String get profileChangeListEmpty => 'No change requests yet';

  @override
  String get profileChangeFilterAll => 'All';

  @override
  String get profileChangeFilterPending => 'Pending';

  @override
  String get profileChangeFilterApplied => 'Applied';

  @override
  String get profileChangeFilterRejected => 'Rejected';

  @override
  String get profileChangeStatusPending => 'Pending HR review';

  @override
  String get profileChangeStatusApplied => 'Applied';

  @override
  String get profileChangeStatusApproved => 'Approved';

  @override
  String get profileChangeStatusRejected => 'Rejected';

  @override
  String get profileChangeStatusCancelled => 'Cancelled';

  @override
  String get profileChangeCancel => 'Cancel';

  @override
  String get profileChangeCancelledByMe => 'Cancelled by me';

  @override
  String get profileChangeBefore => 'Before';

  @override
  String get profileChangeAfter => 'After';

  @override
  String get profileChangeSubmittedAt => 'Submitted at';

  @override
  String get profileChangeReviewer => 'Reviewer';

  @override
  String get profileChangeReviewComment => 'Review comment';

  @override
  String get profileChangeDiffTitle => 'Changes in this request';

  @override
  String profileChangeBatchItems(Object count) {
    return '$count field(s)';
  }

  @override
  String get profileChangeHrQueueTitle => 'Profile change reviews';

  @override
  String get profileChangeHrQueueEmpty => 'No pending reviews';

  @override
  String get profileChangeReviewApprove => 'Approve';

  @override
  String get profileChangeReviewReject => 'Reject';

  @override
  String get profileChangeRejectDialogTitle => 'Reject request';

  @override
  String get profileChangeRejectReasonRequired =>
      'Rejection reason is required';

  @override
  String get profileChangeRejectReasonHint =>
      'Explain why; the employee will see this';

  @override
  String get profileChangeApproveDialogTitle => 'Confirm approval?';

  @override
  String get profileChangeApproveDialogBody =>
      'Changes will be merged into the employee profile immediately';

  @override
  String get profileChangeConfirm => 'Confirm';

  @override
  String get profileChangeCancel2 => 'Cancel';

  @override
  String get profileChangeRejectSuccess => 'Rejected';

  @override
  String get profileChangeApproveSuccess => 'Approved';

  @override
  String get profileChangeFieldPhone => 'Mobile';

  @override
  String get profileChangeFieldFullName => 'Full name';

  @override
  String get profileChangeFieldEmergencyName => 'Emergency contact name';

  @override
  String get profileChangeFieldEmergencyPhone => 'Emergency contact phone';

  @override
  String get profileChangeFieldEmergencyRelationship => 'Relationship';

  @override
  String profilePendingBadge(Object count) {
    return '$count pending';
  }

  @override
  String get profilePendingSectionTitle => 'Pending profile change reviews';

  @override
  String get profilePendingSectionViewAll => 'All →';

  @override
  String get profileFieldGroupContact => 'Contact';

  @override
  String get profileFieldGroupAddress => 'Address';

  @override
  String get profileFieldGroupEmergency => 'Emergency contacts';

  @override
  String get profileFieldGroupOrganization => 'Organization';

  @override
  String get profileEditPolicyHint =>
      'Green \"direct edit\" fields apply immediately; yellow fields take effect after HR review; all other fields are maintained by HR.';

  @override
  String profileEditPendingConflictHint(int count) {
    return 'You have $count pending request(s); editing the same fields again before approval may conflict with them.';
  }

  @override
  String get profileEditFieldAction => 'Edit';

  @override
  String get profileFieldWorkLocation => 'Work location';

  @override
  String get profileFieldSeatNo => 'Seat';

  @override
  String get profileFieldOfficePhone => 'Office phone';

  @override
  String get profileFieldEmail => 'Email';

  @override
  String get profileFieldResidenceAddress => 'Residence address';

  @override
  String get profileFieldHujiAddress => 'Hukou address';

  @override
  String get profileFieldEthnicity => 'Ethnicity';

  @override
  String get profileFieldPoliticalStatus => 'Political status';

  @override
  String get profileFieldMaritalStatus => 'Marital status';

  @override
  String get profileFieldBirthDate => 'Birth date';

  @override
  String get profileFieldGender => 'Gender';

  @override
  String get hubDisabledChip => 'Not enabled';

  @override
  String get hubSectionTaskCenter => 'Task center';

  @override
  String get hubSubDetailPerItem => 'Line-by-item details';

  @override
  String get hubSubSummaryPerDoc => 'Per-document totals';

  @override
  String get hubSubPendingReturnQty => 'Pending stock-in returns';

  @override
  String get hubSubReadOnlyPlan => 'Read-only plan';

  @override
  String get salesHubTitle => 'Sales';

  @override
  String get salesHubSectionReports => 'Sales reports';

  @override
  String get salesHubSectionScarcity => 'Stock arbitration';

  @override
  String get salesHubTaskOrderProgress => 'Order progress';

  @override
  String get salesHubTaskOrderProgressSub => 'Ship & completion status';

  @override
  String get salesHubDocQuote => 'Sales quote';

  @override
  String get salesHubDocQuoteSub => 'Pricing & validity';

  @override
  String get salesHubDocOrder => 'Sales order';

  @override
  String get salesHubDocOrderSub => 'Customer orders';

  @override
  String get salesHubDocShipment => 'Sales shipment';

  @override
  String get salesHubDocShipmentSub => 'Ship out, post A/R';

  @override
  String get salesHubDocOtherShipment => 'Other shipment';

  @override
  String get salesHubDocOtherShipmentSub => 'Direct stock-out';

  @override
  String get salesHubDocReturn => 'Sales return';

  @override
  String get salesHubDocReturnSub => 'Return & red-credit';

  @override
  String get salesHubReportDetail => 'Sales detail report';

  @override
  String get salesHubReportSummary => 'Sales summary report';

  @override
  String get salesHubScarcity => 'Scarcity reallocation';

  @override
  String get salesHubScarcitySub => 'Free low-priority stock';

  @override
  String get purchaseHubTitle => 'Purchasing';

  @override
  String get purchaseHubSectionReports => 'Purchase reports';

  @override
  String get purchaseHubTaskCenter => 'Purchasing tasks';

  @override
  String get purchaseHubTaskCenterSub => 'Split orders by supplier';

  @override
  String get purchaseHubReturnVendor => 'Returns to supplier';

  @override
  String get purchaseHubDocRequest => 'Planned purchase request';

  @override
  String get purchaseHubDocOrder => 'Purchase order';

  @override
  String get purchaseHubDocOrderSub => 'Order & track delivery';

  @override
  String get purchaseHubDocReceipt => 'Purchase receipt';

  @override
  String get purchaseHubDocReceiptSub => 'Receive into stock';

  @override
  String get purchaseHubDocReturn => 'Purchase return';

  @override
  String get purchaseHubDocReturnSub => 'Return out of stock';

  @override
  String get purchaseHubReportDetail => 'Purchase detail report';

  @override
  String get purchaseHubReportSummary => 'Purchase summary report';

  @override
  String get purchaseHubReportExpediting => 'Purchase expediting';

  @override
  String get purchaseHubReportExpeditingSub => 'Shortfalls & stock';

  @override
  String get subcontractHubTitle => 'Subcontracting';

  @override
  String get subcontractHubSectionReports => 'Subcontract reports';

  @override
  String get subcontractHubTaskCenter => 'Subcontracting tasks';

  @override
  String get subcontractHubTaskCenterSub => 'Split orders by vendor';

  @override
  String get subcontractHubReturnVendor => 'Returns to vendor';

  @override
  String get subcontractHubReportDetail => 'Subcontract detail report';

  @override
  String get subcontractHubReportSummary => 'Subcontract summary report';

  @override
  String get subcontractHubReportInOut => 'In-out status';

  @override
  String get subcontractHubReportInOutSub => 'Overall in/out status';

  @override
  String get productionHubTitle => 'Production';

  @override
  String get productionHubSectionReports => 'Production reports';

  @override
  String get productionHubSchedule => 'Scheduling & progress';

  @override
  String get productionHubScheduleSub => 'Plan, WIP, completion';

  @override
  String get productionHubPlan => 'New production plan';

  @override
  String get productionHubPlanSub =>
      'Reference a sales order or create manually; history';

  @override
  String get productionHubPlanHistory => 'Production plan history';

  @override
  String get productionHubPlanHistorySub =>
      'View plans, approvals, and batch records';

  @override
  String get productionHubMaterialAnalysis => 'Material readiness analysis';

  @override
  String get productionHubDaily => 'Production daily';

  @override
  String get productionHubDailySub => 'Daily output & reversal';

  @override
  String get productionHubReportPlanDetail => 'Plan detail';

  @override
  String get productionHubReportPlanDetailSub => 'Date, item, status';

  @override
  String get productionHubReportPlanSummary => 'Plan summary';

  @override
  String get productionHubReportPlanSummarySub => 'Doc, maker, approver';

  @override
  String get productionHubWhereUsed => 'Where-used';

  @override
  String get productionHubWhereUsedSub => 'Where a material is used';

  @override
  String get financeHubTitle => 'Finance';

  @override
  String get financeHubSectionReports => 'Finance reports';

  @override
  String get financeHubTaskApproval => 'Order approval tasks';

  @override
  String get financeSalesAllQueueLabel => 'sales order finance confirmations';

  @override
  String get financeSalesInitialQueueLabel =>
      'initial sales order finance approvals';

  @override
  String get financeSalesChangesQueueLabel => 'sales order changes';

  @override
  String financeSalesQueueCountLoading(String queue) {
    return 'Loading pending $queue';
  }

  @override
  String financeSalesQueueCountFailed(String queue) {
    return 'Could not load pending $queue. Open the task page to retry.';
  }

  @override
  String financeSalesQueueCountEmpty(String queue) {
    return 'No pending $queue';
  }

  @override
  String financeSalesQueueCountPending(String queue, int count) {
    return 'Pending $queue: $count';
  }

  @override
  String get financeHubTaskApprovalSub =>
      'Purchase and subcontract order approvals';

  @override
  String get financeHubTaskOverDelivery => 'Over-delivery approval';

  @override
  String get financeHubTaskOverDeliverySub => 'Approve excess arrivals';

  @override
  String get financeHubDocReceipt => 'Sales receipt';

  @override
  String get financeHubDocReceiptSub => 'Settle or direct receipt';

  @override
  String get financeHubDocPayment => 'Purchase payment';

  @override
  String get financeHubDocPaymentSub => 'Settle or direct payment';

  @override
  String get financeHubDocExpense => 'General expense';

  @override
  String get financeHubSubAllocatedByDept => 'Allocated by department';

  @override
  String get financeHubDocIncome => 'Other income';

  @override
  String get financeHubDocBankTransfer => 'Bank transfer';

  @override
  String get financeHubDocBankTransferSub => 'Between accounts';

  @override
  String get financeHubDocCheck => 'Check management';

  @override
  String get financeHubDocCheckSub => 'Check account view';

  @override
  String get financeHubDocAssets => 'Assets & prepaids';

  @override
  String get financeHubDocAssetsSub => 'Sub-ledger, depreciation';

  @override
  String get financeHubReportArAp => 'A/R & A/P';

  @override
  String get financeHubReportArApSub => 'Customer/vendor balance';

  @override
  String get financeHubReportDetail => 'Detail report';

  @override
  String get financeHubReportDetailSub => 'Receipts, payments, costs';

  @override
  String get financeHubReportSummary => 'Summary report';

  @override
  String get financeHubReportSummarySub => 'Receipt & payment totals';

  @override
  String get financeHubReportStatement => 'Account statement';

  @override
  String get financeHubReportStatementSub => 'Customer/vendor account';

  @override
  String get financeHubReportAccountFlow => 'Account ledger';

  @override
  String get financeHubReportAccountFlowSub => 'Account in/out ledger';

  @override
  String get financeHubReportRecon => 'Reconciliation';

  @override
  String get financeHubReportReconSub => 'Monthly reconciliation';

  @override
  String get financeHubReportCost => 'Cost accounting';

  @override
  String get financeHubReportCostSub => 'Product & sales cost';

  @override
  String get financeHubReportGl => 'General ledger';

  @override
  String get financeHubReportGlSub => 'Accounts, assets, P&L';

  @override
  String get warehouseHubTitle => 'Warehouse';

  @override
  String get warehouseHubSectionDocs => 'Stock documents';

  @override
  String get warehouseHubSectionInventory => 'Inventory queries';

  @override
  String get warehouseHubSectionInventoryDesc =>
      'Live stock, balances, movements';

  @override
  String get warehouseHubSectionReports => 'Warehouse reports';

  @override
  String get warehouseHubSectionReportsDesc =>
      'Detail (per item) & summary (per doc)';

  @override
  String get warehouseHubDocTransfer => 'Stock transfer';

  @override
  String get warehouseHubDocTransferSub => 'Between warehouses';

  @override
  String get warehouseHubDocCheck => 'Stocktake';

  @override
  String get warehouseHubDocCheckSub => 'Count & adjustment';

  @override
  String get warehouseHubInventoryLive => 'Live stock';

  @override
  String get warehouseHubReportDetail => 'Warehouse detail report';

  @override
  String get warehouseHubReportSummary => 'Warehouse summary report';

  @override
  String get basicDataHubTitle => 'Master data';

  @override
  String get basicDataHubGoods => 'Items';

  @override
  String get basicDataHubGoodsSub => 'Item categories & master';

  @override
  String get basicDataHubMould => 'Molds';

  @override
  String get basicDataHubMouldSub => 'Mold series & master';

  @override
  String get basicDataHubClient => 'Customers';

  @override
  String get basicDataHubClientSub => 'Customer groups & master';

  @override
  String get basicDataHubSupplier => 'Suppliers';

  @override
  String get basicDataHubSupplierSub => 'Supplier groups & master';

  @override
  String get basicDataHubColor => 'Colors';

  @override
  String get basicDataHubColorSub => 'Color master';

  @override
  String get basicDataHubUnit => 'Units';

  @override
  String get basicDataHubUnitSub => 'Unit of measure master';

  @override
  String get basicDataHubCurrency => 'Currencies';

  @override
  String get basicDataHubCurrencySub => 'Currency & FX rates';

  @override
  String get basicDataHubWarehouse => 'Warehouses';

  @override
  String get basicDataHubWarehouseSub => 'Warehouse master';

  @override
  String get basicDataHubAccount => 'Accounts';

  @override
  String get basicDataHubAccountSub => 'Account & balances';

  @override
  String get basicDataHubPaymentStyle => 'Payment categories';

  @override
  String get basicDataHubPaymentStyleSub => 'Six accounting classes';

  @override
  String get basicDataHubSettlementMethod => 'Settlement methods';

  @override
  String get basicDataHubSettlementMethodSub =>
      'Terms dictionary and payment-term rules';

  @override
  String get impersonationSwitchPerson => 'Switch person';

  @override
  String get impersonationEnterPasswordTitle => 'Confirm switch person';

  @override
  String get impersonationEnterPasswordHint =>
      'For security, enter your login password. After that you can switch freely for 15 minutes without re-entering.';

  @override
  String get impersonationPasswordLabel => 'Login password';

  @override
  String get impersonationTargetPickerTitle => 'Select an employee to view';

  @override
  String get impersonationSearchHint => 'Search name / employee code';

  @override
  String impersonationBannerTitle(String name) {
    return 'Viewing as $name (read-only)';
  }

  @override
  String get impersonationBannerSwitch => 'Switch';

  @override
  String get impersonationBannerExit => 'Exit';

  @override
  String impersonationRemainingMinutes(int count) {
    return '$count min left';
  }

  @override
  String get impersonationWrongPassword => 'Wrong password';

  @override
  String get impersonationExited => 'Exited impersonation';

  @override
  String get impersonationRecent => 'Recent';

  @override
  String get impersonationNoTargets => 'No employees available to switch';

  @override
  String get impersonationStartFailed => 'Switch failed';

  @override
  String get exportDialogTitle => 'Export Excel';

  @override
  String get exportPasswordOptionalHint =>
      'A password is optional. Leave it blank for a regular Excel file, or enter 1–128 characters to encrypt it.';

  @override
  String get exportPasswordOptionalLabel =>
      'Opening password (optional, 1–128)';

  @override
  String get exportPasswordConfirmLabel => 'Confirm password';

  @override
  String get exportPasswordTooLong => 'Password cannot exceed 128 characters';

  @override
  String get exportPasswordMismatch => 'Passwords do not match';

  @override
  String get exportDownloadPlain => 'Download';

  @override
  String get exportDownloadEncrypted => 'Download encrypted';

  @override
  String get exportFailed => 'Export failed. Try again later.';

  @override
  String exportDownloadStarted(String name) {
    return 'Download started: $name';
  }

  @override
  String exportDownloadSaved(String path) {
    return 'Saved to $path';
  }

  @override
  String get profileLoadingMessage => 'Loading employee record…';

  @override
  String get profileLoadFailed => 'Employee record failed to load';

  @override
  String get profileUnboundTitle =>
      'This account is not linked to an employee record';

  @override
  String get profileUnboundDescription =>
      'Contact an administrator or HR to link this account to an employee record.';

  @override
  String get profileSessionUnavailable =>
      'You are not signed in or the session is unavailable';

  @override
  String get profileValueNotProvided => 'Not provided';

  @override
  String get profileValueNotRegistered => 'Not registered';

  @override
  String get profileAlternatePhoneLabel => 'Alternate phone';

  @override
  String get profileContractSummaryTitle => 'Contract summary';

  @override
  String get profileTabOrgContract => 'Org & contract';

  @override
  String get profileTabContactVehicle => 'Contact & vehicles';

  @override
  String get profileTabMyDocuments => 'My documents';

  @override
  String get profileEmploymentHistoryTitle => 'Employment history';

  @override
  String get profileCompensationBoundaryDescription =>
      'Salary and bank information are intentionally not shown on My Profile. Check monthly income in Payslips, or contact authorized HR for other questions.';

  @override
  String get profileMissingEmergencyContact =>
      'No emergency contact is registered. Ask HR to register one before requesting changes here.';

  @override
  String get historyEventConfirm => 'Confirmation';

  @override
  String get accountProvisionPermissionDenied =>
      'You do not have permission to provision accounts. Contact account support.';

  @override
  String get accountProvisionAlreadyExists =>
      'This employee already has an account or the account is inactive; it cannot be provisioned again.';

  @override
  String get accountProvisionConfirmTitle => 'Confirm account provisioning';

  @override
  String get accountProvisionFailed =>
      'Account provisioning failed. Try again later.';

  @override
  String get accountProvisionInProgress => 'Provisioning';

  @override
  String get accountStatusNotProvisioned => 'Not provisioned';

  @override
  String get accountStatusInactive => 'Account inactive';

  @override
  String get pagePermissionAccountNotProvisionedTitle =>
      'This person does not have an account, so permissions cannot be configured yet';

  @override
  String get pagePermissionAccountNotProvisionedCanProvision =>
      'Provision the account first. After the one-time credentials are saved, this person\'s permissions will load automatically.';

  @override
  String get pagePermissionAccountNotProvisionedNoAccess =>
      'Contact someone with Account Support permission to provision the login account.';

  @override
  String get employeePermissionSettingsTooltip =>
      'Configure employee permissions';

  @override
  String get employeeAccountNotProvisionedTooltip =>
      'Employee account not provisioned';

  @override
  String get employeeResignedCannotProvision =>
      'A resigned employee cannot be given a login account';

  @override
  String get employeeAccountNotProvisionedContactSupport =>
      'This employee does not have an account. Contact account support.';

  @override
  String get materialMainWarehouse => 'Main warehouse';

  @override
  String get materialWarehouseScopeExplanation =>
      'Planning uses main-warehouse totals. Warehouse staff arrange the picking locations.';

  @override
  String get materialSearchHint => 'Search products or materials';

  @override
  String get materialByProduct => 'By product';

  @override
  String get materialByMaterial => 'By material';

  @override
  String get materialIdentityByMaterial => 'Material name';

  @override
  String get materialIdentityByProduct => 'Material name';

  @override
  String get materialRoute => 'Supply method';

  @override
  String get materialRequired => 'Qty needed';

  @override
  String get materialShortage => 'Still short';

  @override
  String get materialPhysicalShortageHint =>
      'Batch demand still lacking qualified material. Issuing purchase, subcontract or workshop work does not reduce this shortage; qualified stock-in allocated to this batch does. Additional supply separately deducts incoming supply to prevent duplicate requests.';

  @override
  String get materialSupplyProgressHint =>
      'Track ordering, finance approval, arrival, inspection and stock-in. Double-click for details. Physical shortage remains after issue and updates after qualified stock-in.';

  @override
  String get materialToSupply => 'Order quantity';

  @override
  String get materialHandle => 'Handle';

  @override
  String get materialAdditionalOrder => 'Additional order';

  @override
  String get materialProductionWorkshop => 'Production workshop';

  @override
  String get materialResponsible => 'Owner';

  @override
  String get materialFutureSupply => 'In transit';

  @override
  String get materialProgress => 'Progress / next step';

  @override
  String get materialMixedRoutes => 'Mixed routes';

  @override
  String materialAggregateSources(int products, int paths) {
    return '$products products · $paths paths';
  }

  @override
  String materialCreateRoutes(int count) {
    return 'Confirm routes ($count)';
  }

  @override
  String get materialRouteChangedRetry =>
      'Analysis updated. Review the selected routes and try again.';

  @override
  String get materialWarehouseFacts => 'Warehouse and supply details';

  @override
  String get materialExactStock => 'Qualified stock pegged here';

  @override
  String get materialPublicStock => 'Public stock';

  @override
  String get materialClaimedSupply => 'Claimed for this task';

  @override
  String get materialTaskBuy => 'Issue purchasing';

  @override
  String get materialTaskSubcontract => 'Issue subcontracting';

  @override
  String get materialTaskWorkshop => 'Issue to workshop';

  @override
  String get materialTaskIssued => 'Issued';

  @override
  String get materialTaskBlocked => 'Needs attention';

  @override
  String get materialTaskEmpty => 'No tasks match this filter';

  @override
  String get materialTaskBuyHint =>
      'Issue remaining purchasing demand and track orders, receipts and inspections.';

  @override
  String get materialTaskSubcontractHint =>
      'Issue remaining subcontracting demand; components first create workshop preparation tasks.';

  @override
  String get materialTaskWorkshopHint =>
      'Set quantity, workshop and owner before issuing. Material-short tasks wait until materials are ready and issued.';

  @override
  String get materialTaskSectionHint =>
      'Manage preparation by route and review pending, issued and blocked tasks.';

  @override
  String get materialWarehouseLimit =>
      'An analysis supports at most 100 physical warehouses. Adjust the warehouse scope before analyzing.';

  @override
  String materialRoutesNext(int count) {
    return 'Next: review $count routes, select them and confirm. Each row keeps its selected route.';
  }

  @override
  String get materialIssueNext =>
      'Next: open purchasing, subcontracting or workshop tasks to issue remaining demand and track issued work.';

  @override
  String materialWorkshopNext(int count) {
    return 'Next: $count products can be issued to workshops. Set quantity, workshop and owner; material-short batches wait for complete kits and material issues.';
  }

  @override
  String materialPreparedChildCreated(int count) {
    return 'Created $count preparation tasks; they have not been issued to a workshop yet.';
  }

  @override
  String get materialPreparedChildNext =>
      'Check quantity, workshop and owner in the selected rows, then generate the production plan. Approval is required before release.';

  @override
  String get materialPreparedChildNeedPlanner =>
      'A planner with production-plan generation permission must set quantity, workshop and owner and submit the plan.';

  @override
  String get materialRootRoutePending => 'Route pending';

  @override
  String get materialRootExternalRoute =>
      'Issue this top-level product from its purchasing or subcontracting entry';

  @override
  String get materialRootSupplyCompleted => 'Supply demand fulfilled';

  @override
  String get materialRootOutputHistory => 'Top-level supply handovers';

  @override
  String get materialRootStockAllocation => 'Existing stock allocation';

  @override
  String get materialRootReceivedSupply => 'Qualified receipt handover';

  @override
  String get materialRootOutputReversed => 'Handover reversed';

  @override
  String get materialSupplyTasksAndReversals => 'Supply tasks and reversals';

  @override
  String get materialNotificationReversalReconcile => 'Reconcile reversal';

  @override
  String get materialRevokeRootStock => 'Reverse stock allocation';

  @override
  String get materialRootRevokeFailed =>
      'Stock allocation could not be reversed. Refresh and review it.';

  @override
  String get materialRootSupplyProcessed =>
      'Supply processed. Review the stock handovers and additional demand records.';

  @override
  String get orderChangeQtyButton => 'Change Qty';

  @override
  String get orderChangeQtyTitle => 'Order Qty Change';

  @override
  String get orderChangeQtyWarning =>
      'Changes after approval take effect immediately and automatically re-enter finance review; finance will see the change list (before → after). Rejection does not restore quantities.';

  @override
  String orderChangeQtyCurrent(String qty) {
    return 'Now $qty';
  }

  @override
  String get orderChangeQtyNewQty => 'New qty';

  @override
  String get orderChangeQtyConfirm => 'Confirm Change';

  @override
  String get orderChangeQtyInvalid =>
      'Some quantities are invalid (must be greater than 0). Please check.';

  @override
  String get orderChangeQtySuccess =>
      'Quantities changed; the order has re-entered finance review';

  @override
  String get orderChangeQtyFailed =>
      'Failed to change quantities. Please try again later.';

  @override
  String orderQtyChangeOld(String value) {
    return 'Before $value';
  }

  @override
  String orderQtyChangeNew(String value) {
    return 'After $value';
  }

  @override
  String get procurementApprovalStatusPending => 'Awaiting finance review';

  @override
  String procurementApprovalStatusChanged(int count) {
    return 'Re-review after change · $count qty changes';
  }

  @override
  String procurementApprovalQtyChangesTitle(int count) {
    return 'Change list · $count qty changes';
  }

  @override
  String get procurementApprovalQtyChangesHint =>
      'Quantities were changed after finance approval and the order has automatically re-entered review; please verify each line (before → after) before reviewing.';

  @override
  String get productionMaterialRecheck => 'Recheck material readiness';

  @override
  String get productionMaterialRecheckReady =>
      'Materials are ready. Select the tasks and submit a material request in My Workshop Tasks. Start after the warehouse has issued all materials.';

  @override
  String get productionMaterialRecheckWaiting =>
      'Materials are still short. Check completed stock receipts and reservations for other tasks.';

  @override
  String get fieldAutofilledReview =>
      'Filled from a previous record or default. Please review before use.';

  @override
  String get workflowQuantityHint =>
      'Enter this quantity in the row unit. Do not mix boxes, pieces or kilograms; a linked source must have enough available quantity.';

  @override
  String get workflowOrderQuantityHint =>
      'Enter the ordered quantity in the row unit. Editing is locked during finance review; changes after approval require a new review.';

  @override
  String get workflowReturnQuantityHint =>
      'Use the original shipment line unit for the actual returned quantity. Do not exceed the remaining returnable quantity. Approved returns await inspection before becoming saleable stock.';

  @override
  String get workflowPriceHint =>
      'Enter the price per row unit in its currency. The line amount follows quantity; do not enter the line total as a unit price.';

  @override
  String get workflowReturnPriceHint =>
      'Return credit is calculated at approval from the original shipment and prior returns. A reference price cannot increase the refundable amount.';

  @override
  String get workflowDiscountHint =>
      'Use a decimal multiplier: 1 is full price and 0.9 means 10% off. Do not enter 9 or 90.';

  @override
  String get workflowExchangeRateHint =>
      'Enter the base-currency value of one unit of the original currency, with up to 6 decimals. Check any prefilled rate for this transaction.';

  @override
  String get workflowTaxRateHint =>
      'Enter a percentage: 13 means 13%. Do not enter 0.13.';

  @override
  String get workflowCurrencyHint =>
      'The currency defines this line’s prices and amounts. Check the source document before changing it.';

  @override
  String get workflowSettlementHint =>
      'Select the agreed supplier settlement terms. Different suppliers, currencies or terms may produce separate orders.';

  @override
  String get workflowWorkshopQuantityHint =>
      'Enter the quantity assigned to the workshop now. Dispatch can happen first; starting and material issue still require the necessary materials and state.';

  @override
  String get workflowReportQuantityHint =>
      'Enter the output completed this time in the plan-line unit, not cumulative output. Approved reporting still requires warehouse registration, quality inspection and stock-in.';

  @override
  String get workflowArrivalQuantityHint =>
      'Enter the actual quantity received now in the row unit, including shortages or excess. Quantity above approval enters exception handling rather than available stock.';

  @override
  String get workflowIqcPassHint =>
      'Enter only the quantity passed this time. Passed plus failed quantity must not exceed the uninspected balance; warehouse confirmation is still needed for stock-in.';

  @override
  String get workflowIqcFailHint =>
      'Enter only the quantity failed this time. It does not become available stock and still needs return, rework or another disposition.';

  @override
  String get workflowPrepaymentAmountHint =>
      'Enter the advance payment actually received in the order currency. Receipt is recorded once; later applying it to receivables does not record another cash receipt.';

  @override
  String get workflowReceiptAllocationHint =>
      'Allocate this receipt to the receivable in its original currency, up to its collectible balance. Do not allocate the same received money twice.';

  @override
  String get workflowBankFeeHint =>
      'Enter the actual bank fee. A fee deducted from the receipt must not also be recorded as a separate payment.';

  @override
  String get workflowOtherFeeHint =>
      'Enter only other fees for this receipt and select their expense category. Do not record a fee twice.';

  @override
  String get workflowReturnReasonHint =>
      'Describe the return reason and original shipment. Approval creates a credit awaiting disposition and quarantines the goods; refund or replacement decisions are separate.';

  @override
  String get workflowPrepaymentOrderHint =>
      'Select the sales order for this advance payment. Its customer and currency are inherited; change the order if the source is wrong.';

  @override
  String get workflowPrepaymentApplyHint =>
      'Explain which advance payment covers which receivables and why. Applying it adjusts balances without recording another cash receipt.';

  @override
  String get workflowFinanceReviewHint =>
      'Record your review. Compare before and after values for changed orders. Finance approval does not mean payment, shipment or production has occurred.';

  @override
  String get workflowFinanceRejectHint =>
      'State what is wrong and what must change. Sales receives this reason and can resubmit after correction.';

  @override
  String get workflowOptionalDetails => 'Additional details (optional)';

  @override
  String get workflowUnitUnknown => 'Inspection unit needs review';

  @override
  String get moneySummaryCustomerPaid => 'Customer paid';

  @override
  String get moneySummaryGrossShipped => 'Gross shipped amount';

  @override
  String get moneySummaryReturned => 'Returned amount';

  @override
  String get moneySummaryUnusedReturns => 'Unapplied return balance';

  @override
  String get moneySummaryNetReceivable => 'Current amount to collect';

  @override
  String get moneySummaryPendingBalance => 'Customer balance to resolve';

  @override
  String get moneySummaryFutureShipment => 'Future shipment amount';

  @override
  String get moneySummaryExpectedNewCash => 'Estimated new payment needed';

  @override
  String get moneySummaryBalanceHint =>
      'Finance must confirm how this balance is applied or refunded. It does not mean a refund has been paid.';

  @override
  String get moneySummaryCollectionHint =>
      'Estimated from current receivables, future shipments and unused advances. No credit or refund is applied automatically.';

  @override
  String get moneySummarySourceHint =>
      'Amounts come from approved documents. Customer payments may include deducted fees; bank cash received is shown in account transactions.';

  @override
  String get moneySummaryUnallocatedHint =>
      'Some payments have not been matched to this order. Finance needs to reconcile them.';

  @override
  String get warehouseArrivalSourceLabel => 'Arrival source';

  @override
  String get warehouseArrivalSourceAutomatic => 'Automatic';

  @override
  String get warehouseArrivalSourceNormal => 'Normal arrival';

  @override
  String get warehouseArrivalSourceReplacement => 'Replace returns first';

  @override
  String get warehouseArrivalSourceHint =>
      'The system identifies the source when only one is available. If both normal arrivals and returned goods are outstanding, select the source of this batch. Replace returns first fills the returned quantity first; any remainder is a normal arrival. Whether replacement is free or billed follows the original return resolution.';

  @override
  String get subcontractPreparationWarehouse => 'Internal production warehouse';

  @override
  String get subcontractPreparationWarehouseHint =>
      'For a direct subcontract order with components and insufficient stock, select the warehouse for internal production receipts. Planning receives the shortage; finance submission becomes available after actual receipt. Optional when there are no components or stock is sufficient.';

  @override
  String get subcontractInternalProduction => 'Internal production';

  @override
  String get subcontractPreparedQuantity => 'Prepared';

  @override
  String get subcontractPreparationShortage => 'Still to produce';

  @override
  String get subcontractOpenPreparation => 'View production plan';

  @override
  String get subcontractDraftPreparationHint =>
      'Planning arranges internal production first. Submit to finance after the goods are received into stock.';

  @override
  String get subcontractWaitingPlan => 'Waiting for planning';

  @override
  String get subcontractReadyForFinance => 'Ready for finance submission';

  @override
  String get materialIssuedPlanSyncPending =>
      'Issued; waiting for plan progress to sync';

  @override
  String get subcontractOrderBlockedProducing =>
      'Production is in progress. Subcontract ordering is not available yet.';

  @override
  String get subcontractOrderBlockedPreparation =>
      'Preparation is not complete. Subcontract ordering is not available yet.';

  @override
  String get subcontractOrderBlockedNotification =>
      'Production is complete. Notify subcontracting before placing the order.';

  @override
  String get subcontractOrderBlockedCancelled =>
      'The production task was cancelled. Subcontract ordering is unavailable.';

  @override
  String get subcontractOrderBlockedComponentStock =>
      'The component has not been received into stock yet. Subcontract ordering is not available; the task center unlocks automatically once the component is received.';

  @override
  String get subcontractPlanIssuedDate => 'Task issue date';

  @override
  String get subcontractPlanIssuedDateHint =>
      'The date planning first issued this subcontract task.';

  @override
  String get subcontractOrderBlockedRefresh =>
      'Subcontracting has been notified. Refresh the task list before ordering.';

  @override
  String get serverStatusTitle => 'Server status';

  @override
  String get serverStatusRefresh => 'Refresh';

  @override
  String get serverStatusAccessRequired =>
      'You do not have permission to view server status';

  @override
  String get serverStatusResources => 'Resources';

  @override
  String get serverStatusStorage => 'Disk space';

  @override
  String get serverStatusDataProtection => 'Database and backups';

  @override
  String get serverStatusOverview => 'Health overview';

  @override
  String get serverStatusOverviewHint =>
      'Based on the server’s latest collected measurements.';

  @override
  String get serverStatusCollecting =>
      'Waiting for the server to collect measurements.';

  @override
  String get serverStatusStale =>
      'Measurements are out of date. Waiting for a new sample.';

  @override
  String get serverStatusRefreshFailed =>
      'Unable to update. Previous measurements are for reference only; try refreshing shortly.';

  @override
  String get serverStatusUpdatedAt => 'Collected at';

  @override
  String get serverStatusEnvironment => 'Environment';

  @override
  String get serverStatusVersion => 'Application version';

  @override
  String get serverStatusUptime => 'Uptime';

  @override
  String serverStatusPolling(int seconds) {
    return 'Refreshes every $seconds seconds while this page is visible';
  }

  @override
  String get serverStatusCpu => 'Processor (CPU)';

  @override
  String get serverStatusMemory => 'System memory';

  @override
  String get serverStatusAppMemory => 'Application memory';

  @override
  String get serverStatusDbPool => 'Database connection pool';

  @override
  String get serverStatusDisk => 'Disk';

  @override
  String get serverStatusUsed => 'Used';

  @override
  String get serverStatusFree => 'Free space';

  @override
  String get serverStatusCapacity => 'Capacity';

  @override
  String get serverStatusDatabase => 'Database';

  @override
  String get serverStatusDatabaseHint =>
      'Database responsiveness and current connection count.';

  @override
  String get serverStatusResponse => 'Response time';

  @override
  String get serverStatusConnections => 'Current / maximum connections';

  @override
  String get serverStatusBackup => 'Latest backup';

  @override
  String get serverStatusHours => 'hours';

  @override
  String get serverStatusLastBackup => 'Last successful backup';

  @override
  String get serverStatusAttention => 'Needs attention';

  @override
  String get serverStatusNotCollected =>
      'This measurement is not available yet';

  @override
  String serverStatusUptimeValue(int days, int hours, int minutes) {
    return '${days}d ${hours}h ${minutes}m';
  }

  @override
  String get serverStatusThresholdUnknown =>
      'No alert thresholds are available';

  @override
  String serverStatusThresholds(String warning, String critical) {
    return 'Warning ≥ $warning; critical ≥ $critical';
  }

  @override
  String get serverStatusNormal => 'Normal';

  @override
  String get serverStatusWarning => 'Warning';

  @override
  String get serverStatusCritical => 'Critical';

  @override
  String get serverStatusUnknown => 'Unknown';

  @override
  String attachmentUploadFormatsHint(String maxSize) {
    return 'Images / PDF / Office / zip / txt, up to $maxSize per file';
  }

  @override
  String attachmentUploadedFile(String fileName) {
    return 'Uploaded $fileName';
  }

  @override
  String attachmentUploadedFiles(int count) {
    return 'Uploaded $count files';
  }

  @override
  String get productionMaterialRecheckHelp =>
      'Recheck qualified receipts for this task and available stock. This does not receive stock or record actual consumption.';

  @override
  String get productionMaterialViewUsage => 'View usage records';

  @override
  String get systemSettingInvalidInteger =>
      'Enter a valid non-negative integer';

  @override
  String get systemSettingInvalidValue =>
      'The setting is outside its allowed range';

  @override
  String get systemSettingEnabled => 'Enabled';

  @override
  String get systemSettingDisabled => 'Disabled';

  @override
  String get systemSettingFixFields => 'Check the highlighted settings first';

  @override
  String get systemSettingUnsavedRefresh =>
      'Save or revert your changes before refreshing';

  @override
  String get systemSettingEffectTiming =>
      'Security limits apply to subsequent actions and token lifetimes to newly issued tokens. Celebrations and audit retention apply on their scheduled runs. Changes are audited and require password confirmation.';

  @override
  String get auditSummaryUnavailable =>
      'Summary unavailable; event records remain available';

  @override
  String get auditSummaryRetry => 'Retry summary';

  @override
  String get auditWorkspaceDescription =>
      'Review sessions by person and time, then follow events to business changes.';

  @override
  String get materialReasonLabel => 'Reason';

  @override
  String get materialReasonRequired => 'Enter a reason';

  @override
  String materialReasonTooLong(int max) {
    return 'Use no more than $max characters for the reason';
  }

  @override
  String materialReasonTooShort(int min) {
    return 'Enter at least $min characters for the reason';
  }

  @override
  String get auditFiltersTitle => 'Operation, business object and event type';

  @override
  String warehouseOutboundBatchAction(String action) {
    return 'Batch $action';
  }

  @override
  String get warehouseOutboundBatchReview => 'Review sales outbound tasks';

  @override
  String get warehouseOutboundBatchHint =>
      'Check goods, quantities, units, warehouses and actual locations before confirming the outbound.';

  @override
  String warehouseOutboundBatchConfirm(String action, int count) {
    return 'Confirm $action for $count selected documents?';
  }

  @override
  String get warehouseOutboundBatchStopped =>
      'Batch processing stopped. Return and refresh before selecting unfinished tasks.';

  @override
  String get warehouseOutboundBatchUnknown =>
      'No definite result was received. Return and refresh to check the current status before proceeding.';

  @override
  String get warehouseOutboundBatchStale =>
      'The task status or allowed actions have changed. Refresh and review.';

  @override
  String get warehouseOutboundBatchEmpty =>
      'The selected tasks are no longer actionable. Return and refresh the list.';

  @override
  String get warehouseOutboundBatchResult => 'Processing result';

  @override
  String get warehouseOutboundBatchDone => 'Completed';

  @override
  String get warehouseOutboundBatchPending => 'Not processed';

  @override
  String get warehouseOutboundBatchFailed => 'Failed; review required';

  @override
  String warehouseOutboundBatchSelection(int count) {
    return '$count documents selected';
  }

  @override
  String get warehouseOutboundBatchReason => 'Processing note';

  @override
  String get warehouseOutboundConfirmShipment => 'Confirm outbound';

  @override
  String get warehouseOutboundBillNo => 'Shipment number';

  @override
  String get warehouseOutboundClient => 'Customer';

  @override
  String get warehouseOutboundStatus => 'Warehouse status';

  @override
  String get warehouseOutboundLineNo => 'Line';

  @override
  String get warehouseOutboundGoodsCode => 'Goods code';

  @override
  String get warehouseOutboundGoodsName => 'Goods name';

  @override
  String get warehouseOutboundPlaceHint => 'Suggested location';

  @override
  String get warehouseOutboundColor => 'Color';

  @override
  String get warehouseOutboundUnit => 'Unit';

  @override
  String get warehouseOutboundQuantity => 'Shipment quantity';

  @override
  String get warehouseOutboundWeight => 'Weight';

  @override
  String get warehouseOutboundParcelQuantity => 'Packages';

  @override
  String get warehouseOutboundCartonCount => 'Cartons';

  @override
  String get warehouseOutboundClientProductCode => 'Customer product code';

  @override
  String get warehouseOutboundClientModel => 'Customer model';

  @override
  String get warehouseOutboundSourceOrder => 'Source order';

  @override
  String get warehouseStockOutboundTitle => 'Review outbound documents';

  @override
  String get warehouseStockOutboundAction => 'Batch outbound';

  @override
  String get warehouseStockOutboundConfirm => 'Confirm batch outbound';

  @override
  String warehouseStockOutboundConfirmMessage(int count) {
    return 'Issue the quantities shown for $count selected documents?\nEach document is approved separately, deducting stock from its actual warehouse and recording your approval. Processing stops on an error; successful documents remain completed.';
  }

  @override
  String get warehouseStockOutboundHint =>
      'Check goods, quantities, units and actual warehouses. Selecting a line selects its entire document. To change quantities, edit the draft first.';

  @override
  String get warehouseStockOutboundLoadFailed =>
      'Unable to load outbound details. Please retry.';

  @override
  String warehouseStockOutboundCompleted(int count) {
    return 'Completed $count outbound documents';
  }

  @override
  String get warehouseStockOutboundDone => 'Issued';

  @override
  String get warehouseStockOutboundUnavailable => 'Currently unavailable';

  @override
  String get warehouseStockOutboundProcessing =>
      'Confirming outbound documents';

  @override
  String get warehouseStockOutboundBillNo => 'Outbound document';

  @override
  String get warehouseStockOutboundPlace => 'Actual location code';

  @override
  String get warehouseStockOutboundQuantity => 'Outbound quantity';

  @override
  String get warehouseStockOutboundSource => 'Source document';

  @override
  String get warehouseSubcontractOutboundBatchTitle => 'Batch outbound details';

  @override
  String get warehouseSubcontractOutboundBatchAction => 'Batch outbound';

  @override
  String get warehouseSubcontractOutboundBatchConfirm =>
      'Confirm batch outbound';

  @override
  String get warehouseSubcontractOutboundReviewHint =>
      'Check each quantity and actual warehouse before confirming outbound.';

  @override
  String get warehouseSubcontractOutboundBatchHint =>
      'Lines are selected together for each outbound document. Reduce quantities for a partial issue. Each document is saved and approved separately; completed results are retained. Processing pauses on errors. Verify the result before continuing unprocessed documents.';

  @override
  String get warehouseSubcontractOutboundDocuments => 'Document details';

  @override
  String get warehouseSubcontractOutboundOrder => 'Source order';

  @override
  String get warehouseSubcontractOutboundSupplier => 'Subcontractor';

  @override
  String get warehouseSubcontractOutboundWarehouse => 'Issue warehouse';

  @override
  String get warehouseSubcontractOutboundWorker => 'Handler';

  @override
  String get warehouseSubcontractOutboundDate => 'Outbound date';

  @override
  String get warehouseSubcontractOutboundDeliveryDate => 'Delivery date';

  @override
  String get warehouseSubcontractOutboundGoodsName => 'Goods name';

  @override
  String get warehouseSubcontractOutboundGoodsCode => 'Code';

  @override
  String get warehouseSubcontractOutboundParentName =>
      'Subcontract item returned';

  @override
  String get warehouseSubcontractOutboundParentCode => 'Subcontract item code';

  @override
  String get warehouseSubcontractOutboundColor => 'Colour';

  @override
  String get warehouseSubcontractOutboundUnit => 'Unit';

  @override
  String get warehouseSubcontractOutboundPlanned => 'Planned quantity';

  @override
  String get warehouseSubcontractOutboundPrepared => 'Prepared quantity';

  @override
  String get warehouseSubcontractOutboundIssued => 'Issued quantity';

  @override
  String get warehouseSubcontractOutboundStockAvailable =>
      'Available in warehouse';

  @override
  String get warehouseSubcontractOutboundAvailable => 'Maximum this issue';

  @override
  String get warehouseSubcontractOutboundQuantity => 'Issue quantity';

  @override
  String get warehouseSubcontractOutboundPlace => 'Location code';

  @override
  String get warehouseSubcontractOutboundStatus => 'Result';

  @override
  String get warehouseSubcontractOutboundPending => 'Pending outbound';

  @override
  String get warehouseSubcontractOutboundDone => 'Issued';

  @override
  String get warehouseSubcontractOutboundPaused => 'Paused; verify the result';

  @override
  String get warehouseSubcontractOutboundUncertain =>
      'The receipt is uncertain. Verify the result before continuing.';

  @override
  String get warehouseSubcontractOutboundChanged =>
      'The document has changed or been processed. Return, refresh and select it again.';

  @override
  String get warehouseSubcontractOutboundSelectRequired =>
      'Select at least one outbound task.';

  @override
  String get warehouseSubcontractOutboundSelectionLimit =>
      'Select at most 50 tasks per batch.';

  @override
  String get warehouseSubcontractOutboundWarehouseRequired =>
      'Select an issue warehouse.';

  @override
  String get warehouseSubcontractOutboundQuantityInvalid =>
      'Issue quantity must be greater than zero and cannot exceed the maximum this issue.';

  @override
  String get warehouseSubcontractOutboundLoadFailed =>
      'Could not load outbound details. Please retry.';

  @override
  String get warehouseSubcontractOutboundConfirmResponsibility =>
      'Confirmation records the signed-in employee as responsible for this outbound approval.';

  @override
  String get warehouseSubcontractOutboundSubcontractEffects =>
      'Approval issues the target goods from the selected warehouse to the subcontractor. Returned goods still require registration and quality inspection.';

  @override
  String warehouseSubcontractOutboundBatchResult(int done, int total) {
    return 'Completed $done of $total tasks.';
  }

  @override
  String get warehouseSubcontractOutboundContinue =>
      'Continue unprocessed tasks';

  @override
  String get warehouseSubcontractOutboundVerify => 'Verify processing result';

  @override
  String get warehouseSubcontractOutboundDraft => 'Outbound draft';

  @override
  String get warehouseSubcontractOutboundNoLines =>
      'No outbound lines are currently available';

  @override
  String get warehouseStockOutboundConfirmSingle => 'Confirm outbound';

  @override
  String get warehouseStockOutboundSeries => 'Series';

  @override
  String get warehouseSubcontractOutboundDraftsGenerated =>
      'Outbound drafts have been generated. Review each draft\'s actual warehouse and quantities before confirming outbound.';

  @override
  String get warehouseSubcontractOutboundPrepareDrafts =>
      'Generate drafts and review';

  @override
  String get warehouseOutboundBatchDocuments => 'Document information';

  @override
  String get warehouseOutboundBatchBillDate => 'Document date';

  @override
  String get warehouseOutboundBatchWorker => 'Handler';

  @override
  String get warehouseOutboundBatchMaker => 'Created by';

  @override
  String get warehouseOutboundBatchCreatedAt => 'Created at';

  @override
  String get warehouseOutboundBatchUpdatedAt => 'Work updated at';

  @override
  String get warehouseSubcontractOutboundDocumentRemark => 'Document notes';

  @override
  String get warehouseSubcontractOutboundLineRemark => 'Line notes';

  @override
  String get warehouseSubcontractOutboundWarehouseSyncHint =>
      'Defaults to the original document\'s actual warehouse. Changing it updates every line belonging to that document.';

  @override
  String get warehouseSubcontractOutboundDocumentRemarkHint =>
      'These notes are shared by every line of the same outbound document. Use line notes for information specific to one line.';

  @override
  String get warehouseSubcontractOutboundStageDraftPicking =>
      'Outbound draft awaiting picking';

  @override
  String warehouseSubcontractOutboundStageReady(String qty) {
    return 'Prepared, awaiting outbound (issuable $qty)';
  }

  @override
  String get warehouseSubcontractOutboundStageReadyPlain =>
      'Prepared, awaiting outbound';

  @override
  String get warehouseSubcontractOutboundWaitingComponent =>
      'Waiting for component stock';

  @override
  String get warehouseSubcontractOutboundStageBlockedPreparation =>
      'Preparation blocked';

  @override
  String get warehouseSubcontractOutboundStageWaitingPreparation =>
      'Waiting for preparation';

  @override
  String get warehouseSubcontractOutboundStagePendingDraft =>
      'Outbound document pending';

  @override
  String get warehouseSubcontractOutboundOpenPicking => 'Open picking outbound';

  @override
  String get warehouseSubcontractOutboundBannerComponent =>
      'Component-issue subcontract items: an issuable quantity appears only after the component is received into stock. The warehouse issues the component; the subcontractor returns the subcontract item.';

  @override
  String warehouseSubcontractOutboundWaitingComponentStock(String qty) {
    return 'Waiting for component stock (available $qty)';
  }

  @override
  String get warehouseSubcontractOutboundSuggestedWarehouse =>
      'Suggested issue warehouse';

  @override
  String get warehouseSubcontractOutboundComponentEffects =>
      'Approval issues the component from the selected warehouse to the subcontractor. The subcontract item is registered on return and still requires quality inspection before it is received into stock.';

  @override
  String get warehouseSubcontractOutboundComponentNotArrived =>
      'The component has not been received yet; there is none in stock. The system adds a draft and notifies the warehouse automatically once the component is received.';

  @override
  String get warehouseSubcontractOutboundWorkView => 'Warehouse work view';

  @override
  String get warehouseSubcontractOutboundBannerScope =>
      'The warehouse work view has no prices or amounts and offers no subcontract business editing.';

  @override
  String warehouseSubcontractOutboundBannerDraftPending(String billNo) {
    return 'Draft $billNo awaits picking review';
  }

  @override
  String get warehouseSubcontractOutboundBannerWaitingComponent =>
      'Waiting for component stock: once the component is received, the system adds a draft and notifies you';

  @override
  String warehouseSubcontractOutboundBannerIssuable(String qty) {
    return 'Issuable $qty';
  }

  @override
  String get warehouseSubcontractOutboundFactDraftNo => 'Outbound draft no.';

  @override
  String get warehouseSubcontractOutboundFactLatestIssue =>
      'Latest outbound document';

  @override
  String warehouseSubcontractOutboundHistoryTitle(int count) {
    return 'Outbound records ($count)';
  }

  @override
  String warehouseSubcontractOutboundLinesTitle(int count) {
    return 'Outbound lines ($count)';
  }

  @override
  String get warehouseSubcontractOutboundSaveDraft => 'Save draft';

  @override
  String get warehouseSubcontractOutboundApprove => 'Approve outbound';

  @override
  String get warehouseSubcontractOutboundClosePlan => 'Stop issuing';

  @override
  String get productionBatchTitle => 'Batch production and material request';

  @override
  String get productionBatchPermission =>
      'You do not have permission to arrange batch material requests.';

  @override
  String get productionBatchSelectTask =>
      'Select a waiting work order from workshop tasks.';

  @override
  String get productionBatchInvalidQuantity =>
      'Enter a positive quantity with up to four decimal places.';

  @override
  String get productionBatchPreviewFailed =>
      'Unable to review the producible batch. Please retry.';

  @override
  String get productionBatchReplay =>
      'This batch was already arranged; no duplicate tasks were created.';

  @override
  String productionBatchSubmittedReuse(String quantity, String unit) {
    return 'Arranged $quantity $unit using previously issued materials. Return to workshop tasks to start.';
  }

  @override
  String productionBatchSubmitted(
    String quantity,
    String unit,
    String remaining,
  ) {
    return 'Submitted the material request for $quantity $unit; $remaining $unit remain for a later batch.';
  }

  @override
  String productionBatchUncertain(String action) {
    return 'The result is not yet confirmed. Use “$action” to check this same request. The reviewed batch is retained.';
  }

  @override
  String productionBatchRejected(String message) {
    return '$message. Review the batch quantity and material summary again.';
  }

  @override
  String get productionBatchRetryRequest => 'Retry this material request';

  @override
  String get productionBatchRetryArrange => 'Retry this batch arrangement';

  @override
  String get productionBatchConfirmRequest => 'Confirm batch material request';

  @override
  String get productionBatchConfirmArrange => 'Confirm this production batch';

  @override
  String get productionBatchSubmitting => 'Submitting this batch';

  @override
  String get productionBatchSubmittingHint =>
      'Checking this batch\'s quantity and material sources. Please wait.';

  @override
  String get productionBatchProductFallback => 'Production item not confirmed';

  @override
  String get productionBatchPlan => 'Production plan';

  @override
  String get productionBatchWorkOrder => 'Work order';

  @override
  String get productionBatchOriginal => 'Awaiting production';

  @override
  String get productionBatchOriginalHint =>
      'Quantity awaiting arrangement for this work order';

  @override
  String get productionBatchReady => 'Complete-kit capacity';

  @override
  String get productionBatchReadyHint =>
      'Based on qualified physical materials';

  @override
  String get productionBatchSelected => 'Reviewed batch quantity';

  @override
  String get productionBatchSelectedHint =>
      'Quantity arranged upon confirmation';

  @override
  String get productionBatchRemaining => 'Remaining after this batch';

  @override
  String get productionBatchRemainingHint => 'Retained for later arrangement';

  @override
  String get productionBatchUnitUnknown => 'Unit not confirmed';

  @override
  String get productionBatchSetup => 'Arrange this production batch';

  @override
  String get productionBatchQuantity => 'Quantity for this batch';

  @override
  String productionBatchQuantityHint(String quantity, String unit) {
    return 'Up to $quantity $unit. After editing, review the material summary before confirming.';
  }

  @override
  String get productionBatchReview => 'Review material summary';

  @override
  String get productionBatchReviewReady => 'Batch reviewed';

  @override
  String get productionBatchNeedsReview => 'Quantity changed; review required';

  @override
  String get productionBatchNeedsReviewHint =>
      'The table shows the previous review. Review again before confirming this batch.';

  @override
  String get productionBatchNoKit => 'This batch cannot be arranged yet';

  @override
  String get productionBatchNoKitHint =>
      'Available materials cannot form a complete batch. Review again after materials are received.';

  @override
  String get productionBatchReuseHint =>
      'This batch uses materials already issued for earlier batches. Confirm, then return to workshop tasks to start.';

  @override
  String get productionBatchDirectTransferBadge =>
      'Workshop direct transfer · auto-issued';

  @override
  String get productionBatchDirectTransferHint =>
      'All materials of this batch come from same-workshop direct transfers (line-side warehouse): they are issued automatically on confirm. No draw request, no warehouse step — return to workshop tasks and start.';

  @override
  String productionBatchSubmittedDirectTransfer(String quantity, String unit) {
    return 'Batch of $quantity $unit arranged; direct-transfer materials were issued automatically. No draw needed — start right away.';
  }

  @override
  String get productionBatchFlow =>
      'Confirm request → Warehouse issues materials → Start in workshop';

  @override
  String productionBatchRemainingText(String quantity, String unit) {
    return 'After this batch, $quantity $unit remain for later arrangement.';
  }

  @override
  String get productionBatchAllRemaining =>
      'This batch covers all production remaining on this work order.';

  @override
  String get productionBatchMaterials => 'Materials for this batch';

  @override
  String productionBatchMaterialCount(int lines, int warehouses) {
    return '$lines material lines · $warehouses warehouses';
  }

  @override
  String get productionBatchWarehouse => 'Actual issue warehouse';

  @override
  String get productionBatchGoodsCode => 'Material code';

  @override
  String get productionBatchGoodsName => 'Material name';

  @override
  String get productionBatchColor => 'Color';

  @override
  String get productionBatchUnit => 'Issue unit';

  @override
  String get productionBatchMaterialQuantity => 'Quantity to request';

  @override
  String get productionBatchMaterialQuantityHint =>
      'Additional material needed for this batch, in this row\'s unit and actual warehouse.';

  @override
  String get productionBatchNoAdditionalMaterials =>
      'No additional materials are needed; arrange production using the existing material sources.';

  @override
  String get securityReasonBlocked => 'Blacklisted: entry denied';

  @override
  String get securityBlacklistTitle => 'Visitor Blacklist';

  @override
  String get securityBlacklistEmpty => 'No blacklisted visitors';

  @override
  String get securityBlacklistColNo => 'Visitor No.';

  @override
  String get securityBlacklistColName => 'Name';

  @override
  String get securityBlacklistColPhone => 'Phone';

  @override
  String get securityBlacklistColReason => 'Reason';

  @override
  String get securityBlacklistColAt => 'Blocked At';

  @override
  String get securityBlacklistColBy => 'By';

  @override
  String get securityBlacklistAction => 'Blacklist Visitor';

  @override
  String get securityBlacklistNoticeLabel => 'Visitor Blacklist';

  @override
  String get securityBlacklistNoticeDesc =>
      'Once blacklisted, the visitor immediately loses login and entry access; the action and reason are audited.';

  @override
  String get securityBlacklistReasonLabel => 'Reason';

  @override
  String get securityBlacklistReasonHint => 'Reason is required';

  @override
  String get securityBlacklistDone => 'Visitor blacklisted';

  @override
  String get securityBlacklistRemove => 'Remove from Blacklist';

  @override
  String get securityBlacklistRemoveConfirm =>
      'Remove this visitor from the blacklist? They can log in and apply again; existing applications keep their status.';

  @override
  String get securityBlacklistRemoveDone => 'Removed from blacklist';

  @override
  String get entryStaffSubtitle =>
      'Sign in with your staff account to enter the workspace';

  @override
  String get entryVisitorSubtitle =>
      'Visitors register with a phone code for quick entry';

  @override
  String get visitorColName => 'Name';

  @override
  String get visitorColPurpose => 'Purpose';

  @override
  String get visitorColHost => 'Host';

  @override
  String get visitorColPlannedVisit => 'Planned Visit';

  @override
  String get visitorColStatus => 'Status';

  @override
  String get visitorColCompany => 'Company';

  @override
  String get visitorColVisitorName => 'Visitor Name';

  @override
  String get visitorColHostDepartment => 'Host Department';

  @override
  String get visitorApplySubmittingOverlay =>
      'Submitting your application. Please do not resubmit or leave this page.';

  @override
  String get visitorApplyHostHint => 'Select the person to visit';

  @override
  String get visitorApplyHostSheetTitle => 'Select the person to visit';

  @override
  String get visitorApplyHostSearchEmpty =>
      'Search the person to visit by name';

  @override
  String get visitorApplyHostSearchHint =>
      'Type at least 2 characters; up to 5 matches are shown';

  @override
  String visitorSettingsPortalTag(Object app) {
    return '$app · Visitor';
  }

  @override
  String get visitorApprovalHostDeptColInfo =>
      'Department snapshot of the host at apply time; the header filter pushes hostDepartmentId to the backend.';

  @override
  String visitorBatchLimitError(int limit, int count) {
    return 'A single batch handles at most $limit items; please split it (currently $count)';
  }

  @override
  String visitorBatchApproveTitle(int count) {
    return 'Batch Approve ($count)';
  }

  @override
  String visitorBatchApproveMessage(int count) {
    return 'Each of the $count selected applications will be approved one by one; approval issues the entry QR code. To double-check hosts and purposes, open details by double-clicking a row.';
  }

  @override
  String get visitorBatchApproveConfirm => 'Confirm Batch Approve';

  @override
  String get visitorBatchActionLabel => 'Visitor Approval';

  @override
  String visitorBatchApproveResponsibility(int count) {
    return 'On confirmation, the selected $count applications will be recorded under your account as approver.';
  }

  @override
  String get visitorBatchVerbApprove => 'approved';

  @override
  String get visitorBatchVerbReject => 'rejected';

  @override
  String get visitorBatchVerbForward => 'forwarded';

  @override
  String visitorBatchResult(Object verb, int count) {
    return '$count applications $verb';
  }

  @override
  String visitorBatchResultFailures(int count) {
    return ', $count failed';
  }

  @override
  String visitorBatchResultSkipped(int count) {
    return ', $count skipped';
  }

  @override
  String visitorBatchIncomplete(Object verb, Object reason) {
    return 'Batch $verb did not fully complete: $reason';
  }

  @override
  String visitorBatchRejectTitle(int count) {
    return 'Batch Reject ($count)';
  }

  @override
  String visitorBatchRejectDescription(int count) {
    return 'The rejection reason will be shared with $count visitors; please describe the problem.';
  }

  @override
  String get visitorBatchRejectConfirm => 'Confirm Reject';

  @override
  String get visitorBatchSubjectLabel => 'visitor applications';

  @override
  String get visitorBatchForwardNoneSelected =>
      'All selected applications are already with their hosts; nothing to forward';

  @override
  String visitorBatchForwardTitle(int count) {
    return 'Batch Forward to Hosts ($count)';
  }

  @override
  String visitorBatchForwardMessage(int count) {
    return 'The $count selected applications will be forwarded to their hosts; after confirmation they return to this queue for your final approval.';
  }

  @override
  String visitorBatchForwardSkippedNote(int count) {
    return ' ($count more already with their hosts, skipped)';
  }

  @override
  String get visitorBatchForwardConfirm => 'Confirm Batch Forward';

  @override
  String visitorBatchForwardResponsibility(int count) {
    return 'On confirmation, forwarding the $count selected applications will be recorded under your account.';
  }

  @override
  String visitorBatchApproveButton(int count) {
    return 'Approve ($count)';
  }

  @override
  String visitorBatchForwardButton(int count) {
    return 'Forward ($count)';
  }

  @override
  String visitorBatchRejectButton(int count) {
    return 'Reject ($count)';
  }

  @override
  String get visitorApprovalDoneApprove => 'Visitor application approved';

  @override
  String get visitorApprovalDoneReject => 'Visitor application rejected';

  @override
  String get visitorApprovalDoneForward =>
      'Forwarded to the host for confirmation';

  @override
  String get visitorApprovalDoneFallback => 'Action completed';

  @override
  String get visitorApprovalApproveNoticeLabel => 'Visitor Approval';

  @override
  String get visitorApprovalApproveNoticeDesc =>
      'On confirmation your account and the decision are recorded; you are responsible for this entry approval.';

  @override
  String get visitorApprovalRejectNoticeLabel => 'Visitor Rejection';

  @override
  String get visitorApprovalRejectNoticeDesc =>
      'On confirmation your account and the rejection are recorded; you are responsible for this decision.';

  @override
  String get myVisitorsConfirmDone =>
      'Host confirmed; the application is back with HR';

  @override
  String get myVisitorsRejectDone => 'Host rejected';

  @override
  String get myVisitorsBatchNoneSelected =>
      'None of the selected applications await your confirmation';

  @override
  String myVisitorsBatchTitle(int count) {
    return 'Batch Confirm ($count)';
  }

  @override
  String myVisitorsBatchMessage(int count) {
    return 'Each of the $count selected visitors will be confirmed as hosted; applications then return to HR for final approval.';
  }

  @override
  String myVisitorsBatchSkippedNote(int count) {
    return ' ($count more not awaiting your confirmation, skipped)';
  }

  @override
  String get myVisitorsBatchConfirm => 'Confirm';

  @override
  String myVisitorsBatchResult(int count) {
    return '$count visitors confirmed as hosted';
  }

  @override
  String myVisitorsBatchIncomplete(Object reason) {
    return 'Batch confirmation did not fully complete: $reason';
  }

  @override
  String myVisitorsBatchButton(int count) {
    return 'Confirm ($count)';
  }

  @override
  String get myVisitorsStatusColInfo =>
      'Shows only items awaiting your confirmation by default; the header filter switches to forwarded / approved / rejected (pushed to the backend).';

  @override
  String get expenseFlowNew => 'New expense claim';

  @override
  String get expenseFlowEdit => 'Edit expense claim';

  @override
  String get expenseFlowSaveAndContinue => 'Save and add evidence';

  @override
  String get expenseFlowSaveDraft => 'Save draft';

  @override
  String get expenseFlowSave => 'Save';

  @override
  String get expenseFlowFlowGuide =>
      'Enter expenses → save draft → attach originals and register evidence → submit → finance records payment';

  @override
  String get expenseFlowInvoiceGuide =>
      'Save a draft, then attach invoice or other lawful evidence originals. Keep electronic evidence in its original format. Image recognition only suggests fields; it does not verify or archive evidence.';

  @override
  String get expenseFlowNoInvoiceGuide =>
      'Without an invoice, explain the circumstances and attach lawful evidence of the transaction for finance review.';

  @override
  String get expenseFlowApplicant => 'Applicant';

  @override
  String get expenseFlowDepartment => 'Department';

  @override
  String get expenseFlowDate => 'Created date';

  @override
  String get expenseFlowTitle => 'Claim title *';

  @override
  String get expenseFlowTitleHint => 'For example: client visit in Shanghai';

  @override
  String get expenseFlowTitleInfo =>
      'Summarize the purpose. This appears on the printed claim.';

  @override
  String get expenseFlowRemark => 'Purpose and explanation';

  @override
  String get expenseFlowRemarkHint =>
      'Travel, project, attendees, or explanation for missing invoices';

  @override
  String get expenseFlowMissingTitle => 'Enter a claim title';

  @override
  String get expenseFlowTitleLength =>
      'The claim title must be 200 characters or fewer';

  @override
  String get expenseFlowMissingItems => 'Add at least one expense item';

  @override
  String get expenseFlowItems => 'Expense items';

  @override
  String get expenseFlowAdd => 'Add';

  @override
  String get expenseFlowEmptyItems =>
      'Add an item with its category, actual amount and transaction date.';

  @override
  String get expenseFlowTotal => 'Claim total';

  @override
  String get expenseFlowCapital => 'Amount in Chinese capitals';

  @override
  String get expenseFlowDeleteItem => 'Remove item';

  @override
  String get expenseFlowDraftSaved =>
      'Draft saved. Add evidence before submitting for approval.';

  @override
  String get expenseFlowSaved => 'Saved';

  @override
  String get expenseFlowRejectedGuide =>
      'Returned for correction. Update the claim, save it and submit again.';

  @override
  String get expenseFlowLoadFailed => 'Unable to load. Try again.';

  @override
  String get expenseFlowNotEditable =>
      'Only the applicant can edit a draft or returned claim.';

  @override
  String get expenseFlowAmountInvalid =>
      'Enter a positive amount with at most two decimals, up to CNY 9999999999.99';

  @override
  String get expenseFlowInvoiceAmountInvalid =>
      'Use at most two decimals. Total must be positive; net and tax must be nonnegative.';

  @override
  String get expenseFlowOcrGuide =>
      'Choose an image to suggest fields, then check each field against the original. Recognition does not verify authenticity or save the original.';

  @override
  String get expenseFlowOcrConfirm =>
      'I checked the suggested fields against the original';

  @override
  String get expenseFlowOcrConfirmRequired =>
      'Check the suggested fields and confirm before saving';

  @override
  String get expenseFlowOriginalRequired =>
      'Upload the original on the detail page, then select the matching file here';

  @override
  String get expenseFlowInvoiceDateRequired => 'Select the evidence date';

  @override
  String get expenseFlowOtherNumberInvalid =>
      'Other evidence numbers allow letters, digits, slashes and hyphens, up to 60 characters. Enter the issuer.';

  @override
  String get expenseFlowVerify => 'Record verification';

  @override
  String get expenseFlowVerifyTitle => 'Manual evidence verification';

  @override
  String get expenseFlowVerifyGuide =>
      'Check the business transaction and original attachment. Verify tax invoices through the STA invoice verification platform or e-Tax service; verify other evidence through its applicable channel. Arithmetic checks and image recognition are not tax verification.';

  @override
  String get expenseFlowVerifyOfficial => 'Open the STA verification platform';

  @override
  String get expenseFlowVerifyRemark =>
      'Verification record (channel, result and notes) *';

  @override
  String get expenseFlowVerifyPassed => 'Verified';

  @override
  String get expenseFlowVerifyMismatch => 'Mismatch';

  @override
  String get expenseFlowVerifyRequired =>
      'Enter the verification channel and result';

  @override
  String get expenseFlowVerifyBeforeApprove =>
      'Record a successful manual verification for every invoice before approval';

  @override
  String get expenseFlowPaymentRecord => 'Record payment';

  @override
  String get expenseFlowPaymentConfirm => 'Confirm payment was made';

  @override
  String get expenseFlowPaymentGuide =>
      'Complete the actual payment first. This records that payment, updates the system account balance and creates accounting entries. It does not send a bank transfer.';

  @override
  String get expenseFlowPaymentDone =>
      'Payment recorded and accounting entries created';

  @override
  String get expenseFlowPrintDisclaimer =>
      'Internal claim display form. It does not replace original evidence, tax verification or statutory electronic archives.';

  @override
  String get expenseFlowSettingsTitle => 'Expense settings';

  @override
  String get expenseFlowSettingsDescription =>
      'Finance maintains company details and evidence requirements shown automatically to applicants.';

  @override
  String get expenseFlowCompanyName => 'Company name';

  @override
  String get expenseFlowCompanyTaxNo => 'Taxpayer identification number';

  @override
  String get expenseFlowSubmissionGuide => 'Claim and evidence instructions';

  @override
  String get expenseFlowRequireInvoice =>
      'Require registered invoices for submission';

  @override
  String get expenseFlowRequireInvoiceHint =>
      'When disabled, lawful original evidence and an explanation for missing invoices are still required.';

  @override
  String get expenseFlowSettingsSaved => 'Expense settings saved';

  @override
  String get expenseFlowSettingsSave => 'Save settings';

  @override
  String get expenseFlowSettingsLoadFailed => 'Unable to load expense settings';

  @override
  String get expenseFlowRetry => 'Retry';

  @override
  String get expenseFlowCompanyNameRequired => 'Enter the company name';

  @override
  String get expenseFlowSettingsEntryDescription =>
      'Company name, tax ID and evidence requirements';

  @override
  String get expenseFlowApprovalEntryDescription =>
      'Verify evidence, review claims and record payment';

  @override
  String get expenseFlowApprovalTitle => 'Expense approval';

  @override
  String get expenseFlowInvoiceRequiredGuide =>
      'Finance requires a registered invoice linked to its original file before submission.';

  @override
  String get expenseFlowReadEvidenceRequired =>
      'Approval requires evidence preview and download permission. Contact an authorizer.';

  @override
  String get expenseFlowHistory => 'Processed';

  @override
  String get expenseFlowPendingCorrection => 'Needs correction';

  @override
  String get expenseFlowPaymentProofs =>
      'Payment proof (bank receipt or signed cash receipt)';

  @override
  String get expenseFlowPaymentProofGuide =>
      'Complete the actual payment and upload its receipt before recording payment.';

  @override
  String get expenseFlowPaymentProofRequired =>
      'Upload payment proof before confirming that payment was made.';

  @override
  String get expenseFlowItemPurpose => 'Expense purpose *';

  @override
  String get expenseFlowItemPurposeHint =>
      'Describe the actual business purpose, such as the client, project or trip.';

  @override
  String get expenseFlowItemPurposeRequired => 'Enter the expense purpose';

  @override
  String get goodsLearnedPriceUnconfirmed =>
      'Verify the price unit and currency';

  @override
  String get goodsLearnedPriceTaxRate => 'Tax rate';

  @override
  String get shelfLocationQuantityHint =>
      'Locations are storage suggestions. Quantities are totals for the actual warehouse and color, not counts at a specific shelf location.';

  @override
  String get shelfActualWarehouse => 'Actual warehouse';

  @override
  String get shelfMasterOnly => 'Master suggestion (no warehouse)';

  @override
  String get shelfChooseWarehouseForRack =>
      'Select one physical warehouse to view its rack diagram. The table lists each warehouse separately.';

  @override
  String get warehouseGoodsMasterDefaultHint =>
      'The goods master default warehouse was filled in. Verify the actual destination for this receipt.';

  @override
  String get warehouseSuggestedDestinationHint =>
      'A suggested warehouse was filled in. Verify the actual destination.';

  @override
  String get warehouseBatchRegistrationHelp =>
      'Each line needs a warehouse and location. Goods master defaults take precedence over personal warehouse context. Selected lines can be edited together. Each report creates its own inspection submission; final receipt follows quality release.';
}
