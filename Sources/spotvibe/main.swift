// SpotVibe — a Spotlight replacement for macOS 26.
// Copyright (C) 2026 Nicolò Santamaria
//
// This program is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License version 3, as published by the Free
// Software Foundation. It comes with ABSOLUTELY NO WARRANTY; see LICENSE.

import AppKit

// Entry point only. Everything else lives in its own file, because a global
// declared in main.swift is initialised by main() rather than lazily — which
// leaves it as uninitialised memory for anything that imports this module.

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = Controller()
    app.delegate = controller // weak in AppKit: `controller` has to outlive run(), and does
    app.setActivationPolicy(.accessory) // no Dock icon, menu-bar only
    app.run()
}
