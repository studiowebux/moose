#!/usr/bin/env swift
// Moose — linear + momentum scroll for non-Apple mice on macOS
// Copyright (C) 2026 Studio Webux (studiowebux.com)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// https://www.gnu.org/licenses/gpl-3.0.html
// Compile: /usr/bin/swiftc Moose.swift -o Moose -framework IOKit -framework Cocoa
// Requires: System Settings > Privacy & Security > Accessibility

import Cocoa
import CoreGraphics
import IOKit.hid
import OSLog
import QuartzCore

let log = Logger(subsystem: "com.studiowebux.moose", category: "scroll")

// MARK: - Config

let CONFIG_PATH: String = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("moose/config.json").path

var PIXELS_PER_CLICK: Double = 200.0  // velocity impulse (px/sec) added per wheel tick
var FRICTION: Double         = 3.5    // deceleration rate; half-life = ln(2)/FRICTION sec
var MAX_VELOCITY: Double     = 3000.0 // px/sec cap
var MIN_VELOCITY: Double     = 25.0   // px/sec — below this momentum stops
var CANCEL_ON_MOUSE_MOVE           = false  // true = cancel momentum if cursor moves during glide
var CANCEL_ON_MOUSE_MOVE_THRESHOLD = 50.0   // px radius before momentum cancels
var REVERSE_MOUSE_SCROLL           = false
var DEBUG_OVERLAY                  = false

func loadConfig() {
    let url = URL(fileURLWithPath: CONFIG_PATH)
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        log.error("Config: could not read file — \(error.localizedDescription)")
        return
    }
    let json: [String: Any]
    do {
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.error("Config: expected a JSON object at top level")
            return
        }
        json = parsed
    } catch {
        log.error("Config: invalid JSON — \(error.localizedDescription)")
        return
    }
    var warnings: [String] = []
    func load<T>(_ key: String, into setter: (T) -> Void) {
        guard let raw = json[key] else { return }
        if let v = raw as? T { setter(v) }
        else { warnings.append("\(key): expected \(T.self), got \(type(of: raw))") }
    }
    load("pixelsPerClick")          { PIXELS_PER_CLICK = $0 }
    load("friction")                { FRICTION = $0 }
    load("maxVelocity")             { MAX_VELOCITY = $0 }
    load("minVelocity")             { MIN_VELOCITY = $0 }
    load("cancelOnMouseMoveThreshold") { CANCEL_ON_MOUSE_MOVE_THRESHOLD = $0 }
    load("cancelOnMouseMove")       { CANCEL_ON_MOUSE_MOVE = $0 }
    load("reverseScroll")           { REVERSE_MOUSE_SCROLL = $0 }
    load("debug")                   { DEBUG_OVERLAY = $0 }
    DebugOverlay.shared.setVisible(DEBUG_OVERLAY)
    for w in warnings { log.warning("Config: \(w) — key ignored") }
    log.info("Config loaded — pixelsPerClick:\(PIXELS_PER_CLICK) friction:\(FRICTION) maxVelocity:\(MAX_VELOCITY) minVelocity:\(MIN_VELOCITY) cancelOnMouseMove:\(CANCEL_ON_MOUSE_MOVE) threshold:\(CANCEL_ON_MOUSE_MOVE_THRESHOLD) reverseScroll:\(REVERSE_MOUSE_SCROLL)")
}

