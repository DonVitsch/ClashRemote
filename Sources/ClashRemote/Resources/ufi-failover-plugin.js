(async () => {
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  const PAGE = `http://${location.hostname}:7788/ui/cr-failover.html`;

  const openModal = () => {
    document.querySelector('#cr_failover_modal')?.remove();
    const { id } = createModal({
      name: 'cr_failover_modal',
      title: '超时自动换节点',
      maxWidth: '820px',
      isMask: true,
      showConfirm: false,
      contentStyle: 'max-height:82vh;',
      onClose: () => true,
      content: `
        <div style="display:flex;flex-direction:column;gap:10px;">
          <div style="font-size:.72rem;line-height:1.7;opacity:.82;">
            守护跑在设备上，关这个窗口也继续。下面是实时页面，手机电脑都能打开：
            <div style="margin-top:6px;word-break:break-all;">${PAGE}</div>
          </div>
          <iframe src="${PAGE}" style="width:100%;height:68vh;border:0;border-radius:14px;background:#12141a;"></iframe>
        </div>
      `,
    });
    showModal(id);
  };

  const btn = document.createElement('button');
  btn.textContent = '超时换节点';
  btn.dataset.crFailover = '1';
  btn.onclick = openModal;

  while (!document.querySelector('.actions-buttons')) await wait(150);
  if (!document.querySelector('[data-cr-failover="1"]')) {
    document.querySelector('.actions-buttons')?.appendChild(btn);
  }
})();
