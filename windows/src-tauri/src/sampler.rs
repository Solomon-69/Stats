// sampler.rs. Reads the PC's numbers. Nothing runs in the background: a snapshot is only taken when the panel asks.
use serde::Serialize;
use std::collections::HashMap;
use std::time::{Duration, Instant};
use sysinfo::{Components, Disks, Networks, Pid, ProcessRefreshKind, ProcessesToUpdate, System};

#[derive(Serialize, Clone, Default)]
pub struct DiskInfo {
    pub name: String,
    pub mount: String,
    pub total: u64,
    pub free: u64,
}

#[derive(Serialize, Clone, Default)]
pub struct Battery {
    pub percent: f32,
    pub plugged_in: bool,
    pub charging: bool,
    pub full: bool,
    pub seconds_left: Option<f32>,
    pub health: Option<f32>,
    pub watts: Option<f32>,
}

#[derive(Serialize, Clone, Default)]
pub struct Temp {
    pub label: String,
    pub c: f32,
}

#[derive(Serialize, Clone, Default)]
pub struct Proc {
    pub name: String,
    pub cpu: f32,
    pub mem: u64,
}

#[derive(Serialize, Clone, Default)]
pub struct Snapshot {
    pub cpu: f32,
    pub cores: Vec<f32>,
    pub mem_used: u64,
    pub mem_total: u64,
    pub swap_used: u64,
    pub swap_total: u64,
    pub disks: Vec<DiskInfo>,
    pub disk_read_bps: f64,
    pub disk_write_bps: f64,
    pub net_down_bps: f64,
    pub net_up_bps: f64,
    pub net_online: bool,
    pub net_name: String,
    pub net_total_down: u64,
    pub net_total_up: u64,
    pub battery: Option<Battery>,
    pub temps: Vec<Temp>,
    pub top_cpu: Vec<Proc>,
    pub top_mem: Vec<Proc>,
    pub self_cpu: f32,
    pub self_mem: u64,
}

#[derive(Serialize, Clone, Default)]
pub struct Machine {
    pub model: String,
    pub cpu: String,
    pub cores: usize,
    pub ram: u64,
    pub os: String,
}

pub struct Sampler {
    sys: System,
    disks: Disks,
    nets: Networks,
    comps: Components,
    pid: Pid,
    last_cpu: Instant,
    last_proc: Instant,
    last_net: Instant,
    last_disks: Instant,
    last_comps: Instant,
    last_batt: Instant,
    cached: Snapshot,
    cpu_primed: bool,
}

const STALE: Duration = Duration::from_secs(5);

impl Sampler {
    pub fn new() -> Self {
        let mut sys = System::new();
        sys.refresh_cpu_usage();
        sys.refresh_memory();
        let pid = Pid::from_u32(std::process::id());
        let old = Instant::now().checked_sub(Duration::from_secs(3600)).unwrap_or_else(Instant::now);
        Sampler {
            sys,
            disks: Disks::new_with_refreshed_list(),
            nets: Networks::new_with_refreshed_list(),
            comps: Components::new_with_refreshed_list(),
            pid,
            last_cpu: Instant::now(),
            last_proc: old,
            last_net: Instant::now(),
            last_disks: Instant::now(),
            last_comps: Instant::now(),
            last_batt: old,
            cached: Snapshot::default(),
            cpu_primed: false,
        }
    }

    pub fn machine(&mut self) -> Machine {
        self.sys.refresh_cpu_usage();
        let cpu = self.sys.cpus().first().map(|c| c.brand().trim().to_string()).unwrap_or_default();
        Machine {
            model: crate::pc_model(),
            cpu,
            cores: self.sys.cpus().len(),
            ram: self.sys.total_memory(),
            os: System::long_os_version().unwrap_or_else(|| "Windows".into()),
        }
    }

    /// Cheap read for the live tray icon: processor, memory and the system drive only.
    pub fn quick(&mut self) -> (f32, f32, f32) {
        self.sys.refresh_cpu_usage();
        self.sys.refresh_memory();
        self.last_cpu = Instant::now();
        let mem = if self.sys.total_memory() > 0 { self.sys.used_memory() as f32 / self.sys.total_memory() as f32 } else { 0.0 };
        self.disks.refresh(true);
        let disk = system_disk(&self.disks).map(|d| 1.0 - d.free as f32 / d.total.max(1) as f32).unwrap_or(0.0);
        (self.sys.global_cpu_usage() / 100.0, mem, disk)
    }

