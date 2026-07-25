#!/usr/bin/env swift
// Drives and verifies the Deus Ex: Mankind Divided built-in benchmark.
// Author: Timur Isaev

import CoreGraphics
import CoreImage
import Darwin
import Foundation
import ImageIO
import Vision

// swiftlint:disable file_length

private let rendererReadyMarker = "[NxApp] Renderer initialized"
private let benchmarkStartedMarker = "[Benchmark] Benchmark started."
private let statisticsStartedMarker =
    "[Benchmark] Benchmark delay expired; starting statistics capture."
private let benchmarkStoppedMarker = "[Benchmark] Benchmark stopped."

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

private func parsePositiveInteger(_ value: String, name: String) -> Int {
    guard let parsed = Int(value), parsed > 0 else {
        fail("\(name) must be a positive integer")
    }
    return parsed
}

private func processExists(_ pid: pid_t) -> Bool {
    if kill(pid, 0) == 0 {
        return true
    }
    return errno == EPERM
}

private func readText(_ url: URL) -> String {
    guard let data = try? Data(contentsOf: url),
          let text = String(bytes: data, encoding: .utf8)
    else {
        return ""
    }
    return text
}

private func logLines(containing marker: String, in titleLogURL: URL) -> [String] {
    readText(titleLogURL)
        .split(whereSeparator: \.isNewline)
        .filter { $0.contains(marker) }
        .map(String.init)
}

private func waitForLogMarker(
    _ marker: String,
    titleLogURL: URL,
    pid: pid_t,
    timeoutSeconds: Int,
    afterCount: Int = 0
) -> String {
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
    while Date() < deadline {
        let matchingLines = logLines(containing: marker, in: titleLogURL)
        if matchingLines.count > afterCount {
            return matchingLines[afterCount]
        }
        if !processExists(pid) {
            fail("DXMD process \(pid) exited before log marker: \(marker)")
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    fail("timed out waiting for Deus Ex log marker: \(marker)")
}

private func findLogLine(
    containing marker: String,
    in titleLogURL: URL,
    afterCount: Int
) -> String? {
    let matchingLines = logLines(containing: marker, in: titleLogURL)
    guard matchingLines.count > afterCount else {
        return nil
    }
    return matchingLines[afterCount]
}

private func postKey(_ keyCode: CGKeyCode, to pid: pid_t) {
    guard let source = CGEventSource(stateID: .hidSystemState),
          let keyDown = CGEvent(
              keyboardEventSource: source,
              virtualKey: keyCode,
              keyDown: true
          ),
          let keyUp = CGEvent(
              keyboardEventSource: source,
              virtualKey: keyCode,
              keyDown: false
          )
    else {
        fail("could not create a CoreGraphics keyboard event")
    }

    keyDown.postToPid(pid)
    Thread.sleep(forTimeInterval: 0.1)
    keyUp.postToPid(pid)
}

private func gameWindowID(for pid: pid_t) -> CGWindowID {
    guard let windowList = CGWindowListCopyWindowInfo(
        [.optionAll],
        kCGNullWindowID
    ) as? [[String: Any]]
    else {
        fail("could not inspect the macOS window list")
    }

    let candidates: [(id: CGWindowID, area: CGFloat)] = windowList.compactMap { window in
        guard let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?
            .int32Value,
            ownerPID == pid,
            let number = (window[kCGWindowNumber as String] as? NSNumber)?
                .uint32Value,
            let boundsDictionary = window[kCGWindowBounds as String]
                as? NSDictionary,
            let bounds = CGRect(
                dictionaryRepresentation: boundsDictionary as CFDictionary
            ),
            bounds.width >= 1000,
            bounds.height >= 700
        else {
            return nil
        }
        return (CGWindowID(number), bounds.width * bounds.height)
    }
    guard let window = candidates.max(by: { $0.area < $1.area }) else {
        fail("could not identify the Deus Ex game window for PID \(pid)")
    }
    return window.id
}

private func captureWindow(_ windowID: CGWindowID, to imageURL: URL) {
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-l", String(windowID), imageURL.path]
    do {
        try capture.run()
        capture.waitUntilExit()
    } catch {
        fail("could not start screencapture: \(error)")
    }
    guard capture.terminationStatus == 0 else {
        fail("screencapture failed for Deus Ex window \(windowID)")
    }
}

private func normalizedMenuText(_ text: String) -> String {
    text
        .uppercased()
        .replacingOccurrences(of: "’", with: "'")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

private func averageLuminance(
    for observation: VNRecognizedTextObservation,
    in image: CIImage,
    context: CIContext
) -> Double {
    let box = observation.boundingBox
    let sample = CGRect(
        x: (box.minX - 0.002) * image.extent.width,
        y: (box.minY - 0.002) * image.extent.height,
        width: (box.width + 0.004) * image.extent.width,
        height: (box.height + 0.004) * image.extent.height
    )
    guard let filter = CIFilter(
        name: "CIAreaAverage",
        parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: sample)
        ]
    ), let output = filter.outputImage
    else {
        fail("could not create menu-highlight luminance filter")
    }
    var pixel = [UInt8](repeating: 0, count: 4)
    context.render(
        output,
        toBitmap: &pixel,
        rowBytes: 4,
        bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
        format: .RGBA8,
        colorSpace: CGColorSpaceCreateDeviceRGB()
    )
    return (
        Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])
    ) / 3.0
}