func writeDefaultConfig() {
    let dir = (CONFIG_PATH as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    guard !FileManager.default.fileExists(atPath: CONFIG_PATH) else { return }
    let defaults: [String: Any] = [
        "pixelsPerClick": PIXELS_PER_CLICK,
        "friction": FRICTION,
        "maxVelocity": MAX_VELOCITY,
        "minVelocity": MIN_VELOCITY,
        "cancelOnMouseMove": CANCEL_ON_MOUSE_MOVE,
        "cancelOnMouseMoveThreshold": CANCEL_ON_MOUSE_MOVE_THRESHOLD,
        "reverseScroll": REVERSE_MOUSE_SCROLL,
        "debug": DEBUG_OVERLAY
    ]
    if let data = try? JSONSerialization.data(withJSONObject: defaults, options: .prettyPrinted) {
        try? data.write(to: URL(fileURLWithPath: CONFIG_PATH))
        log.info("Default config written to \(CONFIG_PATH)")
    }
}

var configWatcher: DispatchSourceFileSystemObject?
var configReloadWork: DispatchWorkItem?

func watchConfig() {
    let dir = (CONFIG_PATH as NSString).deletingLastPathComponent
    let fd = open(dir, O_EVTONLY)
    guard fd >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
    source.setEventHandler {
        guard FileManager.default.fileExists(atPath: CONFIG_PATH) else { return }
        configReloadWork?.cancel()
        let work = DispatchWorkItem { loadConfig() }
        configReloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }
    source.setCancelHandler { close(fd) }
    source.resume()
    configWatcher = source
}

// MARK: - Debug Overlay

// Circle drawn around cursor showing momentum state
class CursorRingView: NSView {
    var progress: CGFloat = 0  // 0 = idle, 1 = max velocity
    var active: Bool = false

    override func draw(_ rect: CGRect) {
        guard active else { return }
        let color = NSColor(hue: 0.33 * (1 - progress), saturation: 1, brightness: 1, alpha: 0.85)
        color.setStroke()
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
        path.lineWidth = 2.5
        path.stroke()
    }
}

class DebugOverlay {
    static let shared = DebugOverlay()
    private var infoWindow: NSWindow?
    private var label: NSTextField?
    private var ringWindow: NSWindow?
    private var ringView: CursorRingView?
    private var mouseMonitor: Any?

    func setVisible(_ visible: Bool) {
        if visible { show() } else { hide() }
    }

    private func show() {
        showInfo()
        update()
    }

    private func hide() {
        infoWindow?.orderOut(nil); infoWindow = nil; label = nil
        ringWindow?.orderOut(nil); ringWindow = nil; ringView = nil
    }

    private func showInfo() {
        guard infoWindow == nil else { return }
        let w = NSWindow(
            contentRect: NSRect(x: 20, y: 20, width: 300, height: 185),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        w.level = .floating
        w.backgroundColor = NSColor.black.withAlphaComponent(0.75)
        w.isOpaque = false
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary]
        w.contentView?.wantsLayer = true
        w.contentView?.layer?.cornerRadius = 10
        let field = NSTextField(frame: w.contentView!.bounds.insetBy(dx: 10, dy: 10))
        field.isEditable = false; field.isBordered = false; field.drawsBackground = false
        field.textColor = .white
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.autoresizingMask = [.width, .height]
        w.contentView?.addSubview(field)
        w.makeKeyAndOrderFront(nil)
        infoWindow = w; label = field
    }

    private func showRing(at origin: CGPoint, radius: CGFloat) {
        let size = radius * 2
        let frame = NSRect(x: origin.x - radius, y: origin.y - radius, width: size, height: size)
        if let w = ringWindow { w.setFrame(frame, display: true); return }
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver
        w.backgroundColor = .clear
        w.isOpaque = false
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary]
        let v = CursorRingView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        w.contentView?.addSubview(v)
        w.makeKeyAndOrderFront(nil)
        ringWindow = w; ringView = v
    }

    func update() {
        guard infoWindow != nil else { return }
        let isActive = velocity != 0
        let progress = CGFloat(min(abs(velocity) / MAX_VELOCITY, 1.0))
        let state = isActive ? String(format: "%.0f px/s", abs(velocity)) : "idle"

        label?.stringValue = """
        Moose debug
        ────────────────────────────
        velocity      \(state)
        ────────────────────────────
        pixelsPerClick  \(Int(PIXELS_PER_CLICK))
        friction        \(FRICTION)
        maxVelocity     \(Int(MAX_VELOCITY))
        minVelocity     \(Int(MIN_VELOCITY))
        reverseScroll   \(REVERSE_MOUSE_SCROLL)
        cancelOnMove    \(CANCEL_ON_MOUSE_MOVE ? "✓ enabled (\(Int(CANCEL_ON_MOUSE_MOVE_THRESHOLD))px)" : "✗ disabled")
        """

        if CANCEL_ON_MOUSE_MOVE && isActive {
            showRing(at: scrollOrigin, radius: CGFloat(CANCEL_ON_MOUSE_MOVE_THRESHOLD))
            ringView?.active = true
            ringView?.progress = progress
            ringView?.needsDisplay = true
        } else {
            ringWindow?.orderOut(nil); ringWindow = nil; ringView = nil
        }
    }
}

