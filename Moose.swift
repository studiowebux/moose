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

// --- Tune these ---
let PIXELS_PER_CLICK: Double = 300.0  // velocity impulse (px/sec) added per wheel tick
let FRICTION: Double         = 2.5    // deceleration rate; half-life = ln(2)/FRICTION sec
                                      //   1.0 = very long glide (~700ms half-life)
                                      //   2.5 = Apple-like  (~280ms half-life)
                                      //   5.0 = short snap  (~140ms half-life)
let MAX_VELOCITY: Double     = 4000.0 // px/sec cap
let CANCEL_ON_MOUSE_MOVE     = false  // true = cancel momentum if cursor moves during glide
let REVERSE_MOUSE_SCROLL     = false
// ------------------

let MIN_VELOCITY: Double = 8.0  // px/sec — below this momentum stops

var velocity: Double      = 0.0
var displayLink: CADisplayLink?
var scrollOrigin: CGPoint = .zero

class ScrollDriver: NSObject {
    @objc func tick(_ link: CADisplayLink) {
        let dt = link.targetTimestamp - link.timestamp
        guard abs(velocity) >= MIN_VELOCITY else { cancelMomentum(); return }
        let decay = exp(-FRICTION * dt)
        // exact integral of v(t)=v0·e^(-F·t) over [0,dt] — no stepping artifact
        let delta = velocity * (1.0 - decay) / FRICTION
        velocity *= decay
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
    let movedWindow = CANCEL_ON_MOUSE_MOVE && dx * dx + dy * dy > 2500
    let switchedApp = currentApp != scrollApp
    let cmdHeld     = CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
    if movedWindow || switchedApp || cmdHeld {
        cancelMomentum()
        return
    }
    guard let src = CGEventSource(stateID: .combinedSessionState),
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
