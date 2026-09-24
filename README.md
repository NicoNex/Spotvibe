# SpotVibe

A Spotlight alternative for macOS 26+: a Liquid Glass search panel that searches
your apps and files and never searches the internet — it only offers to hand the
query to your default browser.

## Use

`⌥Space` opens the panel. Empty field shows every app as a grid; typing narrows
the grid and adds a file list underneath. `↑ ↓ ← →` move, `Return` opens,
`Esc` closes. The menu-bar item opens it too, and quits the app.

The last row always offers to search the web, which opens your default browser.

## Build

    make test     # swift-testing suite
    make app      # dist/SpotVibe.app
    make dmg      # dist/SpotVibe-1.0.0.dmg
    make run      # build the bundle and launch it

Needs the macOS 26 SDK. Builds with the Command Line Tools alone — no Xcode, at
the cost of two hand-written property-wrapper expansions in `RootView.swift`
(the SwiftUI macro plugin ships only with Xcode).

## How it works

- **Apps** come from a directory listing of `/Applications`,
  `/System/Applications` and `~/Applications`, read once at launch and filtered
  in memory, so they appear on the same keystroke that typed them.
- **Files** come from Spotlight's own index via `NSMetadataQuery`, scoped to the
  home directory, debounced by 120 ms. No second index is built or maintained.
- **Ranking** is frecency: every open adds 1 to a score that halves every 30
  days, recorded against every prefix of what was typed. Opening Firefox after
  typing `fire` teaches `f`, `fi`, `fir` and `fire`, so next time the first
  keystroke already puts it on top. Stored in
  `~/Library/Application Support/SpotVibe/frecency.json`.
- **Appearance** follows System Settings: the glass takes the system accent
  colour, and Reduce Transparency swaps the glass for a solid window background.

## Deliberate simplifications

Marked in the source with `ponytail:` comments, each naming what was skipped and
when to add it. `grep -rn "ponytail:" Sources` lists them.