private func inspectMenu(
    windowID: CGWindowID,
    imageURL: URL
) -> [String: Double] {
    captureWindow(windowID, to: imageURL)
    guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        fail("could not read captured Deus Ex window")
    }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    do {
        try VNImageRequestHandler(cgImage: image).perform([request])
    } catch {
        fail("could not recognize Deus Ex menu text: \(error)")
    }

    let coreImage = CIImage(cgImage: image)
    let context = CIContext(options: [.cacheIntermediates: false])
    var items: [String: Double] = [:]
    for observation in request.results ?? [] {
        guard let candidate = observation.topCandidates(1).first else {
            continue
        }
        items[normalizedMenuText(candidate.string)] = averageLuminance(
            for: observation,
            in: coreImage,
            context: context
        )
    }
    return items
}

private func navigateToMenuItem(
    _ target: String,
    windowID: CGWindowID,
    imageURL: URL,
    pid: pid_t
) {
    let selectedLuminance = 150.0
    let downArrow: CGKeyCode = 125
    for _ in 0 ..< 20 {
        let items = inspectMenu(windowID: windowID, imageURL: imageURL)
        if let luminance = items[target], luminance >= selectedLuminance {
            print("selected menu item: \(target)")
            return
        }
        guard items[target] != nil else {
            Thread.sleep(forTimeInterval: 1.0)
            continue
        }
        postKey(downArrow, to: pid)
        Thread.sleep(forTimeInterval: 1.5)
    }
    fail("could not select Deus Ex menu item: \(target)")
}

private func prepareMainMenu(
    windowID: CGWindowID,
    imageURL: URL,
    pid: pid_t
) {
    let returnKey: CGKeyCode = 36
    let escapeKey: CGKeyCode = 53
    for _ in 0 ..< 20 {
        let items = inspectMenu(windowID: windowID, imageURL: imageURL)
        if items["EXTRAS"] != nil {
            return
        }
        if items["OK"] != nil ||
            items.keys.contains(where: { $0.hasPrefix("BENCHMARK RESULTS") }) {
            postKey(returnKey, to: pid)
        } else {
            postKey(escapeKey, to: pid)
        }
        Thread.sleep(forTimeInterval: 1.5)
    }
    fail("could not restore the Deus Ex main menu")
}

private func enterMenu(
    from sourceItem: String,
    to targetItem: String,
    windowID: CGWindowID,
    imageURL: URL,
    pid: pid_t
) {
    let returnKey: CGKeyCode = 36
    for _ in 0 ..< 5 {
        postKey(returnKey, to: pid)
        for _ in 0 ..< 6 {
            Thread.sleep(forTimeInterval: 1.0)
            let items = inspectMenu(windowID: windowID, imageURL: imageURL)
            if items[targetItem] != nil {
                print("entered menu containing: \(targetItem)")
                return
            }
            if let sourceLuminance = items[sourceItem],
               sourceLuminance >= 150.0 {
                break
            }
        }
    }
    fail("could not enter Deus Ex menu containing: \(targetItem)")
}

