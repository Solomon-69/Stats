// app.js. The panel and the Settings window share this file; ?w=panel or ?w=settings picks which one to draw.
(() => {
  const VERSION = '1.0.3';
  const T = window.__TAURI__;
  const invoke = (n, a) => T.core.invoke(n, a);
  const params = new URLSearchParams(location.search);
  const root = document.documentElement;
  const errors = [];
  window.addEventListener('error', (e) => errors.push(String(e.message)));
  window.addEventListener('unhandledrejection', (e) => errors.push(String(e.reason)));

  let W = params.get('w') || 'panel';
  let testOpt = {};
  let testView = null;

  // ---------- preferences ----------
  const DEF = { appearance: 'auto', accent: 0, icon: 'bars', mods: {}, temp: 'c', speed: 'bits', refresh: 2, alerts: true, checks: true };
  const load = () => { try { return { ...DEF, ...JSON.parse(localStorage.getItem('stats.prefs') || '{}') }; } catch { return { ...DEF }; } };
  let P = load();
  const save = () => { try { localStorage.setItem('stats.prefs', JSON.stringify(P)); } catch {} T.event.emit('prefs-changed', {}); };

  const ACC = [['Graphite', '#454952', '#C5C9D2'], ['Blue', '#2160C4', '#82B1F2'], ['Teal', '#0B7268', '#4FD1C0'], ['Orchid', '#B0307F', '#E25AA4'], ['Orange', '#B04A0A', '#F59A4A']];
  const mq = matchMedia('(prefers-color-scheme: dark)');
  function applyTheme() {
    const mode = testOpt.theme || P.appearance;
    const dark = mode === 'auto' ? mq.matches : mode === 'dark';
    root.dataset.theme = dark ? 'dark' : 'light';
    if (W === 'settings') {
      const a = ACC[Math.min(Math.max(testOpt.accent != null ? +testOpt.accent : P.accent, 0), ACC.length - 1)];
      root.style.setProperty('--brand', dark ? a[2] : a[1]);
    }
  }
  mq.addEventListener?.('change', applyTheme);

  // ---------- formatting ----------
  const pct = (f) => Math.round(Math.min(Math.max(f, 0), 1) * 100) + '%';
  const bytes = (n) => {
    const u = ['B', 'KB', 'MB', 'GB', 'TB']; let i = 0;
    while (n >= 1024 && i < 4) { n /= 1024; i++; }
    return (i >= 3 ? n.toFixed(1) : i === 2 ? n.toFixed(n < 10 ? 1 : 0) : Math.round(n)) + ' ' + u[i];
  };
  const rate = (bps) => {
    if (P.speed === 'bits') {
      let b = bps * 8; const u = ['bps', 'Kbps', 'Mbps', 'Gbps']; let i = 0;
      while (b >= 1000 && i < 3) { b /= 1000; i++; }
      return [i === 0 ? Math.round(b) : b.toFixed(b < 10 ? 1 : 0), u[i]];
    }
    const s = bytes(bps).split(' ');
    return [s[0], s[1] + '/s'];
  };
  const rateText = (bps) => rate(bps).join(' ');
  const temp = (c) => P.temp === 'f' ? [Math.round(c * 9 / 5 + 32), '°F'] : [Math.round(c), '°C'];
  const tempWord = (c) => c < 55 ? 'Cool' : c < 75 ? 'Warm' : c < 90 ? 'Hot' : 'Very hot';
  const dur = (s) => { const m = Math.round(s / 60); const h = Math.floor(m / 60); return h ? `${h} h ${m % 60} min` : `${m} min`; };
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
  const pressure = (s) => { const f = s.mem_used / Math.max(s.mem_total, 1); return f >= 0.95 ? 4 : f >= 0.85 ? 2 : 1; };

  // ---------- icons ----------
  const I = (d) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">${d}</svg>`;
  const ICON = {
    cpu: I('<rect x="7" y="7" width="10" height="10" rx="2"/><path d="M10 3v4M14 3v4M10 17v4M14 17v4M3 10h4M3 14h4M17 10h4M17 14h4"/>'),
    memory: I('<rect x="3" y="7.5" width="18" height="9" rx="1.8"/><path d="M7 16.5v2M11 16.5v2M15 16.5v2M7 11v2M12 11v2M17 11v2"/>'),
    disk: I('<path d="M4 14l2.2-7.2A2 2 0 0 1 8.1 5.4h7.8a2 2 0 0 1 1.9 1.4L20 14"/><rect x="3" y="14" width="18" height="5.5" rx="2"/><path d="M7 16.8h.01M10 16.8h.01"/>'),
    diskio: I('<path d="M4 8h14M14 4l4 4-4 4M20 16H6M10 12l-4 4 4 4"/>'),
    network: I('<path d="M8 20V5M4 9l4-4 4 4M16 4v15M12 15l4 4 4-4"/>'),
    battery: I('<rect x="2.5" y="7.5" width="16" height="9" rx="2.2"/><path d="M21 11v2"/><rect x="5" y="10" width="7" height="4" rx=".8" fill="currentColor" stroke="none"/>'),
    sensors: I('<path d="M14 14.8V5a2 2 0 0 0-4 0v9.8a4 4 0 1 0 4 0z"/><path d="M12 9v7"/>'),
    chev: I('<path d="M6 9l6 6 6-6"/>'),
    sliders: I('<path d="M4 7h9M17 7h3M4 17h3M11 17h9"/><circle cx="15" cy="7" r="2"/><circle cx="9" cy="17" r="2"/>'),
    look: I('<circle cx="12" cy="12" r="8"/><path d="M12 4v16"/><path d="M12 4a8 8 0 0 1 0 16" fill="currentColor"/>'),
    watch: I('<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z"/><circle cx="12" cy="12" r="2.8"/>'),
    gear: I('<circle cx="12" cy="12" r="3"/><path d="M12 3v2.5M12 18.5V21M3 12h2.5M18.5 12H21M5.6 5.6l1.8 1.8M16.6 16.6l1.8 1.8M5.6 18.4l1.8-1.8M16.6 7.4l1.8-1.8"/>'),
    info: I('<circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8h.01"/>'),
  };

  // ---------- history ----------
  const N = 60;
  const H = { cpu: [], temp: [], down: [], up: [], rd: [], wr: [] };
  const push = (a, v) => { a.push(v); if (a.length > N) a.shift(); };

  function spark(series, max) {
    const m = max || Math.max(1, ...series.flatMap((s) => s.v));
    const paths = series.map((s) => {
      const v = s.v.length ? s.v : [0];
      const pad = Array(Math.max(0, N - v.length)).fill(v[0]).concat(v);
      const pts = pad.map((y, i) => `${((i / (N - 1)) * 100).toFixed(1)},${(28 - Math.min(y / m, 1) * 26).toFixed(1)}`).join(' ');
      return `<polyline points="${pts}" fill="none" stroke="${s.color}" stroke-width="1.7" stroke-linejoin="round" stroke-linecap="round" vector-effect="non-scaling-stroke"/>`;
    }).join('');
    return `<svg viewBox="0 0 100 30" preserveAspectRatio="none" class="@C">${paths}</svg>`;
  }
  const segs = (f, tint) => {
    const on = Math.round(Math.min(Math.max(f, 0), 1) * 10);
    return `<div class="segs" style="--tint:${tint}">${Array.from({ length: 10 }, (_, i) => `<i class="${i < on ? 'on' : ''}"></i>`).join('')}</div>`;
  };
  const drow = (a, b) => `<div class="drow"><span>${esc(a)}</span><b>${esc(b)}</b></div>`;
  const dh = (t) => `<div class="dh">${esc(t)}</div>`;
  const procList = (arr, memFirst) => arr.length ? arr.map((p) => drow(p.name, memFirst ? bytes(p.mem) : pct(p.cpu))).join('') : drow('Nothing busy', '');

  // ---------- tiles ----------
  const TINT = { cpu: '#D6402B', memory: '#1F9D6B', disk: '#C9A227', diskio: '#D9702A', network: '#2E86D1', battery: '#5E9E00', sensors: '#D1347F' };
  const sysDisk = (s) => s.disks.find((d) => /^c:/i.test(d.mount)) || s.disks[0];
  const battLine = (b) => {
    if (b.plugged_in && (b.full || (!b.charging && b.percent >= 99))) return 'Fully charged';
    if (b.charging) return b.seconds_left ? `Charging · ${dur(b.seconds_left)} to full` : 'Charging';
    if (b.plugged_in) return 'Plugged in, not charging';
    return b.seconds_left ? `${dur(b.seconds_left)} left` : 'Working out time left';
  };
  const big = (v, u) => `<div class="big">${esc(v)}${u ? `<small>${esc(u)}</small>` : ''}</div>`;
  const TILES = [
    { id: 'cpu', title: 'Processor', avail: () => true,
      body(s) {
        const top = s.top_cpu[0];
        const sub = top && top.cpu > 0.08 ? 'Busiest: ' + (top.name.length > 15 ? top.name.slice(0, 14) + '…' : top.name) : 'Mostly resting';
        return { mid: big(pct(s.cpu)), spark: spark([{ v: H.cpu, color: TINT.cpu }], 1), sub, bar: segs(s.cpu, TINT.cpu) };
      },
      detail: (s) => dh('Each core') + `<div class="cores" style="--tint:${TINT.cpu}">${s.cores.map((c) => `<i><b style="height:${Math.max(4, c * 100)}%"></b></i>`).join('')}</div>` + dh('Busiest apps') + procList(s.top_cpu, false) },
    { id: 'memory', title: 'Memory', avail: () => true,
      body(s) {
        const f = s.mem_used / Math.max(s.mem_total, 1);
        const p = pressure(s);
        const w = p === 4 ? ['Squeezed', 'var(--bad)'] : p === 2 ? ['Filling up', 'var(--warn)'] : ['Roomy', 'var(--good)'];
        const swap = s.swap_used > 1e6 ? ' · Swap ' + bytes(s.swap_used) : '';
        return { mid: big(pct(f)) + `<span class="state" style="--tint:${w[1]}">${w[0]}</span>`, sub: `${bytes(s.mem_used)} of ${bytes(s.mem_total)}${swap}`, bar: segs(f, TINT.memory) };
      },
      detail: (s) => dh('Right now') + drow('In use', bytes(s.mem_used)) + drow('Free', bytes(Math.max(s.mem_total - s.mem_used, 0))) + drow('Page file', s.swap_total ? `${bytes(s.swap_used)} of ${bytes(s.swap_total)}` : 'None') + dh('Using the most') + procList(s.top_mem, true) },
    { id: 'disk', title: 'Storage', avail: (s) => s.disks.length > 0,
      body(s) {
        const d = sysDisk(s); const used = d.total ? 1 - d.free / d.total : 0;
        const u = d.free > 0 ? Math.min(used, 0.99) : used;
        return { mid: `<div class="big" style="${u > 0.9 ? 'color:var(--bad)' : ''}">${pct(u)}</div>`, sub: `${bytes(d.free)} free of ${bytes(d.total)}`, bar: segs(u, u > 0.9 ? 'var(--bad)' : TINT.disk) };
      },
      detail: (s) => dh('Drives') + s.disks.map((d) => drow(`${d.mount.replace(/\\$/, '')} ${d.name || ''}`.trim(), `${bytes(d.free)} free of ${bytes(d.total)}`) + segs(d.total ? 1 - d.free / d.total : 0, TINT.disk)).join('') },
    { id: 'diskio', title: 'Disk activity', avail: () => true,
      body(s) {
        const r = rate(s.disk_read_bps);
        return { mid: big(r[0], r[1]), spark: spark([{ v: H.rd, color: TINT.diskio }, { v: H.wr, color: 'var(--second)' }]), sub: 'Write ' + rateText(s.disk_write_bps) };
      },
      detail: (s) => dh('Right now') + drow('Reading', rateText(s.disk_read_bps)) + drow('Writing', rateText(s.disk_write_bps)) },
    { id: 'network', title: 'Internet', avail: () => true,
      body(s) {
        if (!s.net_online) return { mid: big('Offline'), sub: 'Not connected' };
        const r = rate(s.net_down_bps);
        return { mid: big(r[0], r[1]), spark: spark([{ v: H.down, color: TINT.network }, { v: H.up, color: 'var(--second)' }]), sub: 'Upload ' + rateText(s.net_up_bps) };
      },
      detail: (s) => dh('Right now') + drow('Connection', s.net_name || 'None') + drow('Downloading', rateText(s.net_down_bps)) + drow('Uploading', rateText(s.net_up_bps)) + dh('Since the PC started') + drow('Downloaded', bytes(s.net_total_down)) + drow('Uploaded', bytes(s.net_total_up)) + dh('Speed test') + `<div class="drow"><span>${esc(speedText)}</span><button class="btn mini" data-speed ${speedBusy ? 'disabled' : ''}>Test speed</button></div>` },
    { id: 'battery', title: 'Battery', avail: (s) => !!s.battery,
      body(s) { const b = s.battery; return { mid: big(Math.round(b.percent) + '%'), sub: battLine(b), bar: segs(b.percent / 100, b.percent < 15 && !b.plugged_in ? 'var(--bad)' : TINT.battery) }; },
      detail: (s) => { const b = s.battery; return dh('Battery') + drow('Charge', Math.round(b.percent) + '%') + drow('Health', b.health ? Math.round(b.health) + '%' : 'Not reported') + drow('Power', b.watts ? b.watts.toFixed(1) + ' W' : 'Not reported') + drow('Power cable', b.plugged_in ? 'Plugged in' : 'Not plugged in'); } },
    { id: 'sensors', title: 'Temperature', avail: (s) => s.temps.length > 0,
      body(s) { const c = mainTemp(s); const t = temp(c); return { mid: big(t[0], t[1]), spark: spark([{ v: H.temp, color: TINT.sensors }], 1), sub: tempWord(c) }; },
      detail: (s) => dh('Sensors') + s.temps.slice(0, 8).map((t) => drow(t.label, temp(t.c).join(''))).join('') },
  ];
  const mainTemp = (s) => { const cpu = s.temps.find((t) => /cpu|core|package/i.test(t.label)); return (cpu || s.temps.slice().sort((a, b) => b.c - a.c)[0]).c; };
  const enabled = (id) => P.mods[id] !== false;
  let speedText = 'Not tested yet', speedBusy = false;
  async function speedTest() {
    if (speedBusy) return; speedBusy = true; speedText = 'Testing…'; render();
    try {
      const ctl = new AbortController(); let got = 0; const t0 = performance.now();
      const stop = setTimeout(() => ctl.abort(), 9000);
      await Promise.all([0, 1, 2, 3].map(async () => {
        try {
          const r = await fetch('https://speed.cloudflare.com/__down?bytes=25000000', { cache: 'no-store', signal: ctl.signal });
          const rd = r.body.getReader();
          for (;;) { const { done, value } = await rd.read(); if (done) break; got += value.length; }
        } catch {}
      }));
      clearTimeout(stop);
      const down = got * 8 / ((performance.now() - t0) / 1000) / 1e6;
      speedText = `Testing upload…`; render();
      const t1 = performance.now(); let sent = 0; const ctl2 = new AbortController(); const stop2 = setTimeout(() => ctl2.abort(), 7000);
      await Promise.all([0, 1, 2, 3].map(async () => { try { await fetch('https://speed.cloudflare.com/__up', { method: 'POST', body: new Uint8Array(3e6), signal: ctl2.signal }); sent += 3e6; } catch {} }));
      clearTimeout(stop2);
      const up = sent * 8 / ((performance.now() - t1) / 1000) / 1e6;
      speedText = got > 0 ? `Download ${down.toFixed(down < 10 ? 1 : 0)} Mbps · Upload ${sent > 0 ? up.toFixed(up < 10 ? 1 : 0) + ' Mbps' : 'not measured'}` : 'Could not reach the speed test. Are you online?';
    } catch { speedText = 'Could not run the speed test.'; }
    speedBusy = false; render();
  }

  // ---------- panel ----------
  let S = null, machine = null, timer = null, shell, grid, steady = { text: 'Everything looks calm', tint: 'var(--good)', at: 0 };
  const els = {};

  function judge(s) {
    const avg = H.cpu.length ? H.cpu.reduce((a, b) => a + b, 0) / H.cpu.length : s.cpu;
    const t = s.temps.length ? mainTemp(s) : null; const p = pressure(s); const b = s.battery;
    if (p >= 4) return { text: 'Memory is squeezed', tint: 'var(--bad)' };
    if (t != null && t >= 90) return { text: 'Running hot', tint: 'var(--bad)' };
    if (avg > 0.8) return { text: 'Working hard', tint: 'var(--hard)' };
    if (p === 2) return { text: 'Memory is getting full', tint: 'var(--hard)' };
    if (b && !b.plugged_in && b.percent < 15) return { text: 'Battery is low', tint: 'var(--hard)' };
    if (avg > 0.45) return { text: 'Busy', tint: 'var(--warn)' };
    if (t != null && t >= 75) return { text: 'Warm', tint: 'var(--warn)' };
    return { text: 'Everything looks calm', tint: 'var(--good)' };
  }

  function buildPanel() {
    document.getElementById('app').innerHTML = `<div class="stage"><div class="shell" id="shell"><div id="inner">
      <div class="head"><h1 id="model">This PC</h1><div class="pill" id="pill" style="--tint:var(--good)"><i></i><span id="ptxt">Looking…</span></div></div>
      <div class="chips" id="chips"></div><div class="grid" id="grid"></div>
      <div class="foot"><button class="fbtn" id="bset">${ICON.sliders}Settings</button><button class="fbtn" id="bquit">Quit</button></div></div></div></div>`;
    shell = document.getElementById('shell'); grid = document.getElementById('grid');
    document.getElementById('bset').onclick = () => invoke('open_settings');
    document.getElementById('bquit').onclick = () => invoke('quit');
    document.addEventListener('keydown', (e) => { if (e.key === 'Escape') invoke('hide_panel'); });
    new ResizeObserver(fit).observe(document.getElementById('inner'));
    invoke('machine_info').then((m) => { machine = m; paintMachine(); }).catch((e) => errors.push(String(e)));
  }
  let lastFit = 0;
  function fit() { const h = Math.ceil(shell.scrollHeight + 22); if (Math.abs(h - lastFit) > 1) { lastFit = h; invoke('fit_panel', { height: h }); } }
  function paintMachine() {
    if (!machine) return;
    document.getElementById('model').textContent = machine.model;
    const cpu = machine.cpu.replace(/\((R|TM)\)/g, '').replace(/\bCPU\b|@.*$|\d+-Core Processor|Processor/gi, '').replace(/\s+/g, ' ').trim();
    const chips = [cpu, `${machine.cores} cores`, bytes(machine.ram).replace(/\.0 /, ' '), machine.os.replace(/^Windows/, 'Windows')].filter(Boolean);
    document.getElementById('chips').innerHTML = chips.map((c) => `<span class="chip">${esc(c)}</span>`).join('');
  }

  function render() {
    if (!S || !grid) return;
    const now = Date.now();
    if (now - steady.at > 60000) { steady = { ...judge(S), at: now }; }
    const pill = document.getElementById('pill'); pill.style.setProperty('--tint', steady.tint); document.getElementById('ptxt').textContent = steady.text;
    const want = TILES.filter((t) => t.avail(S) && enabled(t.id));
    Object.keys(els).forEach((id) => { if (!want.find((t) => t.id === id)) { els[id].el.remove(); delete els[id]; } });
    want.forEach((t, idx) => {
      let e = els[t.id];
      if (!e) {
        const el = document.createElement('div'); el.className = 'tile'; el.dataset.id = t.id; el.style.setProperty('--tint', TINT[t.id]);
        el.innerHTML = `<div class="trow"><div class="ico">${ICON[t.id]}</div><div class="ttl">${t.title}</div><div class="chev">${ICON.chev}</div></div><div class="dyn"></div>`;
        el.onclick = (ev) => { if (ev.target.closest('[data-speed]')) { speedTest(); return; } toggle(t.id); };
        e = els[t.id] = { el, dyn: el.querySelector('.dyn') };
      }
      if (grid.children[idx] !== e.el) grid.insertBefore(e.el, grid.children[idx] || null);
      const b = t.body(S);
      e.dyn.innerHTML = `<div class="mid">${b.mid}${b.spark ? b.spark.replace('@C', 'spark') : ''}</div>${b.sub ? `<div class="sub">${esc(b.sub)}</div>` : ''}${b.bar || ''}<div class="detail">${t.detail(S).replace(/@C/g, '')}</div>`;
    });
    // Keep detail graphs big when opened.
    Object.values(els).forEach((e) => { if (e.el.classList.contains('open')) e.el.querySelector('.detail').insertAdjacentHTML('afterbegin', ''); });
  }
  function toggle(id) {
    const e = els[id]; if (!e) return;
    const open = !e.el.classList.contains('open');
    Object.values(els).forEach((x) => x.el.classList.remove('open'));
    if (open) { e.el.classList.add('open'); e.el.animate([{ opacity: .85, transform: 'scale(.985)' }, { opacity: 1, transform: 'none' }], { duration: 260, easing: 'cubic-bezier(.2,.9,.25,1.1)' }); setTimeout(() => e.el.scrollIntoView({ block: 'nearest', behavior: 'smooth' }), 60); }
  }

  const lastAlert = {};
  function alertOnce(k, title, body) {
    if (!P.alerts) return; const n = Date.now(); if (n - (lastAlert[k] || 0) < 30 * 60e3) return; lastAlert[k] = n; invoke('notify', { title, body });
  }
  function alerts(s) {
    if (s.battery && !s.battery.plugged_in && s.battery.percent < 15) alertOnce('batt', 'Battery is low', `${Math.round(s.battery.percent)}% left. Plug in soon.`);
    const d = sysDisk(s); if (d && d.total && d.free / d.total < 0.05) alertOnce('disk', 'Storage is almost full', `Only ${bytes(d.free)} free on ${d.mount}.`);
    if (pressure(s) >= 4) alertOnce('mem', 'Memory is squeezed', 'Close a few apps to free up room.');
  }

  async function tick() {
    try {
      const s = await invoke('snapshot'); S = s;
      push(H.cpu, s.cpu); push(H.down, s.net_down_bps); push(H.up, s.net_up_bps); push(H.rd, s.disk_read_bps); push(H.wr, s.disk_write_bps);
      if (s.temps.length) push(H.temp, (mainTemp(s) - 30) / 70);
      render(); alerts(s);
    } catch (e) { errors.push(String(e)); }
  }
  function startLoop() { stopLoop(); tick(); timer = setInterval(tick, P.refresh * 1000); }
  function stopLoop() { if (timer) clearInterval(timer); timer = null; }
  function animateIn() { shell?.animate([{ opacity: 0, transform: 'translateY(12px) scale(.97)' }, { opacity: 1, transform: 'none' }], { duration: 340, easing: 'cubic-bezier(.2,.9,.25,1.08)' }); }

  async function initPanel() {
    buildPanel();
    T.event.listen('panel-visible', (e) => { if (e.payload) { animateIn(); startLoop(); } else stopLoop(); });
    T.event.listen('prefs-changed', () => { P = load(); applyTheme(); if (timer) startLoop(); else render(); });
    invoke('set_icon_style', { style: P.icon }).catch(() => {});
    if (window.__MOCK || (testView && testView.startsWith('panel'))) { startLoop(); }
    if (testOpt.expand) setTimeout(() => toggle(testOpt.expand), 900);
  }

  // ---------- settings ----------
  const TABS = [['Look', 'look', 'How Stats looks and sits in the tray'], ['What to watch', 'watch', 'Pick the tiles you want. Parts this PC does not have are hidden.'], ['General', 'gear', 'Start-up, alerts and units'], ['About', 'info', '']];
  let tab = 0, ownTimer = null, availSnap = null;
  const MODS = [['cpu', 'Processor', 'How busy the PC is'], ['memory', 'Memory used', 'How much working space is in use'], ['disk', 'Storage', 'Size and free space of your drives'], ['diskio', 'Disk activity', 'How fast the drives read and write'], ['network', 'Internet', 'Download and upload speed'], ['battery', 'Battery', 'Charge, time left and battery health'], ['sensors', 'Temperature', 'How warm the chips are']];

  const segHtml = (id, opts, cur) => `<div class="seg" data-seg="${id}"><span class="pillbg"></span>${opts.map(([v, l]) => `<button data-v="${v}" class="${String(v) === String(cur) ? 'on' : ''}">${l}</button>`).join('')}</div>`;
  const swHtml = (id, on) => `<button class="sw ${on ? 'on' : ''}" role="switch" aria-checked="${!!on}" data-sw="${id}"></button>`;
  const row = (t, d, ctl) => `<div class="row"><div><div class="t">${t}</div>${d ? `<div class="d">${d}</div>` : ''}</div>${ctl}</div>`;

  function pageHtml() {
    if (tab === 0) return row('Appearance', 'Follows Windows unless you pick one', segHtml('appearance', [['auto', 'Auto'], ['light', 'Light'], ['dark', 'Dark']], P.appearance))
      + row('Accent colour', 'Used in this window', `<div class="swatches">${ACC.map((a, i) => `<button class="swatch ${i === P.accent ? 'on' : ''}" data-acc="${i}" title="${a[0]}" style="--c:${a[1]}"></button>`).join('')}</div>`)
      + row('Tray icon', 'Live bars move every 5 seconds. Hidden removes the tray icon: open Stats again to reach Settings', segHtml('icon', [['bars', 'Bars'], ['live', 'Live bars'], ['hidden', 'Hidden']], P.icon));
    if (tab === 1) {
      const have = (id) => id === 'battery' ? !!availSnap?.battery : id === 'sensors' ? !!availSnap?.temps?.length : true;
      return MODS.filter((m) => have(m[0])).map((m) => row(`<span class="modrow"><span class="ico" style="--tint:${TINT[m[0]]};width:28px;height:28px;border-radius:8px;display:grid;place-items:center;color:var(--tint);background:color-mix(in srgb,var(--tint) 14%,transparent);border:1px solid color-mix(in srgb,var(--tint) 40%,transparent)"><span style="width:16px;height:16px;display:block">${ICON[m[0]]}</span></span>${m[1]}</span>`, m[2], swHtml('mod.' + m[0], enabled(m[0])))).join('');
    }
    if (tab === 2) return row('Open at login', 'Start Stats when you sign in to Windows', swHtml('login', !!window.__login))
      + row('Alerts', 'Low battery, full storage, squeezed memory (checked while the panel is open)', swHtml('alerts', P.alerts))
      + row('Check for updates', 'Looks on GitHub when you open About', swHtml('checks', P.checks))
      + row('Temperature', '', segHtml('temp', [['c', '°C'], ['f', '°F']], P.temp))
      + row('Speed', '', segHtml('speed', [['bytes', 'MB/s'], ['bits', 'Mbps']], P.speed))
      + row('Refresh while open', 'Nothing runs while the panel is closed', segHtml('refresh', [[1, '1 s'], [2, '2 s'], [5, '5 s'], [10, '10 s']], P.refresh));
    return `<div class="about"><img src="icon.png" alt=""><h3>Stats</h3><p>Version ${VERSION} for Windows</p><p>How your PC is doing, in plain words.</p></div>`
      + row('Updates', '<span class="upd" id="upd">Not checked yet</span>', '<button class="btn" id="chk">Check now</button>')
      + row('Stats’ own use', 'What this app costs your PC right now', '<b class="mono" id="own">…</b>')
      + row('Credits', 'Based on exelban/stats (MIT licence)', '<a data-url="https://github.com/Solomon-69/Stats">GitHub</a>');
  }
  function placePills(scope) {
    (scope || document).querySelectorAll('.seg').forEach((sg) => {
      const on = sg.querySelector('button.on'); const bg = sg.querySelector('.pillbg'); if (!on) return;
      bg.style.left = on.offsetLeft + 'px'; bg.style.width = on.offsetWidth + 'px';
    });
  }
  function renderSettings(animate = true) {
    const t = TABS[tab];
    document.getElementById('app').innerHTML = `<div class="app"><div class="side"><h1>Stats</h1><div class="s2">Settings</div>
      ${TABS.map((x, i) => `<button class="nav ${i === tab ? 'on' : ''}" data-tab="${i}">${ICON[x[1]]}${x[0]}</button>`).join('')}
      <div class="credit">Based on exelban/stats<br>MIT licence</div></div>
      <div class="main"><h2>${t[0]}</h2><div class="lead">${t[2] || '&nbsp;'}</div><div class="page" ${animate ? '' : 'style="animation:none"'}>${pageHtml()}</div></div></div>`;
    placePills();
    clearInterval(ownTimer);
    if (tab === 3) { ownTick(); ownTimer = setInterval(() => { if (!document.hidden) ownTick(); }, 2000); if (P.checks && !window.__checked) { window.__checked = 1; checkUpdate(); } }
  }
  async function ownTick() { try { const s = await invoke('snapshot'); const el = document.getElementById('own'); if (el) el.textContent = `${(s.self_cpu * 100).toFixed(1)}% CPU · ${bytes(s.self_mem)}`; S = s; } catch (e) { errors.push(String(e)); } }
  const cmpV = (a, b) => { const x = a.split('.').map(Number), y = b.split('.').map(Number); for (let i = 0; i < 3; i++) { if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) - (y[i] || 0); } return 0; };
  async function checkUpdate() {
    const el = document.getElementById('upd'); if (!el) return; el.textContent = 'Checking…';
    try {
      const r = await fetch('https://api.github.com/repos/Solomon-69/Stats/releases/latest', { headers: { Accept: 'application/vnd.github+json' } });
      const j = await r.json(); const v = String(j.tag_name || '').replace(/^v/, '');
      el.innerHTML = v && cmpV(v, VERSION) > 0 ? `Version ${esc(v)} is out. <a data-url="${esc(j.html_url)}">Download it</a>` : 'You are up to date.';
    } catch { el.textContent = 'Could not check. Are you online?'; }
  }
  function onSettingsClick(e) {
    const a = e.target.closest('[data-url]'); if (a) { invoke('open_url', { url: a.dataset.url }); return; }
    const n = e.target.closest('[data-tab]'); if (n) { tab = +n.dataset.tab; renderSettings(); return; }
    if (e.target.closest('#chk')) { checkUpdate(); return; }
    const sw = e.target.closest('[data-sw]');
    if (sw) {
      const on = !sw.classList.contains('on'); sw.classList.toggle('on', on); sw.setAttribute('aria-checked', on);
      const id = sw.dataset.sw;
      if (id.startsWith('mod.')) P.mods[id.slice(4)] = on; else if (id === 'login') { invoke('set_autostart', { on }).then((r) => { window.__login = r; sw.classList.toggle('on', r); }); return; } else P[id] = on;
      save(); return;
    }
    const sb = e.target.closest('.seg button');
    if (sb) {
      const sg = sb.parentElement; sg.querySelectorAll('button').forEach((b) => b.classList.toggle('on', b === sb)); placePills(sg.parentElement);
      const id = sg.dataset.seg; const v = sb.dataset.v; P[id] = (id === 'refresh') ? +v : v;
      if (id === 'appearance') applyTheme(); if (id === 'icon') invoke('set_icon_style', { style: v });
      save(); return;
    }
    const ac = e.target.closest('[data-acc]');
    if (ac) { P.accent = +ac.dataset.acc; document.querySelectorAll('.swatch').forEach((s) => s.classList.toggle('on', s === ac)); applyTheme(); save(); }
  }
  async function initSettings() {
    document.body.addEventListener('click', onSettingsClick);
    T.event.listen('prefs-changed', () => { P = load(); applyTheme(); });
    window.addEventListener('focus', refreshAvail);
    try { window.__login = await invoke('get_autostart'); } catch {}
    tab = Math.min(Math.max(+(testOpt.tab ?? 0), 0), 3);
    await refreshAvail(true);
  }
  async function refreshAvail(first) {
    try { availSnap = await invoke('snapshot'); } catch (e) { errors.push(String(e)); }
    if (first || tab === 1) renderSettings(!!first && !testView);
  }

  // ---------- start ----------
  async function reportLater(ms) {
    setTimeout(() => {
      const r = { view: W, theme: root.dataset.theme, errors, version: VERSION, opts: testOpt };
      if (W === 'panel') {
        r.tiles = Object.keys(els);
        r.texts = Object.fromEntries(Object.entries(els).map(([id, e]) => [id, { big: e.el.querySelector('.big')?.textContent || '', sub: e.el.querySelector('.sub')?.textContent || '' }]));
        r.status = document.getElementById('ptxt')?.textContent; r.chips = [...document.querySelectorAll('.chip')].map((c) => c.textContent);
        r.model = document.getElementById('model')?.textContent; r.open = [...document.querySelectorAll('.tile.open')].map((t) => t.dataset.id);
        r.batteryPresent = !!S?.battery; r.tempCount = S?.temps?.length || 0; r.cpuNow = S?.cpu; r.memNow = S ? S.mem_used / S.mem_total : null;
        r.selfCpu = S?.self_cpu; r.selfMem = S?.self_mem;
      } else {
        r.tab = tab; r.title = document.querySelector('.main h2')?.textContent; r.rows = document.querySelectorAll('.row').length;
        r.switches = document.querySelectorAll('.sw').length; r.own = document.getElementById('own')?.textContent;
        r.modRows = [...document.querySelectorAll('.row .t')].map((x) => x.textContent.trim());
      }
      invoke('test_report', { report: JSON.stringify(r) });
      window.__report = r;
    }, ms);
  }
  (async () => {
    try { testView = await invoke('test_mode'); } catch {}
    if (testView) {
      const parts = testView.split(';'); if (parts[0].startsWith('settings')) W = 'settings';
      parts.slice(1).forEach((p) => { const [k, v] = p.split('='); testOpt[k] = v; });
    } else if (params.get('test')) { testView = params.get('test'); testView.split(';').slice(1).forEach((p) => { const [k, v] = p.split('='); testOpt[k] = v; }); }
    document.body.dataset.w = W; applyTheme();
    if (W === 'settings') await initSettings(); else await initPanel();
    const mainView = testView ? (testView.startsWith('settings') ? 'settings' : 'panel') : null;
    if (window.__MOCK || (testView && W === mainView)) reportLater(W === 'panel' ? 5500 : 3500);
  })();
})();
