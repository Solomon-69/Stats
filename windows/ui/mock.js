// mock.js. Pretend backend for previewing the screens in an ordinary browser (no Tauri). Never used inside the app.
(function () {
  if (window.__TAURI__) return;
  window.__MOCK = true;
  const q = new URLSearchParams(location.search);
  const mode = q.get('mock') || 'full';           // full | desktop (no battery, no sensors)
  let t = 0;
  const GB = 1024 ** 3;
  const wave = (a, b, p) => a + (b - a) * (0.5 + 0.5 * Math.sin(t / p));
  const snap = () => {
    t++;
    const cores = Array.from({ length: 8 }, (_, i) => Math.max(0.02, Math.min(1, wave(0.08, 0.7, 3 + i) * (0.6 + 0.04 * i))));
    const cpu = cores.reduce((a, b) => a + b, 0) / cores.length;
    return {
      cpu, cores,
      mem_used: wave(9, 12.5, 40) * GB, mem_total: 16 * GB, swap_used: 1.2 * GB, swap_total: 4 * GB,
      disks: [{ name: 'Windows', mount: 'C:\\', total: 476 * GB, free: 142 * GB }, { name: 'Data', mount: 'D:\\', total: 931 * GB, free: 612 * GB }],
      disk_read_bps: wave(0.2e6, 9e6, 5), disk_write_bps: wave(0.1e6, 4e6, 7),
      net_down_bps: wave(0.1e6, 6e6, 4), net_up_bps: wave(0.02e6, 0.8e6, 6), net_online: true, net_name: 'Wi-Fi',
      net_total_down: 38 * GB, net_total_up: 4 * GB,
      battery: mode === 'desktop' ? null : { percent: 63, plugged_in: false, charging: false, full: false, seconds_left: 14400, health: 91, watts: 8.4 },
      temps: mode === 'desktop' ? [] : [{ label: 'CPU Package', c: wave(48, 66, 9) }, { label: 'NVMe Drive', c: 41 }],
      top_cpu: [{ name: 'chrome', cpu: 0.12, mem: 1.4 * GB }, { name: 'Code', cpu: 0.05, mem: 0.8 * GB }, { name: 'explorer', cpu: 0.01, mem: 0.2 * GB }],
      top_mem: [{ name: 'chrome', cpu: 0.12, mem: 1.4 * GB }, { name: 'Code', cpu: 0.05, mem: 0.8 * GB }, { name: 'Teams', cpu: 0, mem: 0.6 * GB }],
      self_cpu: 0.002, self_mem: 41 * 1024 * 1024,
    };
  };
  const cmds = {
    snapshot: snap,
    machine_info: () => ({ model: 'ThinkPad X1 Carbon', cpu: 'Intel(R) Core(TM) i7-1365U', cores: 12, ram: 16 * GB, os: 'Windows 11 Pro' }),
    fit_panel: () => {}, hide_panel: () => {}, open_settings: () => {}, quit: () => {}, notify: () => {}, open_url: (a) => console.log('open', a.url),
    test_mode: () => q.get('test') || null, test_report: (a) => { window.__report = a.report; },
    get_autostart: () => false, set_autostart: (a) => a.on, set_icon_style: () => {},
  };
  window.__TAURI__ = {
    core: { invoke: async (name, args) => cmds[name](args || {}) },
    event: { listen: async () => () => {}, emit: async () => {} },
  };
})();