    pub fn snapshot(&mut self) -> Snapshot {
        let now = Instant::now();
        let first = !self.cpu_primed;
        // The processor reading is an average since the last look; after a long gap look twice, a moment apart.
        if now.duration_since(self.last_cpu) > STALE || !self.cpu_primed {
            self.sys.refresh_cpu_usage();
            std::thread::sleep(Duration::from_millis(260));
            self.cpu_primed = true;
        }
        self.sys.refresh_cpu_usage();
        self.last_cpu = Instant::now();
        self.sys.refresh_memory();

        let stale_proc = first || now.duration_since(self.last_proc) > STALE * 2;
        let kind = ProcessRefreshKind::nothing().with_cpu().with_memory().with_disk_usage();
        if stale_proc {
            self.sys.refresh_processes_specifics(ProcessesToUpdate::All, true, kind);
            std::thread::sleep(Duration::from_millis(260));
            self.last_proc = Instant::now();
        }
        let proc_elapsed = Instant::now().duration_since(self.last_proc).as_secs_f64();
        // Processes are re-read every other look to keep this app light.
        let age = Instant::now().duration_since(self.last_proc);
        if stale_proc || age >= Duration::from_millis(3500) {
            let before = self.last_proc;
            self.sys.refresh_processes_specifics(ProcessesToUpdate::All, true, kind);
            let secs = Instant::now().duration_since(before).as_secs_f64().max(0.25);
            self.last_proc = Instant::now();
            self.rebuild_procs(secs);
        } else if self.cached.top_cpu.is_empty() {
            self.rebuild_procs(proc_elapsed.max(0.25));
        }

        let cores: Vec<f32> = self.sys.cpus().iter().map(|c| c.cpu_usage() / 100.0).collect();
        let cpu = self.sys.global_cpu_usage() / 100.0;

        if now.duration_since(self.last_disks) > Duration::from_secs(20) || self.cached.disks.is_empty() {
            self.disks.refresh(true);
            self.last_disks = now;
            self.cached.disks = self
                .disks
                .list()
                .iter()
                .filter(|d| d.total_space() > 0 && !d.is_removable())
                .map(|d| DiskInfo {
                    name: d.name().to_string_lossy().to_string(),
                    mount: d.mount_point().to_string_lossy().to_string(),
                    total: d.total_space(),
                    free: d.available_space(),
                })
                .collect();
        }

        let net_secs = now.duration_since(self.last_net).as_secs_f64().max(0.25);
        self.nets.refresh(true);
        self.last_net = now;
        let (mut down, mut up, mut tdown, mut tup) = (0u64, 0u64, 0u64, 0u64);
        let mut best: (u64, String) = (0, String::new());
        for (name, d) in self.nets.iter() {
            let l = name.to_lowercase();
            if l.contains("loopback") || l.contains("isatap") || l.contains("teredo") || l.contains("pseudo") { continue; }
            down += d.received();
            up += d.transmitted();
            tdown += d.total_received();
            tup += d.total_transmitted();
            if d.total_received() > best.0 { best = (d.total_received(), name.clone()); }
        }
        // First look after a long gap covers the whole gap; show it as quiet rather than a false burst.
        let gap_big = net_secs > 8.0;
        let (net_down_bps, net_up_bps) = if gap_big { (0.0, 0.0) } else { (down as f64 / net_secs, up as f64 / net_secs) };

        if now.duration_since(self.last_comps) > Duration::from_secs(6) || self.cached.temps.is_empty() {
            self.comps.refresh(true);
            self.last_comps = now;
            self.cached.temps = self
                .comps
                .iter()
                .filter_map(|c| c.temperature().filter(|t| t.is_finite() && *t > 1.0 && *t < 130.0).map(|t| Temp { label: c.label().to_string(), c: t }))
                .collect();
        }

        if first || now.duration_since(self.last_batt) > Duration::from_secs(4) {
            self.last_batt = now;
            self.cached.battery = read_battery();
        }

        let (self_cpu, self_mem) = self
            .sys
            .process(self.pid)
            .map(|p| (p.cpu_usage() / self.sys.cpus().len().max(1) as f32, p.memory()))
            .unwrap_or((0.0, 0));

        let mut s = self.cached.clone();
        s.cpu = cpu;
        s.cores = cores;
        s.mem_used = self.sys.used_memory();
        s.mem_total = self.sys.total_memory();
        s.swap_used = self.sys.used_swap();
        s.swap_total = self.sys.total_swap();
        s.net_down_bps = net_down_bps;
        s.net_up_bps = net_up_bps;
        s.net_online = tdown + tup > 0;
        s.net_name = best.1;
        s.net_total_down = tdown;
        s.net_total_up = tup;
        s.self_cpu = self_cpu;
        s.self_mem = self_mem;
        s
    }