var velocity: Double        = 0.0
var displayLink: CADisplayLink?
var scrollEventSource       = CGEventSource(stateID: .combinedSessionState)
var scrollOrigin: CGPoint   = .zero

class ScrollDriver: NSObject {
    @objc func tick(_ link: CADisplayLink) {
        let dt = link.targetTimestamp - link.timestamp
        guard abs(velocity) >= MIN_VELOCITY else { cancelMomentum(); return }
        let decay = exp(-FRICTION * dt)
        // exact integral of v(t)=v0·e^(-F·t) over [0,dt] — no stepping artifact
        let delta = velocity * (1.0 - decay) / FRICTION
        velocity *= decay
        if DEBUG_OVERLAY { DebugOverlay.shared.update() }
        postSyntheticScroll(deltaY: delta)
    }
}
let scrollDriver = ScrollDriver()
var scrollApp: pid_t      = 0
var currentApp: pid_t     = 0
var connectedMice: Int    = 0
var hidManager: IOHIDManager?

var eventTap: CFMachPort?

// MARK: - Scroll

func postSyntheticScroll(deltaY: Double) {
    let pos = NSEvent.mouseLocation
    let dx = pos.x - scrollOrigin.x
    let dy = pos.y - scrollOrigin.y
    let t = CANCEL_ON_MOUSE_MOVE_THRESHOLD
    let movedWindow = CANCEL_ON_MOUSE_MOVE && dx * dx + dy * dy > t * t
    let switchedApp = currentApp != scrollApp
    let cmdHeld     = CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
    if movedWindow || switchedApp || cmdHeld {
        cancelMomentum()
        return
    }
    guard let src = scrollEventSource,
          let event = CGEvent(
              scrollWheelEvent2Source: src,
              units: .pixel,
              wheelCount: 1,
              wheel1: 0, wheel2: 0, wheel3: 0
          ) else { return }
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: deltaY)
    event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: deltaY / 10.0)
    event.post(tap: .cgSessionEventTap)
}

func cancelMomentum() {
    displayLink?.invalidate()
    displayLink = nil
    velocity = 0
    if DEBUG_OVERLAY { DebugOverlay.shared.update() }
}

func startMomentum(origin: CGPoint) {
    scrollOrigin = origin
    guard displayLink == nil else { return }
    scrollApp = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    guard let link: CADisplayLink = NSScreen.main?.displayLink(target: scrollDriver, selector: #selector(ScrollDriver.tick(_:))) else { return }
    link.add(to: RunLoop.main, forMode: RunLoop.Mode.common)
    displayLink = link
}

// MARK: - Event tap

let eventMask: CGEventMask = 1 << CGEventType.scrollWheel.rawValue

let tapCallback: CGEventTapCallBack = { proxy, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if connectedMice > 0, let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            log.warning("Event tap was disabled by macOS — re-enabled.")
        }
        return nil
    }
    guard type == .scrollWheel else { return Unmanaged.passRetained(event) }
    let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous)
    guard isContinuous == 0 else { return Unmanaged.passRetained(event) }
    let scrollCount = event.getIntegerValueField(.scrollWheelEventScrollCount)
    let rawY = scrollCount != 0 ? scrollCount : event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
    guard rawY != 0 else { return Unmanaged.passRetained(event) }
    let direction: Double = REVERSE_MOUSE_SCROLL ? -1.0 : 1.0
    let impulse = Double(rawY) * PIXELS_PER_CLICK * direction
    if velocity != 0 && (impulse > 0) != (velocity > 0) { cancelMomentum() }
    velocity += impulse
    velocity = max(-MAX_VELOCITY, min(MAX_VELOCITY, velocity))
    startMomentum(origin: NSEvent.mouseLocation)
    return nil
}

