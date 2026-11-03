<div align="center">

<img src="docs/img/icon.png" width="128" height="128" alt="Stats app icon">

# Stats

**How your Mac is doing, in plain words.**

<p>
  <a href="https://github.com/Solomon-69/Stats/releases/latest"><img alt="Version 1.0.7" src="https://img.shields.io/badge/version-1.0.7-454952?style=flat-square"></a>
  <img alt="macOS 14 or later" src="https://img.shields.io/badge/macOS-14%2B-1f1d1a?style=flat-square&logo=apple&logoColor=white">
  <a href="LICENSE"><img alt="MIT licence" src="https://img.shields.io/badge/licence-MIT-5b8a5a?style=flat-square"></a>
</p>

</div>

Stats lives in your menu bar. Click it to see live tiles for the processor, graphics, memory, storage, disk activity, internet, battery, temperature, fans and Bluetooth gadgets. Each tile says what is going on in everyday words ("Plenty of room", "Mostly resting", "3 h 10 min left") and opens up for more detail.

## Features

- **Live tiles** with small graphs that fill in the moment you open the panel. Tap a tile to expand it; the grid always stays neat.
- **Honest numbers.** Battery time comes from the real power draw, battery health matches System Settings, and temperatures come from the processor sensors.
- **Your Mac at the top.** The model name and its chip, cores, memory and macOS version.
- **Menu bar icon your way.** Bars, Chip, Pulse, a Live graph of any reading, or hidden. It can turn green, amber or red with how hard the Mac is working.
- **Light and dark**, units (°C or °F, MB/s or Mbps), refresh rate, open at login and alerts for low battery, full storage or squeezed memory.
- **Updates itself** from this page's releases.

## Install

Download `Stats.dmg` (or `Stats-mac.zip`) from the [latest release](https://github.com/Solomon-69/Stats/releases/latest), open it and drag Stats to Applications. The app is signed and notarized by Apple.

## Build from source

```bash
./build.sh            # test build with hooks, installs to ~/Applications
RELEASE=1 ./build.sh  # release build
```

## Credits

The sensor and SMC reading code is ported from [exelban/stats](https://github.com/exelban/stats) (MIT). Everything else is written fresh.
