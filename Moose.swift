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
// Compile: /usr/bin/swiftc Moose.swift -o Moose
// Requires: System Settings > Privacy & Security > Accessibility

import Cocoa
import CoreGraphics
import OSLog

let log = Logger(subsystem: "com.studiowebux.moose", category: "scroll")

// --- Tune these ---
let PIXELS_PER_CLICK: Double = 10.0  // base scroll distance per wheel tick (tune to taste: 10–40)
let DECAY: Double            = 0.80  // momentum decay per frame (0.7=short, 0.85=long)
let REVERSE_MOUSE_SCROLL     = false
// ------------------

let MIN_VELOCITY: Double = 0.8
let FRAME_INTERVAL       = 1.0 / 60.0

var velocity: Double = 0.0
var momentumTimer: DispatchSourceTimer?
var scrollOrigin: CGPoint = .zero
var scrollApp: pid_t = 0
var currentApp: pid_t = 0
let momentumQueue = DispatchQueue(label: "com.studiowebux.moose.momentum")

var eventTap: CFMachPort?

func postSyntheticScroll(deltaY: Double) {
    let pos = NSEvent.mouseLocation
    let dx = pos.x - scrollOrigin.x
    let dy = pos.y - scrollOrigin.y
    let movedWindow = dx * dx + dy * dy > 2500
    let switchedApp = currentApp != scrollApp
    let flags = CGEventSource.flagsState(.combinedSessionState)
    let cmdHeld = flags.rawValue & CGEventFlags.maskCommand.rawValue != 0
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
    momentumTimer?.cancel()
    momentumTimer = nil
    velocity = 0
}

func startMomentum(origin: CGPoint) {
    scrollOrigin = origin
    guard momentumTimer == nil else { return }
    scrollApp = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    let timer = DispatchSource.makeTimerSource(queue: momentumQueue)
    timer.schedule(deadline: .now(), repeating: FRAME_INTERVAL)
    timer.setEventHandler {
        guard abs(velocity) >= MIN_VELOCITY else {
            cancelMomentum()
            return
        }
        let delta = velocity
        velocity *= DECAY
        postSyntheticScroll(deltaY: delta)
    }
    timer.resume()
    momentumTimer = timer
}

let eventMask: CGEventMask = 1 << CGEventType.scrollWheel.rawValue

let tapCallback: CGEventTapCallBack = { proxy, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
            log.warning("Event tap was disabled by macOS — re-enabled.")
        }
        return nil
    }

    guard type == .scrollWheel else { return Unmanaged.passRetained(event) }

    let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous)
    guard isContinuous == 0 else { return Unmanaged.passRetained(event) }

    let rawY = event.getIntegerValueField(.scrollWheelEventScrollCount) != 0
        ? event.getIntegerValueField(.scrollWheelEventScrollCount)
        : event.getIntegerValueField(.scrollWheelEventDeltaAxis1)

    guard rawY != 0 else { return Unmanaged.passRetained(event) }

    let direction: Double = REVERSE_MOUSE_SCROLL ? -1.0 : 1.0
    let impulse = Double(rawY) * PIXELS_PER_CLICK * direction

    // Direction changed — cancel current momentum and start fresh
    if velocity != 0 && (impulse > 0) != (velocity > 0) { cancelMomentum() }

    velocity += impulse
    velocity = max(-300, min(300, velocity))

    startMomentum(origin: NSEvent.mouseLocation)
    return nil
}

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
    CGEvent.tapEnable(tap: tap, enable: true)
    log.info("Moose running — momentum scroll active. Trackpad unchanged.")
}

let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
if AXIsProcessTrustedWithOptions(options) {
    installTap()
} else {
    log.warning("Waiting for Accessibility access — grant it in System Settings then Moose will start automatically.")
    DispatchQueue.global(qos: .background).async {
        while !AXIsProcessTrusted() {
            Thread.sleep(forTimeInterval: 0.5)
        }
        log.info("Accessibility granted — starting.")
        DispatchQueue.main.async { installTap() }
    }
}

CFRunLoopRun()
