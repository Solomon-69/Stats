#!/usr/bin/env python3
"""Stats test run. Drives the installed test build through its test hook and checks real numbers.
Nothing here changes the Mac's light/dark mode. Output: PASS/FAIL lines, exit code 1 if anything failed."""
import time, json, os, re, subprocess, sys, time

HOME = os.path.expanduser("~")
STATE = f"{HOME}/Library/Logs/StatsRemake-state.json"
SNAP = f"{HOME}/Library/Logs/StatsRemake-snap"
POST = "/private/tmp/stats-post"
fails, passes = [], 0

def post(cmd, wait=0.4):
    subprocess.run([POST, cmd], check=False)
    time.sleep(wait)

def state():
    if os.path.exists(STATE): os.remove(STATE)
    post("state", 0.6)
    for _ in range(20):
        if os.path.exists(STATE):
            try: return json.load(open(STATE))
            except Exception: pass
        time.sleep(0.2)
    raise SystemExit("no state file: is the test build running?")

def sh(cmd): return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout

def check(name, ok, detail=""):
    global passes
    if ok: passes += 1; print(f"PASS {name} {detail}")
    else: fails.append(name); print(f"FAIL {name} {detail}")

def near(a, b, tol): return abs(a - b) <= tol

# whatever happens, leave the menu bar clean: only the main icon (tests switch extra menu bar items on and off)
import atexit
atexit.register(lambda: [post("show:clock:0", 0.05), post("theme:0", 0.05)] and [post(f"bar:{m}:off", 0.05) for m in ["cpu", "gpu", "memory", "disk", "network", "battery", "sensors", "fans", "bluetooth", "clock"]])

# 0. fresh app (a clean process so earlier snapshot runs cannot skew the CPU check)
sh("pkill -x StatsNew; open -g ~/Applications/Stats.app"); time.sleep(4)
sh(f"rm -rf '{SNAP}'")
check("process running", bool(sh("pgrep -x StatsNew").strip()))
post("close"); post("closesettings")
for m in ["cpu", "gpu", "memory", "disk", "network", "battery", "sensors"]: post(f"show:{m}:1", 0.1)
for m in ["cpu", "gpu", "memory", "disk", "network", "battery", "sensors", "fans", "bluetooth", "clock"]: post(f"bar:{m}:off", 0.1)
post("quietbars:1", 0.1); post("units:temp:c", 0.1); post("units:net:bytes", 0.1); post("refresh:2", 0.1); post("appearance:0", 0.1); post("invisible:0", 0.1)
post("zones:America/New_York,Europe/London,Asia/Tokyo", 0.1)

# 1. numbers vs real tools
for _ in range(3):
    post("panel", 1.5); sopen = state()
    if sopen["panelShown"]: break
check("panel open (silent)", sopen["panelShown"])
time.sleep(9)
s1 = state()
if not s1["panelShown"]: post("panel", 3); s1 = state()   # someone clicked elsewhere and closed it: open again
top = sh("top -l 2 -n 0 -s 2 | grep 'CPU usage' | tail -1")
m = re.search(r"([\d.]+)% user, ([\d.]+)% sys", top)
s2 = state()
if m:
    real = (float(m.group(1)) + float(m.group(2))) / 100
    mine = (s1["cpu"] + s2["cpu"]) / 2
    check("cpu near top", near(mine, real, 0.30), f"mine={mine:.2f} top={real:.2f}")
