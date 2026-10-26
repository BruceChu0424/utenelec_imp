(() => {
  'use strict';
  const language = (navigator.language || 'zh').split('-')[0];
  const strings = {
    zh: {
      updating: '服务器正在更新中', scheduled: '服务器即将更新', recovery: '服务恢复需要管理员确认',
      intro: '正在更新服务并检查运行状态。请保留当前窗口，恢复后会自动进入系统。',
      scheduledIntro: '请先保存其他窗口中的工作。更新开始时，连接会暂时中断。',
      recoveryIntro: '更新尚未完成。请保留当前窗口并联系管理员，服务通过检查后会自动进入系统。',
      hint: '如果您在其他窗口编辑单据，请保留那些窗口。恢复连接后，先核对提交结果，再继续操作。',
      version: '目标版本', starts: '开始时间（北京时间）', notice: '更新预告已发布', update: '服务更新中', awaitRecovery: '等待恢复服务', waitingUpdate: '等待更新开始',
      return: '恢复后返回工作', retry: '检查恢复状态', checking: '正在检查', waiting: '将自动检查服务恢复状态',
      unavailable: '暂时无法读取更新状态，正在继续检查。', ready: '服务已恢复，正在进入系统…',
    },
    en: {
      updating: 'The server is being updated', scheduled: 'Server update coming soon', recovery: 'Service recovery needs administrator attention',
      intro: 'The service is being updated and checked. Keep this window open; the system will open when it is ready.',
      scheduledIntro: 'Save your work in other windows. The connection will pause when the update starts.',
      recoveryIntro: 'The update is not complete. Keep this window open and contact an administrator. The system will open after service checks pass.',
      hint: 'Keep other windows open if you are editing documents. After reconnecting, check submission results before continuing.',
      version: 'Target version', starts: 'Starts at (Beijing time)', notice: 'Update notice published', update: 'Updating service', awaitRecovery: 'Waiting for service recovery', waitingUpdate: 'Waiting for the update to start',
      return: 'Return to work when ready', retry: 'Check recovery', checking: 'Checking', waiting: 'Service recovery is checked automatically',
      unavailable: 'The update status is temporarily unavailable. Checks will continue.', ready: 'The service is ready. Opening the system…',
    },
    ko: {
      updating: '서버 업데이트 중', scheduled: '서버 업데이트 예정', recovery: '서비스 복구에 관리자 확인이 필요합니다',
      intro: '서비스 업데이트와 상태 확인을 진행 중입니다. 이 창을 유지하면 준비 완료 후 시스템으로 이동합니다.',
      scheduledIntro: '다른 창에서 진행 중인 작업을 저장하세요. 업데이트가 시작되면 연결이 일시 중단됩니다.',
      recoveryIntro: '업데이트가 완료되지 않았습니다. 창을 유지하고 관리자에게 문의하세요. 서비스 검사 통과 후 시스템으로 이동합니다.',
      hint: '문서를 편집 중인 다른 창을 유지하세요. 재연결 후 제출 결과를 확인한 다음 계속 작업하세요.',
      version: '대상 버전', starts: '시작 시간 (베이징 시간)', notice: '업데이트 사전 공지 게시됨', update: '서비스 업데이트 중', awaitRecovery: '서비스 복구 대기 중', waitingUpdate: '업데이트 시작 대기 중',
      return: '복구 후 작업으로 돌아가기', retry: '복구 상태 확인', checking: '확인 중', waiting: '서비스 복구 상태를 자동으로 확인합니다',
      unavailable: '업데이트 상태를 일시적으로 읽을 수 없습니다. 확인을 계속합니다.', ready: '서비스가 복구되었습니다. 시스템으로 이동 중…',
    },
  };
  const text = strings[language] || strings.zh;
  document.documentElement.lang = strings[language] ? language : 'zh-CN';
  const element = (id) => document.getElementById(id);
  const retry = element('retry');
  const status = element('status');
  element('heading').textContent = text.updating;
  element('intro').textContent = text.intro;
  element('hint').textContent = text.hint;
  element('step-notice').textContent = text.notice;
  element('step-update').textContent = text.update;
  element('step-return').textContent = text.return;
  retry.textContent = text.retry;
  status.textContent = text.waiting;
  let timer;
  let busy = false;
  let returning = false;
  async function readJson(path, signal) {
    const response = await fetch(path, { cache: 'no-store', credentials: 'omit', redirect: 'error', signal });
    if (!response.ok || !response.headers.get('content-type')?.includes('application/json')) throw new Error('Status unavailable');
    return response.json();
  }
  async function check() {
    if (busy || returning || document.hidden) return;
    clearTimeout(timer);
    busy = true;
    retry.disabled = true;
    retry.textContent = text.checking;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 5000);
    let interval = 10000;
    try {
      const state = await readJson('/api/system/maintenance', controller.signal);
      if (state.schemaVersion !== 1 || !['available', 'scheduled', 'updating', 'recovery_required'].includes(state.state)) throw new Error('Invalid status');
      const recovery = state.state === 'recovery_required';
      const scheduled = state.state === 'scheduled';
      document.body.classList.toggle('recovery', recovery);
      element('heading').textContent = recovery ? text.recovery : scheduled ? text.scheduled : text.updating;
      element('intro').textContent = recovery ? text.recoveryIntro : scheduled ? text.scheduledIntro : text.intro;
      element('step-notice').className = scheduled ? 'current' : 'done';
      element('step-update').className = scheduled ? '' : 'current';
      element('step-update').textContent = recovery ? text.awaitRecovery : scheduled ? text.waitingUpdate : text.update;
      document.title = `${element('heading').textContent} · 优腾`;
      const version = typeof state.targetVersion === 'string' && /^v?\d{1,4}\.\d{1,4}\.\d{1,4}$/.test(state.targetVersion) ? state.targetVersion : null;
      element('version').hidden = !version;
      element('version').textContent = version ? `${text.version} ${version}` : '';
      const startsAt = typeof state.startsAt === 'string' ? new Date(state.startsAt) : null;
      const showStart = scheduled && startsAt && Number.isFinite(startsAt.getTime());
      element('start').hidden = !showStart;
      element('start').textContent = showStart
        ? `${text.starts} ${new Intl.DateTimeFormat(document.documentElement.lang, { timeZone: 'Asia/Shanghai', dateStyle: 'medium', timeStyle: 'short' }).format(startsAt)}`
        : '';
      if (Number.isInteger(state.retryAfterSeconds)) interval = Math.max(5, Math.min(60, state.retryAfterSeconds)) * 1000;
      status.textContent = text.waiting;
      if (state.state === 'available') {
        const health = await readJson('/actuator/health/readiness', controller.signal);
        if (health.status === 'UP') {
          returning = true;
          status.textContent = text.ready;
          // This static page has no editors. Existing Flutter windows stay
          // mounted and never use this reload path.
          if (window.location.pathname === '/maintenance.html') window.location.replace('/');
          else window.location.reload();
        }
      }
    } catch (_) {
      status.textContent = text.unavailable;
    } finally {
      clearTimeout(timeout);
      busy = false;
      retry.disabled = false;
      retry.textContent = text.retry;
      if (!document.hidden && !returning) timer = setTimeout(check, interval);
    }
  }
  retry.addEventListener('click', check);
  document.addEventListener('visibilitychange', () => {
    clearTimeout(timer);
    if (!document.hidden) check();
  });
  check();
})();