    fn rebuild_procs(&mut self, secs: f64) {
        let ncpu = self.sys.cpus().len().max(1) as f32;
        let mut by: HashMap<String, Proc> = HashMap::new();
        let (mut rd, mut wr) = (0u64, 0u64);
        for p in self.sys.processes().values() {
            let u = p.disk_usage();
            rd += u.read_bytes;
            wr += u.written_bytes;
            let mut n = p.name().to_string_lossy().to_string();
            if let Some(stripped) = n.strip_suffix(".exe") { n = stripped.to_string(); }
            if n.is_empty() || n == "Idle" || n == "System Idle Process" { continue; }
            let e = by.entry(n.clone()).or_insert(Proc { name: n, cpu: 0.0, mem: 0 });
            e.cpu += p.cpu_usage() / ncpu / 100.0;
            e.mem += p.memory();
        }
        let mut v: Vec<Proc> = by.into_values().collect();
        v.sort_by(|a, b| b.cpu.partial_cmp(&a.cpu).unwrap_or(std::cmp::Ordering::Equal));
        self.cached.top_cpu = v.iter().take(5).cloned().collect();
        v.sort_by(|a, b| b.mem.cmp(&a.mem));
        self.cached.top_mem = v.iter().take(5).cloned().collect();
        self.cached.disk_read_bps = rd as f64 / secs;
        self.cached.disk_write_bps = wr as f64 / secs;
    }
}

fn system_disk(disks: &Disks) -> Option<DiskInfo> {
    let sys_drive = std::env::var("SystemDrive").unwrap_or_else(|_| "C:".into()).to_uppercase();
    let pick = disks
        .list()
        .iter()
        .find(|d| d.mount_point().to_string_lossy().to_uppercase().starts_with(&sys_drive))
        .or_else(|| disks.list().first())?;
    Some(DiskInfo {
        name: pick.name().to_string_lossy().to_string(),
        mount: pick.mount_point().to_string_lossy().to_string(),
        total: pick.total_space(),
        free: pick.available_space(),
    })
}

fn read_battery() -> Option<Battery> {
    use starship_battery::units::{power::watt, ratio::percent, time::second};
    use starship_battery::{Manager, State};
    let m = Manager::new().ok()?;
    let b = m.batteries().ok()?.flatten().next()?;
    let st = b.state();
    let charging = st == State::Charging;
    let full = st == State::Full;
    let plugged = charging || full || st == State::Unknown && false;
    let secs = if charging { b.time_to_full() } else { b.time_to_empty() }.map(|t| t.get::<second>());
    let pct = b.state_of_charge().get::<percent>();
    let w = b.energy_rate().get::<watt>();
    Some(Battery {
        percent: pct,
        plugged_in: plugged || (st != State::Discharging && pct >= 99.0),
        charging,
        full: full || (pct >= 99.0 && st != State::Discharging),
        seconds_left: secs.filter(|s| s.is_finite() && *s > 0.0),
        health: Some(b.state_of_health().get::<percent>()).filter(|h| h.is_finite() && *h > 0.0),
        watts: Some(w).filter(|w| w.is_finite() && *w > 0.0),
    })
}