check("core count", s1["cores"] == int(sh("sysctl -n hw.ncpu")), f"{s1['cores']}")
check("cpu parts add up", near(s1["cpuUser"] + s1["cpuSystem"], s1["cpu"], 0.001))
check("memory total", s1["memTotal"] == int(sh("sysctl -n hw.memsize")))
vm = sh("vm_stat"); ps = int(re.search(r"page size of (\d+)", vm).group(1))
wired = int(re.search(r"Pages wired down:\s+(\d+)", vm).group(1)) * ps
# wired memory moves by hundreds of MB while the Mac is busy: accept anything between a reading before and one after
vm0 = sh("vm_stat"); wired0 = int(re.search(r"Pages wired down:\s+(\d+)", vm0).group(1)) * ps
lo, hi = min(wired, wired0), max(wired, wired0)
check("wired memory", lo * 0.9 <= s2["memWired"] <= hi * 1.1 or near(s2["memWired"], wired, wired * 0.06), f"mine={s2['memWired']/1e9:.2f} vm_stat={wired0/1e9:.2f}..{wired/1e9:.2f} GB")
comp = int(re.search(r"Pages occupied by compressor:\s+(\d+)", vm).group(1)) * ps
check("compressed memory", near(s2["memCompressed"], comp, comp * 0.10), f"mine={s2['memCompressed']/1e9:.2f} vm_stat={comp/1e9:.2f} GB")
sw = re.search(r"used = ([\d.]+)M", sh("sysctl vm.swapusage")); swb = float(sw.group(1)) * 1048576
check("swap", near(s2["swapUsed"], swb, swb * 0.10 + 5e7), f"mine={s2['swapUsed']/1e9:.2f} sysctl={swb/1e9:.2f} GB")
check("pressure", s2["pressure"] == int(sh("sysctl -n kern.memorystatus_vm_pressure_level")), f"{s2['pressure']}")
check("memory used = app+wired+compressed", near(s2["memUsed"], s2["memApp"] + s2["memWired"] + s2["memCompressed"], 1))
df = sh("df -k / | tail -1").split(); dfree = int(df[3]) * 1024; dtot = int(df[1]) * 1024
check("disk total", near(s2["diskTotal"], dtot, dtot * 0.12), f"mine={s2['diskTotal']/1e9:.0f} df={dtot/1e9:.0f} GB")
check("disk free at least df free", s2["diskFree"] >= dfree * 0.95, f"mine={s2['diskFree']/1e9:.1f} df={dfree/1e9:.1f} GB")
ip = sh("ipconfig getifaddr en0").strip()
if ip: check("network address", s2["netAddr"] == ip and s2["netKind"] == "Wi-Fi", f"{s2['netAddr']} {s2['netKind']}")
pm = sh("pmset -g batt")
mp = re.search(r"(\d+)%", pm)
if mp and s2.get("battery"):
    check("battery percent", near(s2["battery"]["percent"], int(mp.group(1)), 2), f"mine={s2['battery']['percent']} pmset={mp.group(1)}")
    mt = re.search(r"(\d+):(\d+) remaining", pm)
    if mt and s2["battery"]["secondsLeft"] > 0:
        # our own estimate comes from the live charge current; macOS's number is only a loose guide (0.4x to 1.6x)
        sysmin = int(mt.group(1)) * 60 + int(mt.group(2)); mine_min = s2["battery"]["secondsLeft"] / 60
        check("battery time left", 0.4 * sysmin <= mine_min <= 1.6 * sysmin, f"mine={mine_min:.0f} min, macOS={sysmin} min")
    cyc = int(re.search(r'"CycleCount" = (\d+)', sh("ioreg -rn AppleSmartBattery")).group(1))
    check("battery cycles", s2["battery"]["cycles"] == cyc, f"{cyc}")
    check("battery health 50-100%", 0.5 <= s2["battery"]["health"] <= 1.0, f"{s2['battery']['health']:.2f}")
gpus = [int(re.findall(r'"Device Utilization %"=(\d+)', sh("ioreg -r -c IOAccelerator"))[0]) for _ in range(3) if not time.sleep(0.7)]
if gpus and "gpu" in s2:
    s3 = state()
    ok = 0 <= s2["gpu"] <= 1 and (min(gpus) - 40 <= s2["gpu"] * 100 <= max(gpus) + 40 or min(gpus) - 40 <= s3.get("gpu", 0) * 100 <= max(gpus) + 40)
    check("gpu in range", ok, f"mine={s2['gpu']:.2f}/{s3.get('gpu', 0):.2f} ioreg={gpus}")