// MARK: - IOKit mouse detection

func externalMouseInfo(_ device: IOHIDDevice) -> (product: String, transport: String)? {
    let t = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? "unknown"
    guard t == "USB" || t == "Bluetooth" || t == "AmbiguousNonBluetooth" else { return nil }
    let p = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "unknown"
    return (p, t)
}

let mouseConnected: IOHIDDeviceCallback = { _, _, _, device in
    guard let (product, transport) = externalMouseInfo(device) else { return }
    connectedMice += 1
    log.info("Mouse connected: \(product) (\(transport)) — total: \(connectedMice)")
    if connectedMice == 1, let tap = eventTap {
        CGEvent.tapEnable(tap: tap, enable: true)
        log.info("Tap enabled.")
    }
}

let mouseDisconnected: IOHIDDeviceCallback = { _, _, _, device in
    guard let (product, transport) = externalMouseInfo(device) else { return }
    connectedMice = max(0, connectedMice - 1)
    log.info("Mouse disconnected: \(product) (\(transport)) — total: \(connectedMice)")
    if connectedMice == 0, let tap = eventTap {
        cancelMomentum()
        CGEvent.tapEnable(tap: tap, enable: false)
        log.info("Tap disabled — no external mice connected.")
    }
}

func setupMouseDetection() {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    hidManager = manager
    // Match both mouse (0x02) and pointer (0x01) usages — some mice report as pointer
    let matchingArray = [
        [kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
         kIOHIDDeviceUsageKey as String:     kHIDUsage_GD_Mouse],
        [kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
         kIOHIDDeviceUsageKey as String:     kHIDUsage_GD_Pointer]
    ] as CFArray
    IOHIDManagerSetDeviceMatchingMultiple(manager, matchingArray)
    IOHIDManagerRegisterDeviceMatchingCallback(manager, mouseConnected, nil)
    IOHIDManagerRegisterDeviceRemovalCallback(manager, mouseDisconnected, nil)
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
}

// MARK: - Boot

func installTap() {
    NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification,
        object: nil,
        queue: .main
    ) { note in
        currentApp = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier ?? 0
    }

    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: eventMask,
        callback: tapCallback,
        userInfo: nil
    ) else {
        log.error("Could not create event tap — grant Accessibility access in System Settings > Privacy & Security > Accessibility")
        exit(1)
    }
    eventTap = tap
    let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)

    // Start disabled — IOKit will enable it if a mouse is already connected
    CGEvent.tapEnable(tap: tap, enable: false)

    setupMouseDetection()
    log.info("Moose running — tap disabled until external mouse detected.")
}

writeDefaultConfig()
loadConfig()
watchConfig()

let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
if AXIsProcessTrustedWithOptions(options) {
    installTap()
} else {
    log.warning("Waiting for Accessibility access — grant it in System Settings then Moose will start automatically.")
    DistributedNotificationCenter.default().addObserver(
        forName: NSNotification.Name("com.apple.accessibility.api"),
        object: nil,
        queue: .main
    ) { _ in
        guard AXIsProcessTrusted() else { return }
        DistributedNotificationCenter.default().removeObserver(
            DistributedNotificationCenter.default(),
            name: NSNotification.Name("com.apple.accessibility.api"),
            object: nil
        )
        log.info("Accessibility granted — starting.")
        installTap()
    }
}

CFRunLoopRun()
