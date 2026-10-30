# spz-replay

> Server-side race replays with broadcast cameras.

![version](https://img.shields.io/badge/version-1.7.0-ff6200) ![SPiceZ-Core](https://img.shields.io/badge/SPiceZ--Core-beta-18181b)

## Overview

Every race is recorded server-side, compressed into the database and can be played back with TV, chase, heli, bonnet, wheel and free cameras, driver switching and a clean record view.

## Features

- Automatic recording of every race
- Compressed storage
- Multiple camera modes and driver switching

## Requirements

| Resource | Type |
|---|---|
| `ox_lib` | third-party |
| `oxmysql` | third-party |
| `spz-core` | SPiceZ module |
| `spz-races` | SPiceZ module |
| `spz-vehicles` | SPiceZ module |

## Installation

Included in the [txAdmin recipe](https://github.com/SPiceZ21/spz-txrecipe). Manual install:

1. Download `spz-replay` from GitHub (latest release, or the repository) into your `resources` folder.
2. Add to `server.cfg`, after its requirements:

```cfg
ensure spz-replay
```

## Configuration

- `config.lua`

See the file for every option.

## Exports

| Export | Side |
|---|---|
| `WatchRace` | client |

```lua
exports["spz-replay"]:WatchRace(...)
```

---

Part of **SPiceZ-Core** — [documentation](https://github.com/SPiceZ21/Docs) · [all modules](https://github.com/SPiceZ21/Docs/blob/main/modules/README.md)