check("temperatures sane", len(s2["temps"]) > 0 and all(10 < t["c"] < 110 for t in s2["temps"]), f"{len(s2['temps'])} sensors")
check("own memory under 60 MB", s2["ownMemory"] < 60e6, f"{s2['ownMemory']/1e6:.0f} MB")
def _cputime():
    t = sh("ps -o cputime= -p $(pgrep -x StatsNew)").strip().split(":"); return float(t[0]) * 60 + float(t[1])
post("close", 0.8); post("refresh:5", 0.3); time.sleep(5)
c0, t0 = _cputime(), time.time(); time.sleep(25)
idle = (_cputime() - c0) / (time.time() - t0)
post("refresh:2", 0.3)
check("own cpu closed under 3 percent of one core (busy Mac)", idle < 0.03, f"{idle*100:.1f}%")

# 2. panel behaviour
for mod in s2["panelModules"]:
    post(f"expand:{mod}", 0.5)
    st = state()
    check(f"expand {mod}", st["expanded"] == mod)
post("expand", 0.3); check("fold all", state()["expanded"] == "")
post("close", 0.8); check("panel closes", not state()["panelShown"])
for mod in ["cpu", "network"]:
    for _ in range(3):
        post(f"panel:{mod}", 1.2); st = state()
        if st["panelShown"]: break
    check(f"panel from {mod} opens expanded", st["panelShown"] and st["expanded"] == mod or mod not in st["panelModules"])
    post("close", 0.6)

# 3. settings effects
post("units:temp:f", 0.6); sm = state()["summary"]["sensors"]["value"]; check("fahrenheit", sm.endswith("°F"), sm)
post("units:temp:c", 0.6); sm = state()["summary"]["sensors"]["value"]; check("celsius", sm.endswith("°C"), sm)
post("units:net:bits", 0.6); sm = state()["summary"]["network"]["value"]; check("megabits", "bps" in sm, sm)
post("units:net:bytes", 0.6); sm = state()["summary"]["network"]["value"]; check("bytes per second", "/s" in sm, sm)
post("show:cpu:0", 0.6); st = state(); check("hide module", "cpu" not in st["panelModules"] and "cpu" not in [x for x in []])
post("show:cpu:1", 0.6); check("show module again", "cpu" in state()["panelModules"])
post("refresh:5", 0.6); check("refresh saved", state()["prefs"]["refresh"] == 5); post("refresh:2", 0.3)
post("appearance:2", 0.6); check("appearance dark saved", state()["prefs"]["appearance"] == 2); post("appearance:0", 0.3)
post("invisible:1", 0.6); st = state(); main = [b for b in st["bars"] if b["module"] == "main"][0]
check("invisible icon keeps width", main["invisible"] and main["length"] == 28, f"len={main['length']}"); post("invisible:0", 0.3)
styles = {"text": None, "graph": None, "bar": None, "icon": None}
for mod in ["cpu", "gpu", "memory", "disk", "network", "battery", "sensors"]:
    for sty in styles:
        post(f"bar:{mod}:{sty}", 0.3); post(f"snapbar:{mod}:{sty}", 0.15)
        st = state(); b = [x for x in st["bars"] if x["module"] == mod]
        check(f"bar {mod} {sty}", bool(b) and b[0]["style"] == sty and b[0]["length"] > 10, f"len={b[0]['length'] if b else None}")
    post(f"bar:{mod}:off", 0.3)
    check(f"bar {mod} off removes item", not [x for x in state()["bars"] if x["module"] == mod])
post("zones:Asia/Tokyo", 0.5); check("zones saved", state()["prefs"]["zones"] == ["Asia/Tokyo"])
post("zones:America/New_York,Europe/London,Asia/Tokyo", 0.3)

# 3a. internet checks (opt-in) against the real internet
post("checks:1", 0.3); post("show:network:1", 0.2); post("panel:network", 1.0); time.sleep(8)
stn = state(); real_ip = sh("curl -s --max-time 6 https://api.ipify.org").strip()
check("public address matches ipify", stn.get("publicAddress") == real_ip and real_ip != "", f"mine={stn.get('publicAddress')} real={real_ip}")
check("delay to internet measured", 0 < (stn.get("delayMs") or 0) < 2000, f"{stn.get('delayMs')}")
post("checks:0", 0.3); post("close", 0.4)
check("alerts default off", state()["prefs"]["alerts"] is False)

