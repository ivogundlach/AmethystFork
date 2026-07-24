# Personal Amethyst fork

Fork of [ianyh/Amethyst](https://github.com/ianyh/Amethyst) at `0.24.3` (upstream commit `34e3562`),
branch `personal`. Built to fix windows silently dropping out of tiling, which shows up as a
two-pane layout that leaves one window full-screen or doesn't move anything at all.

## Identity

| | |
|---|---|
| Bundle ID | `com.ivogundlach.Amethyst` (upstream: `com.amethyst.Amethyst`) |
| Signed with | `Ivo Market Dev` — keeps the Accessibility grant across rebuilds |
| Installed at | `/Applications/Amethyst.app` |
| Config domain | `com.ivogundlach.Amethyst`, imported byte-identical from the old domain |
| Auto-update | **Removed.** Sparkle is gone from the project entirely |

Upstream 0.24.3 and the original preferences are archived at
`~/.local/state/amethyst-fork/` in case anything needs to go back.

## Build

```
./build.sh              # build, sign, install to /Applications
NO_DEPLOY=1 ./build.sh  # build only
```

Needs Xcode (deployment target was bumped 11 → 12.0; Xcode 27 refuses to build for 11).

**Don't loop this script.** Replacing the app bundle churns the record TCC keys the Accessibility
grant against; doing it repeatedly in quick succession gets the grant revoked, and a window manager
without Accessibility silently manages nothing. If that happens:

```
tccutil reset Accessibility com.ivogundlach.Amethyst
```

then relaunch and approve the prompt.

## Fixes on top of upstream

Four are upstream pull requests that were open and unmerged; two are local.

| Change | Source | What it fixes |
|---|---|---|
| Retry backoff used `^` (XOR) instead of exponentiation | [#1863](https://github.com/ianyh/Amethyst/pull/1863) | `count ^ 2 * 100` parses as `count ^ 200`, so the six retries were a flat ~200 ms each instead of 0/100/400/900/1600/2500 ms. An app slower than ~1.2 s to become observable burned the whole budget and its windows were dropped for good. |
| Observer registration retried, not abandoned | [#1868](https://github.com/ianyh/Amethyst/pull/1868) | An app whose accessibility interface isn't ready at launch returns `kAXErrorAPIDisabled`; upstream gave up after ~1.4 s and the app was never tracked. Now re-attempted on a timer until it registers or exits. |
| Duplicate window-id reflow crash | [#1868](https://github.com/ianyh/Amethyst/pull/1868) | `Dictionary(uniqueKeysWithValues:)` traps when two windows report the same id. |
| Stale accessibility elements refreshed | [#1870](https://github.com/ianyh/Amethyst/pull/1870) | Apps that hide windows instead of destroying them (Slack, Telegram, Claude) hand back a fresh element for a window already tracked under a dead one. The dead element answers identity checks but fails every read, so the window could neither tile nor be re-added. |
| Rescan an app after one of its windows is destroyed | [#1871](https://github.com/ianyh/Amethyst/pull/1871) | Closing a native tab doesn't always notify about the window that remains. |
| **Reconcile untracked windows on layout switch** | local | The general case. Tracking is driven by accessibility notifications and every path can drop a window; the fixes above each close one race. On an explicit layout command, the window server — which doesn't lie about what's on screen — is consulted and anything on screen but untracked is adopted. Costs one syscall when nothing is missing. |
| **Re-selecting the active layout applies it** | local | Picking the current layout toggles back to the previous one, by design. With no previous layout the guard returned without even a reflow, so the command looked ignored precisely when windows had drifted out of the layout. |

`WindowManager.adoptUntrackedWindows()` logs `Reconciling untracked on-screen windows for pids: […]`
whenever it actually adopts something — the line to look for if tiling ever goes wrong again.

## Deliberately unchanged

`float-small-windows` (threshold 850) still floats a window that is under 850×850 **at the moment
Amethyst first sees it**, permanently, and is never re-evaluated. That is intended: it keeps
one-off menus and settings panes from being enlarged. Worth knowing that a *main* window which
happens to be briefly small while its app launches gets floated for the rest of its life; `mod1+t`
(toggle float) is the recovery if that ever shows up.

## Gotcha: tests clobber the preference domain

The test target's host is the app, so `xcodebuild test` writes stock default hotkeys into
`com.ivogundlach.Amethyst`. After running tests, restore:

```
defaults delete com.ivogundlach.Amethyst
defaults import com.ivogundlach.Amethyst ~/.local/state/amethyst-fork/com.amethyst.Amethyst.plist.backup
```

## Pulling in upstream later

`upstream` remote is configured. The identity changes (bundle ID, deployment target, Sparkle
removal) share a commit with the first fix rather than sitting on their own, so expect to resolve
`project.pbxproj` by hand on a rebase.