private func startBenchmark(
    windowID: CGWindowID,
    imageURL: URL,
    titleLogURL: URL,
    pid: pid_t,
    startMarkerBaseline: Int
) -> String {
    let returnKey: CGKeyCode = 36
    for _ in 0 ..< 5 {
        postKey(returnKey, to: pid)
        let deadline = Date().addingTimeInterval(12)
        while Date() < deadline {
            if let line = findLogLine(
                containing: benchmarkStartedMarker,
                in: titleLogURL,
                afterCount: startMarkerBaseline
            ) {
                return line
            }
            if !processExists(pid) {
                fail("DXMD exited before its benchmark-start marker")
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        let items = inspectMenu(windowID: windowID, imageURL: imageURL)
        if let benchmarkLuminance = items["BENCHMARK"],
           benchmarkLuminance >= 150.0 {
            continue
        }
        return waitForLogMarker(
            benchmarkStartedMarker,
            titleLogURL: titleLogURL,
            pid: pid,
            timeoutSeconds: 45,
            afterCount: startMarkerBaseline
        )
    }
    fail("could not start the selected Deus Ex benchmark")
}

private func latestPresentTimestamp(in metricsURL: URL) -> Int64 {
    let metrics = readText(metricsURL)
    var latest: Int64?
    for line in metrics.split(whereSeparator: \.isNewline).dropFirst() {
        let columns = line.split(
            separator: "\t",
            omittingEmptySubsequences: false
        )
        guard columns.count == 6,
              columns[1] == "present",
              let timestamp = Int64(columns[0])
        else {
            continue
        }
        latest = max(latest ?? timestamp, timestamp)
    }
    guard let timestamp = latest else {
        fail("metrics contain no completed Present at a benchmark marker")
    }
    return timestamp
}

private struct BenchmarkMarkers {
    let pid: pid_t
    let benchmarkStartedLine: String
    let statisticsStartedLine: String
    let benchmarkStoppedLine: String?
    let sceneStartTimestampNs: Int64
    let sceneEndTimestampNs: Int64?
}

private func writeMarkers(_ markers: BenchmarkMarkers, to outputURL: URL) {
    var payload: [String: Any] = [
        "schemaVersion": 1,
        "author": "Timur Isaev",
        "pid": Int(markers.pid),
        "automation": [
            "mainMenuTarget": "EXTRAS",
            "extrasMenuTarget": "BENCHMARK",
            "selectionVerification": "Vision OCR and selected-row luminance"
        ],
        "benchmarkStartedLogLine": markers.benchmarkStartedLine,
        "statisticsStartedLogLine": markers.statisticsStartedLine,
        "sceneStartTimestampNs": markers.sceneStartTimestampNs
    ]
    if let benchmarkStoppedLine = markers.benchmarkStoppedLine {
        payload["benchmarkStoppedLogLine"] = benchmarkStoppedLine
    } else {
        payload["benchmarkStoppedLogLine"] = NSNull()
    }
    if let sceneEndTimestampNs = markers.sceneEndTimestampNs {
        payload["sceneEndTimestampNs"] = sceneEndTimestampNs
        payload["sceneDurationSeconds"] =
            Double(sceneEndTimestampNs - markers.sceneStartTimestampNs)
                / 1_000_000_000
    } else {
        payload["sceneEndTimestampNs"] = NSNull()
        payload["sceneDurationSeconds"] = NSNull()
    }

    do {
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        var rendered = data
        rendered.append(0x0a)
        try rendered.write(to: outputURL, options: .atomic)
    } catch {
        fail("could not write scene markers: \(error)")
    }
}

private let arguments = CommandLine.arguments
guard arguments.count == 7 else {
    FileHandle.standardError.write(
        Data(
            """
            usage: drive-deus-ex-benchmark.swift PID TITLE_LOG METRICS_TSV \
            MARKERS_JSON MENU_SETTLE_SECONDS SCENE_TIMEOUT_SECONDS

            """.utf8
        )
    )
    exit(2)
}

let parsedPID = parsePositiveInteger(arguments[1], name: "PID")
guard parsedPID <= Int(Int32.max) else {
    fail("PID is outside the supported range")
}
let pid = pid_t(parsedPID)
let titleLogURL = URL(fileURLWithPath: arguments[2])
let metricsURL = URL(fileURLWithPath: arguments[3])
let markersURL = URL(fileURLWithPath: arguments[4])
let menuSettleSeconds = parsePositiveInteger(
    arguments[5],
    name: "MENU_SETTLE_SECONDS"
)
let sceneTimeoutSeconds = parsePositiveInteger(
    arguments[6],
    name: "SCENE_TIMEOUT_SECONDS"
)

_ = waitForLogMarker(
    rendererReadyMarker,
    titleLogURL: titleLogURL,
    pid: pid,
    timeoutSeconds: 120
)
Thread.sleep(forTimeInterval: TimeInterval(menuSettleSeconds))

let windowID = gameWindowID(for: pid)
let menuCaptureURL = markersURL
    .deletingLastPathComponent()
    .appendingPathComponent("\(markersURL.lastPathComponent).menu.jpg")
defer {
    try? FileManager.default.removeItem(at: menuCaptureURL)
}
let benchmarkStartBaseline = logLines(
    containing: benchmarkStartedMarker,
    in: titleLogURL
).count
let statisticsStartBaseline = logLines(
    containing: statisticsStartedMarker,
    in: titleLogURL
).count
let benchmarkStopBaseline = logLines(
    containing: benchmarkStoppedMarker,
    in: titleLogURL
).count
prepareMainMenu(
    windowID: windowID,
    imageURL: menuCaptureURL,
    pid: pid
)
navigateToMenuItem(
    "EXTRAS",
    windowID: windowID,
    imageURL: menuCaptureURL,
    pid: pid
)
enterMenu(
    from: "EXTRAS",
    to: "BENCHMARK",
    windowID: windowID,
    imageURL: menuCaptureURL,
    pid: pid
)
navigateToMenuItem(
    "BENCHMARK",
    windowID: windowID,
    imageURL: menuCaptureURL,
    pid: pid
)
let benchmarkStartedLine = startBenchmark(
    windowID: windowID,
    imageURL: menuCaptureURL,
    titleLogURL: titleLogURL,
    pid: pid,
    startMarkerBaseline: benchmarkStartBaseline
)
let statisticsStartedLine = waitForLogMarker(
    statisticsStartedMarker,
    titleLogURL: titleLogURL,
    pid: pid,
    timeoutSeconds: 30,
    afterCount: statisticsStartBaseline
)
let sceneStartTimestampNs = latestPresentTimestamp(in: metricsURL)
writeMarkers(
    BenchmarkMarkers(
        pid: pid,
        benchmarkStartedLine: benchmarkStartedLine,
        statisticsStartedLine: statisticsStartedLine,
        benchmarkStoppedLine: nil,
        sceneStartTimestampNs: sceneStartTimestampNs,
        sceneEndTimestampNs: nil
    ),
    to: markersURL
)

let benchmarkStoppedLine = waitForLogMarker(
    benchmarkStoppedMarker,
    titleLogURL: titleLogURL,
    pid: pid,
    timeoutSeconds: sceneTimeoutSeconds,
    afterCount: benchmarkStopBaseline
)
let sceneEndTimestampNs = latestPresentTimestamp(in: metricsURL)
guard sceneEndTimestampNs > sceneStartTimestampNs else {
    fail("benchmark stop marker did not advance DXMT Present telemetry")
}
writeMarkers(
    BenchmarkMarkers(
        pid: pid,
        benchmarkStartedLine: benchmarkStartedLine,
        statisticsStartedLine: statisticsStartedLine,
        benchmarkStoppedLine: benchmarkStoppedLine,
        sceneStartTimestampNs: sceneStartTimestampNs,
        sceneEndTimestampNs: sceneEndTimestampNs
    ),
    to: markersURL
)

print("benchmark scene complete: \(markersURL.path)")