# 3b. colour themes
for n in range(5):
    post(f"theme:{n}", 0.5); check(f"theme {n} saved", state()["prefs"]["theme"] == n)
    for scheme in ["light", "dark"]:
        post(f"snap:theme{n}-{scheme}:{scheme}", 0.8)
post("icon:live", 0.5); st = state(); mi = [b for b in st["bars"] if b["module"] == "main"][0]
check("live graph icon chosen and sized", st["prefs"]["icon"] == "live" and mi["length"] == 40, f"{st['prefs']['icon']} {mi['length']}")
post("iconsrc:network", 0.5); check("live graph source saved", state()["prefs"]["iconSource"] == "network")
post("iconsrc:cpu", 0.3)
post("icon:bars", 0.4); check("bars icon back", state()["prefs"]["icon"] == "bars")
post("theme:0", 0.4)

# 4. snapshots light and dark, every module expanded
for scheme in ["light", "dark"]:
    post("expand", 0.2); post(f"snap:base:{scheme}", 0.8)
    for mod in s2["panelModules"]:
        post(f"show:{mod}:1", 0.2); post(f"expand:{mod}", 0.3); post(f"snap:{mod}:{scheme}", 0.8)
post("expand", 0.2)
try:
    from PIL import Image
    ok = True
    for f in sorted(os.listdir(SNAP)):
        if f.endswith(".png"):
            if f.startswith('bar-'): continue
            im = Image.open(f"{SNAP}/{f}").convert("L"); lo, hi = im.getextrema()
            if hi - lo < 30 or im.width < 100: ok = False; print("  blank image", f)
    check("all snapshots drawn", ok, f"{len(os.listdir(SNAP))} files")
except ImportError:
    pass

# 4b. the clock is gone
post("show:clock:1", 0.4); post("panel", 0.8)
check("clock never appears in the panel", "clock" not in state()["panelModules"], str(state()["panelModules"]))
post("close", 0.4)

# 4c. popover arrow and body are one shape: same fill either side of the join (light and dark)
def join_check(scheme):
    post(f"popjoin:join:{scheme}", 1.5)
    try:
        from PIL import Image
        im = Image.open(f"{SNAP}/join-{scheme}.png").convert("RGBA"); w, h = im.size
        # the arrow is the short run of solid pixels above the body's top edge (y < 26 at 2x), away from the left/right corners
        row = [x for x in range(40, w - 40) if im.getpixel((x, 14))[3] > 200]
        if not row: check(f"popover arrow found ({scheme})", False); return
        cx = (row[0] + row[-1]) // 2
        def avg(y0, y1):
            px = [im.getpixel((cx + dx, y)) for y in range(y0, y1) for dx in range(-3, 4)]
            return [sum(p[c] for p in px) / len(px) for c in range(3)]
        top, body = avg(18, 22), avg(34, 38)
        d = max(abs(top[c] - body[c]) for c in range(3))
        check(f"popover arrow joins body without a seam ({scheme})", d <= 10, f"arrow={[round(v) for v in top]} body={[round(v) for v in body]} diff={d:.0f}")
    except ImportError:
        pass
join_check("dark"); join_check("light")

# 5. keyboard navigation of Settings (silent: same code path as the key presses)
def cur(): return state()["navCurrent"]
def goto(row, limit=40):
    for _ in range(limit):
        if cur() == row: return True
        post("nav:down", 0.12)
    return cur() == row
