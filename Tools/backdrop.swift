// SpotVibe — a Spotlight replacement for macOS 26.
// Copyright (C) 2026 Nicolò Santamaria
//
// This program is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License version 3, as published by the Free
// Software Foundation. It comes with ABSOLUTELY NO WARRANTY; see LICENSE.

// A full-screen wallpaper, for screenshots only.
//
// The panel is glass: it shows whatever is behind it, which on a working Mac is mail,
// messages and whatever video was paused. This puts something neutral back there so the
// screenshots are reproducible and carry nothing private.
//
//     swift Tools/backdrop.swift &
//
// It sits at the normal window level, far below the panel's .screenSaver.

import AppKit

final class Backdrop: NSView {
    override func draw(_ dirty: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        // A deep blue-violet wash. Glass needs a gradient to refract — a flat colour shows
        // none of the lensing at the rim, which is most of what there is to look at.
        let sky = CGGradient(colorsSpace: space,
                             colors: [CGColor(red: 0.09, green: 0.11, blue: 0.28, alpha: 1),
                                      CGColor(red: 0.23, green: 0.17, blue: 0.42, alpha: 1),
                                      CGColor(red: 0.45, green: 0.26, blue: 0.40, alpha: 1)] as CFArray,
                             locations: [0, 0.55, 1])!
        context.drawLinearGradient(sky, start: CGPoint(x: 0, y: bounds.maxY),
                                   end: CGPoint(x: bounds.maxX, y: 0), options: [])

        // Soft blooms, so the material has something with structure to bend.
        for (x, y, r, color) in [
            (0.22, 0.74, 0.34, CGColor(red: 0.30, green: 0.55, blue: 1.0, alpha: 0.42)),
            (0.78, 0.30, 0.40, CGColor(red: 1.0, green: 0.42, blue: 0.52, alpha: 0.30)),
            (0.58, 0.86, 0.26, CGColor(red: 0.35, green: 0.92, blue: 0.85, alpha: 0.24)),
        ] {
            let center = CGPoint(x: bounds.width * x, y: bounds.height * y)
            let radius = min(bounds.width, bounds.height) * r
            let bloom = CGGradient(colorsSpace: space,
                                   colors: [color, color.copy(alpha: 0)!] as CFArray,
                                   locations: [0, 1])!
            context.drawRadialGradient(bloom, startCenter: center, startRadius: 0,
                                       endCenter: center, endRadius: radius, options: [])
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var windows: [NSWindow] = []
for screen in NSScreen.screens {
    let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                          backing: .buffered, defer: false, screen: screen)
    window.level = .normal
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    window.contentView = Backdrop(frame: screen.frame)
    window.setFrame(screen.frame, display: true)
    window.orderFrontRegardless()
    windows.append(window)
}
app.run()
