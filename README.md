# herdr-cliamp

Control [CLIAmp](https://github.com/cliamp/cliamp) — a terminal TUI for music,
podcasts, and audiobooks — from [herdr](https://herdr.dev), **without the music
stopping when you close the player**.

Press a key: CLIAmp floats in the middle of your screen. Press detach: the float
disappears and the audio keeps playing. Now-playing toasts and play/pause work
from any workspace without opening the float at all.

## The problem this solves

CLIAmp keeps its audio player *inside* the TUI process. A normal floating pane
(herdr's `type = "popup"`, tmux's `display-popup`) runs a command and closes when
that command exits — so quitting the player would stop the music. Parking CLIAmp
in a regular tab works, but then it permanently occupies a tab, and closing that
tab kills playback too.

Instead, CLIAmp runs in its own **persistent herdr session**, and the floating
pane merely *attaches* to it. A herdr session's server keeps running with no
client attached, so:

- detaching hides the float and playback continues
- no tab is consumed in any of your working workspaces
- the player survives closing the float, switching workspaces, and detaching

## Requirements

- herdr **0.8.0+**
- `cliamp` on `PATH`
- `jq`, `python3`, `bash`
- `allow_nested = true` in your main herdr config (see Setup) — the float
  attaches to a herdr session from inside a herdr pane, which herdr blocks by
  default

## Install

```sh
herdr plugin install <owner>/herdr-cliamp
```

Or from a checkout:

```sh
git clone https://github.com/<owner>/herdr-cliamp
cd herdr-cliamp && herdr plugin link .
```

## Setup

**1. Allow nesting.** In `~/.config/herdr/config.toml`:

```toml
[experimental]
allow_nested = true
```

Without this, opening the float fails with *"nested herdr is disabled by
default"*.

**2. Bind the actions.** herdr plugins cannot declare keybindings, so add these
yourself (adjust keys to taste):

```toml
  [[keys.command]]
  key = "prefix+m"
  type = "plugin_action"
  command = "herdr-cliamp.open"
  description = "CLIAmp: floating player"

  [[keys.command]]
  key = "prefix+M"
  type = "plugin_action"
  command = "herdr-cliamp.status"
  description = "CLIAmp: now playing"

  [[keys.command]]
  key = "prefix+p"
  type = "plugin_action"
  command = "herdr-cliamp.toggle"
  description = "CLIAmp: play/pause"
```

Then `herdr server reload-config`.

> **Check for conflicts.** herdr resolves a duplicate binding by *silently
> disabling* one side. `herdr server reload-config` prints `"status":"applied"`
> with empty diagnostics when your keys are free, and `"partial"` with a
> `disabled keys.<action>` diagnostic when they are not. Note `prefix+p` and
> `prefix+n` are herdr's defaults for `previous_tab`/`next_tab`; to reclaim one,
> set it empty (`previous_tab = ""`) in `[keys]`.

## Actions

| Action | Does | Needs the float? |
|---|---|---|
| `herdr-cliamp.open` | Open the floating player | — |
| `herdr-cliamp.status` | Toast the current track + progress | No |
| `herdr-cliamp.toggle` | Play/pause | No |
| `herdr-cliamp.next` | Next track | No |
| `herdr-cliamp.prev` | Previous track | No |

`status`, `toggle`, `next`, and `prev` work from anywhere because CLIAmp's IPC
socket sits at a fixed path (`~/.config/cliamp/cliamp.sock`) regardless of which
herdr session hosts the TUI.

All five also appear in herdr's action menu, and run via
`herdr plugin action invoke herdr-cliamp.<id>`.

## Using it

- **Open**: your `open` key. First use starts the session and CLIAmp; later uses
  just attach.
- **Hide**: detach inside the float (`prefix+d` with the session's own prefix).
  The music keeps playing.
- **Quit for real**: quit CLIAmp itself (`q`). Its pane exits, and the next
  `open` starts it fresh.

## Configuration

Optional. Copy the example into the plugin's config dir:

```sh
cp config.sh.example "$(herdr plugin config-dir herdr-cliamp)/config.sh"
```

| Variable | Default | Meaning |
|---|---|---|
| `CLIAMP_SESSION` | `music` | Name of the herdr session hosting the player |
| `CLIAMP_CMD` | `cliamp` | Launch command (add flags here) |
| `CLIAMP_TOAST_POSITION` | `top-right` | Toast corner |
| `CLIAMP_MAIN_SOCKET` | main session socket | Where toasts are sent |

### Matching your keybindings inside the float

The player session loads its own herdr config (no sidebar, no tab bar). Anything
it does not set falls back to **herdr's defaults** — so by default the float uses
`ctrl+b` as its prefix, not whatever you use.

To make the float match your muscle memory, drop a `session.toml` into the plugin
config dir with your own `[keys]` block copied from your main config; it takes
precedence over the bundled one:

```sh
cp session.toml "$(herdr plugin config-dir herdr-cliamp)/session.toml"
# then edit its [keys] to mirror your main config.toml
```

herdr has no config-include mechanism, so this is a copy: if you rebind keys
later, mirror the change here too.

## How it works

```
your session (default)                player session ("music")
┌──────────────────────────┐          ┌──────────────────────────┐
│ workspaces, tabs, panes  │          │ one pane: cliamp (exec)  │
│                          │          │ server runs with NO      │
│  ┌────────────────────┐  │ attach   │ client attached  ────────┼─► audio
│  │ floating overlay   │──┼─────────►│                          │
│  └────────────────────┘  │  detach  └──────────────────────────┘
└──────────────────────────┘
        ▲                                        │
        └──── toasts (main session socket) ──────┘
              status/toggle via cliamp.sock (fixed path)
```

`cliamp.sh` is the single entry point for every action. It keeps two sockets
straight: CLIAmp's fixed IPC socket (for playback state) and herdr's
*per-session* API socket — toasts must target the **main** session, or they
render in the hidden session where nobody can see them.

The session bootstrap is idempotent and self-healing: it restarts the session
server if stopped, recreates the workspace if the pane is gone, and launches
CLIAmp only when it is not already the pane's foreground process. That last check
matters — CLIAmp is a singleton on its IPC socket, and a second instance would
play over the first while answering for neither.

## Limitations

- **`allow_nested` is experimental** in herdr, by herdr's own labelling.
- **Radio metadata needs a recent cliamp.** Showing station + artist/song
  requires cliamp's IPC status to report `station` and resolve `title`/`artist`
  from the live ICY tag. Older builds send only the station name, and the toast
  degrades to that plus progress.
- **No auto-popping toasts on track change.** herdr cannot observe CLIAmp's
  internal events; the status action is pull-based. A CLIAmp Lua plugin hooking
  `track.change` could push them, but note `cliamp.exec.run()` passes only
  `PATH`/`HOME`/`LANG` to subprocesses, so it needs a wrapper that sets
  `HERDR_SOCKET_PATH` itself.
- **Linux/macOS only.**

## License

MIT
