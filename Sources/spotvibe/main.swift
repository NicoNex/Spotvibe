import AppKit

// Entry point only. Everything else lives in its own file, because a global
// declared in main.swift is initialised by main() rather than lazily — which
// leaves it as uninitialised memory for anything that imports this module.

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.accessory) // no Dock icon, menu-bar only
app.run()