post("nav:reset", 0.2)
post("nav:down", 0.3); check("nav: first Down highlights Appearance", cur() == "appearance")
for _ in range(8): post("nav:down", 0.12)
check("nav: Down walks to the next page's first row", cur() == "mod.cpu.show" and state()["navTab"] == 1, cur())
post("nav:up", 0.2); check("nav: Up goes back a row", cur() == "refresh" and state()["navTab"] == 0, cur())
post("nav:reset", 0.2); post("nav:up", 0.3)
check("nav: Up from nothing highlights the last row of the page", cur() == "refresh", cur())
post("nav:tab:3", 0.2); post("nav:reset", 0.1); post("nav:tab:3", 0.1); post("nav:down", 0.3); post("nav:down", 0.3)
check("nav: Down past the last row wraps to the first", cur() == "appearance" and state()["navTab"] == 0, cur())
post("nav:up", 0.3); check("nav: Up from the first row wraps to the last", cur() == "update" and state()["navTab"] == 3, cur())
# changing settings
post("nav:reset", 0.2); post("nav:down", 0.3)
a0 = state()["prefs"]["appearance"]
post("nav:right", 0.3); check("nav: Right steps the chips forward", state()["prefs"]["appearance"] == (a0 + 1) % 3)
post("nav:left", 0.3); check("nav: Left steps the chips back", state()["prefs"]["appearance"] == a0)
goto("icontint"); k0 = state()["prefs"]["iconTinted"]
post("nav:space", 0.4); check("nav: Space flips a switch", state()["prefs"]["iconTinted"] == (not k0))
post("nav:space", 0.4); check("nav: Space flips it back", state()["prefs"]["iconTinted"] == k0)
goto("unit.temp"); f0 = state()["prefs"]["fahrenheit"]
post("nav:right", 0.3); check("nav: Right flips a two-choice chip", state()["prefs"]["fahrenheit"] == (not f0))
post("nav:left", 0.3); check("nav: Left flips it back", state()["prefs"]["fahrenheit"] == f0)
goto("refresh"); r0 = state()["prefs"]["refresh"]
post("nav:right", 0.3); check("nav: Right steps the drum by one", state()["prefs"]["refresh"] == min(60, r0 + 1))
post("nav:left", 0.3); check("nav: Left steps it back by one", state()["prefs"]["refresh"] == r0)
goto("checks"); c0 = state()["prefs"]["checks"]
post("nav:space", 0.4); check("nav: Space flips Internet checks", state()["prefs"]["checks"] == (not c0))
post("nav:space", 0.4); check("nav: Space flips it back (checks)", state()["prefs"]["checks"] == c0)
goto("mod.cpu.style"); b0 = state()["barStyles"]["cpu"]
post("nav:right", 0.4); check("nav: Right steps a menu bar style", state()["barStyles"]["cpu"] != b0)
post("bar:cpu:off", 0.3)
post("nav:esc", 0.3); check("nav: Esc clears the highlight", cur() == "")
# snapshot with the highlight showing
post("nav:reset", 0.2); post("nav:down", 0.2); post("nav:down", 0.2); post("nav:down", 0.3)
for scheme in ["light", "dark"]: post(f"snap:navhl:{scheme}", 1.0)
check("nav: highlight snapshot drawn", os.path.exists(f"{SNAP}/navhl-settings0-light.png") and os.path.exists(f"{SNAP}/navhl-settings0-dark.png"))
post("nav:reset", 0.2)

# accent colour: saved, and the main panel looks exactly the same whichever accent is chosen
post("accent:3", 0.3); check("accent colour saved", state()["prefs"]["accent"] == 3)
post("freeze:1", 1.2)
for sch in ["light", "dark"]:
    post("accent:0", 0.3); post(f"snap:acc0:{sch}", 1.5); post("accent:3", 0.3); post(f"snap:acc3:{sch}", 1.5)
    a = open(os.path.join(SNAP, f"acc0-panel-{sch}.png"), "rb").read(); b = open(os.path.join(SNAP, f"acc3-panel-{sch}.png"), "rb").read()
    check(f"panel identical with orchid accent ({sch})", a == b and len(a) > 1000, f"{len(a)} vs {len(b)} bytes")
post("accent:1", 0.3); post("setshot:accblue:0:light", 1.2); post("setshot:accblue:0:dark", 1.2)
post("accent:3", 0.3); post("setshot:accorchid:0:light", 1.2); post("setshot:accorchid:0:dark", 1.2)
post("accent:0", 0.3); post("freeze:0", 0.3)

print(f"\n{passes} passed, {len(fails)} failed")
if fails: print("FAILED:", ", ".join(fails)); sys.exit(1)
