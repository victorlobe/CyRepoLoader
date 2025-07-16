//
//  ContentView.swift
//  Cydia Repo Downloader SwiftUI
//
//  Created by Victor on 16.07.25.
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit
import Foundation

struct ContentView: View {
    @State private var repoURL: String = ""
    @State private var destDir: String = ""
    @State private var repoHistory: [String] = []
    @State private var isRunning: Bool = false
    @State private var logOutput: String = ""
    @State private var errorOutput: String = ""
    @State private var showingPicker = false
    @State private var shouldAutoScroll: Bool = true
    @State private var downloadProcess: Process? = nil
    @State private var isPaused: Bool = false
    
    @State private var showOpenFolderButton: Bool = false
    
    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (\(build))"
    }
    
    private var repoFolderURL: URL? {
        let trimmedRepoURL = repoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRepoURL.isEmpty else { return nil }
        let url = URL(string: trimmedRepoURL)
        let expandedDestDir = (destDir as NSString).expandingTildeInPath
        let urlHost = url?.host ?? "repo"
        return URL(fileURLWithPath: expandedDestDir).appendingPathComponent(urlHost, isDirectory: true)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 6) {
                    Text("Cydia Repo Utility")
                        .font(.title2)
                        .bold()
                    Text("by Victor")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                TextField("Cydia Repo URL", text: $repoURL)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    TextField("Download Destination", text: $destDir)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose") {
                        showingPicker = true
                    }
                    .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                        switch result {
                        case .success(let urls):
                            if let url = urls.first {
                                var isDir: ObjCBool = false
                                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                                    // Only update destDir, do not saveDestination here
                                    destDir = url.path
                                    errorOutput = ""
                                    let defaults = UserDefaults.standard
                                    defaults.set(url.path, forKey: "destDir")
                                } else {
                                    errorOutput = "Selected path is not a valid directory."
                                }
                            }
                        case .failure(let error):
                            errorOutput = "Directory selection failed: \(error.localizedDescription)"
                        }
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    var foundValidFolder = false
                    let group = DispatchGroup()
                    var localError: String? = nil

                    for provider in providers {
                        group.enter()
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (item, error) in
                            defer { group.leave() }
                            if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                                var isDir: ObjCBool = false
                                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                                    if isDir.boolValue {
                                        DispatchQueue.main.async {
                                            destDir = url.path
                                            errorOutput = ""
                                            let defaults = UserDefaults.standard
                                            defaults.set(destDir, forKey: "destDir")
                                        }
                                        foundValidFolder = true
                                    } else {
                                        let folderPath = url.deletingLastPathComponent().path
                                        DispatchQueue.main.async {
                                            destDir = folderPath
                                            errorOutput = "Dropped item was a file; using its containing folder instead."
                                            let defaults = UserDefaults.standard
                                            defaults.set(destDir, forKey: "destDir")
                                        }
                                        foundValidFolder = true
                                    }
                                }
                            }
                        }
                        if foundValidFolder { break }
                    }

                    group.notify(queue: .main) {
                        if !foundValidFolder {
                            errorOutput = "No valid folder found in the dropped items."
                        }
                    }

                    return foundValidFolder
                }

                HStack {
                    Button(isRunning ? "Downloading..." : "Start Download") {
                        isPaused = false
                        downloadProcess = nil
                        showOpenFolderButton = false
                        errorOutput = "" // Reset errors when starting a new download
                        logOutput = ""   // Clear log only when starting a new download
                        Task { await mirrorRepo() }
                    }
                    .disabled(isRunning || repoURL.isEmpty || destDir.isEmpty)
                    .buttonStyle(.borderedProminent)

                    if isRunning {
                        Button("Cancel") {
                            cancelDownload()
                        }
                        .buttonStyle(.bordered)

                        if isPaused {
                            Button("Resume") {
                                resumeDownload()
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button("Pause") {
                                pauseDownload()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                if !errorOutput.isEmpty {
                    Text(errorOutput)
                        .foregroundColor(errorOutput.localizedCaseInsensitiveContains("warning") ? .orange : .red)
                        .padding(8)
                        .background(errorOutput.localizedCaseInsensitiveContains("warning") ? Color.orange.opacity(0.15) : Color.red.opacity(0.15))
                        .cornerRadius(6)
                        .padding(.top, 5)
                }

                // Always show logOutput ScrollView, never hide or clear it except when starting new download
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(logOutput)
                            .textSelection(.enabled)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        Color.clear.frame(height: 1).id("logEnd")
                    }
                    .frame(maxHeight: 250)
                    .gesture(
                        DragGesture()
                            .onChanged { _ in
                                shouldAutoScroll = false
                            }
                    )
                    .onChange(of: logOutput) { _ in
                        if shouldAutoScroll {
                            withAnimation {
                                proxy.scrollTo("logEnd", anchor: .bottom)
                            }
                        }
                    }
                }
                
                if !repoHistory.isEmpty {
                    Text("Recent URLs")
                        .font(.headline)
                        .padding(.top, 4)
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(repoHistory, id: \.self) { url in
                                HStack {
                                    Button {
                                        repoURL = url
                                        errorOutput = ""
                                    } label: {
                                        Text(url)
                                            .lineLimit(1)
                                            .padding(6)
                                            .background(Color.gray.opacity(0.2))
                                            .cornerRadius(6)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    Button {
                                        removeHistoryURL(url)
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundColor(.red)
                                            .padding(6)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: 200)
                }
                
                if !isRunning, showOpenFolderButton, let repoFolderURL = repoFolderURL, FileManager.default.fileExists(atPath: repoFolderURL.path) {
                    Text("Download finished. You can open the download folder below.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    Button("Open Folder") {
                        openRepoFolder()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
                }
            }
            .padding()
            .onAppear {
                let defaults = UserDefaults.standard
                destDir = defaults.string(forKey: "destDir") ?? ""
                repoHistory = defaults.stringArray(forKey: "repoHistory") ?? []
            }
            HStack {
                Spacer()
                Text(versionString)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                    .padding(.trailing, 6)
            }
        }
    }

    func saveHistoryURL(_ url: String) {
        var updated = repoHistory.filter { $0 != url }
        updated.insert(url, at: 0)
        if updated.count > 10 {
            updated = Array(updated.prefix(10))
        }
        repoHistory = updated
        let defaults = UserDefaults.standard
        defaults.set(updated, forKey: "repoHistory")
    }

    func removeHistoryURL(_ url: String) {
        var updated = repoHistory.filter { $0 != url }
        repoHistory = updated
        let defaults = UserDefaults.standard
        defaults.set(updated, forKey: "repoHistory")
    }

    func cancelDownload() {
        if let process = downloadProcess, process.isRunning {
            process.terminate()
            Task { await MainActor.run {
                errorOutput = "Download cancelled by user."
                isRunning = false
                downloadProcess = nil
                isPaused = false
                showOpenFolderButton = false
            }}
        }
    }

    func pauseDownload() {
        if let process = downloadProcess, !isPaused, process.isRunning {
            process.suspend()
            Task { await MainActor.run {
                isPaused = true
                logOutput += "Paused.\n"
            }}
        }
    }

    func resumeDownload() {
        if let process = downloadProcess, isPaused {
            process.resume()
            Task { await MainActor.run {
                isPaused = false
                logOutput += "Resumed.\n"
            }}
        }
    }

    func mirrorRepo() async {
        await MainActor.run {
            errorOutput = ""
        }

        await MainActor.run {
            isRunning = true
            logOutput = "" // Clear log only when starting a new download
            shouldAutoScroll = true
            showOpenFolderButton = false
        }

        await MainActor.run { logOutput += "Validating URL...\n" }

        // Validate repoURL
        let trimmedRepoURL = repoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedRepoURL),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https") else {
            await MainActor.run {
                errorOutput = "Invalid URL: Please enter a valid URL starting with http:// or https://"
                isRunning = false
            }
            return
        }

        await MainActor.run { logOutput += "Validating destination directory...\n" }

        // Validate destDir
        let expandedDestDir = (destDir as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedDestDir, isDirectory: &isDir), isDir.boolValue else {
            await MainActor.run {
                errorOutput = "Invalid destination: The download destination must be an existing folder."
                isRunning = false
            }
            return
        }

        await MainActor.run { logOutput += "Locating wget executable...\n" }

        guard let wgetPath = findWgetPath(), FileManager.default.isExecutableFile(atPath: wgetPath) else {
            await MainActor.run {
                errorOutput = "wget not found in your system PATH. Please install wget and make sure it's available in PATH."
                isRunning = false
            }
            return
        }

        await MainActor.run {
            logOutput += "Found wget at \(wgetPath)\n"
            logOutput += "Preparing download...\n"
            saveHistoryURL(trimmedRepoURL)
        }

        let trimmedURL = trimmedRepoURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urlHost = url.host ?? "repo"
        let repoPath = expandedDestDir + "/" + urlHost
        let fileManager = FileManager.default

        await MainActor.run { logOutput += "Creating target directory...\n" }

        do {
            try fileManager.createDirectory(atPath: repoPath, withIntermediateDirectories: true, attributes: nil)
        } catch {
            await MainActor.run {
                errorOutput = "Failed to create destination directory: \(error.localizedDescription)"
                isRunning = false
            }
            return
        }

        // Clean old logs
        let logFile = repoPath + "/wget.log"
        let errorFile = repoPath + "/wget-errors.log"
        do {
            try? fileManager.removeItem(atPath: logFile)
            try? fileManager.removeItem(atPath: errorFile)
        }

        let wgetArgs = [
            "--mirror", "--no-parent", "--convert-links", "--restrict-file-names=windows", "--wait=1",
            "-e", "robots=off", trimmedURL
        ]

        let outPipe = Pipe()

        await MainActor.run { logOutput += "Starting download...\n" }

        // Run wget and streaming output off main thread
        await withCheckedContinuation { continuation in
            Task.detached(priority: .background) {
                let wget = Process()
                wget.launchPath = wgetPath
                wget.arguments = wgetArgs
                wget.currentDirectoryPath = repoPath
                wget.standardOutput = outPipe
                wget.standardError = outPipe

                await MainActor.run {
                    downloadProcess = wget
                    isPaused = false
                    showOpenFolderButton = false
                }

                let fileManager = FileManager.default
                let logHandle: FileHandle
                do {
                    if fileManager.fileExists(atPath: logFile) {
                        guard let handle = FileHandle(forWritingAtPath: logFile) else {
                            await MainActor.run {
                                errorOutput = "Failed to open log file for writing."
                                isRunning = false
                                downloadProcess = nil
                                isPaused = false
                                showOpenFolderButton = false
                            }
                            continuation.resume()
                            return
                        }
                        logHandle = handle
                        logHandle.seekToEndOfFile()
                    } else {
                        fileManager.createFile(atPath: logFile, contents: nil, attributes: [FileAttributeKey.posixPermissions: 0o644])
                        guard let handle = FileHandle(forWritingAtPath: logFile) else {
                            await MainActor.run {
                                errorOutput = "Failed to create log file."
                                isRunning = false
                                downloadProcess = nil
                                isPaused = false
                                showOpenFolderButton = false
                            }
                            continuation.resume()
                            return
                        }
                        logHandle = handle
                    }
                } catch {
                    await MainActor.run {
                        errorOutput = "Error accessing log file: \(error.localizedDescription)"
                        isRunning = false
                        downloadProcess = nil
                        isPaused = false
                        showOpenFolderButton = false
                    }
                    continuation.resume()
                    return
                }

                // Stream log output live
                Task.detached(priority: .background) {
                    do {
                        for try await line in outPipe.fileHandleForReading.bytes.lines {
                            await MainActor.run {
                                logOutput += line + "\n"
                            }
                            if let data = (line + "\n").data(using: .utf8) {
                                try? logHandle.write(contentsOf: data)
                            }
                        }
                    } catch {
                        // Ignored for live streaming errors
                    }
                }

                do {
                    try wget.run()
                    wget.waitUntilExit()
                } catch {
                    await MainActor.run {
                        errorOutput = "Failed to run wget process: \(error.localizedDescription)"
                        isRunning = false
                        downloadProcess = nil
                        isPaused = false
                        showOpenFolderButton = false
                    }
                    logHandle.closeFile()
                    continuation.resume()
                    return
                }

                logHandle.closeFile()

                if wget.terminationStatus != 0 {
                    await MainActor.run {
                        errorOutput = "wget exited with status \(wget.terminationStatus). Please check the logs for details."
                        logOutput += "\n⚠️ Warning: wget exited with non-zero status \(wget.terminationStatus)."
                        isRunning = false
                        downloadProcess = nil
                        isPaused = false
                        showOpenFolderButton = false
                    }
                    continuation.resume()
                    return
                }

                // Grep errors to error log
                do {
                    let logContent = try String(contentsOfFile: logFile)
                    let errorLines = logContent.split(separator: "\n").filter {
                        $0.range(of: "404|fehler|error|not found|unavailable", options: .regularExpression) != nil
                    }
                    if !errorLines.isEmpty {
                        try errorLines.joined(separator: "\n").write(toFile: errorFile, atomically: true, encoding: .utf8)
                        await MainActor.run {
                            errorOutput = "Download completed with errors. See below:\n" + errorLines.joined(separator: "\n")
                        }
                    } else {
                        try? fileManager.removeItem(atPath: errorFile)
                        await MainActor.run {
                            errorOutput = ""
                            logOutput += "\n✅ Download completed successfully with no errors."
                        }
                    }
                } catch {
                    await MainActor.run {
                        errorOutput = "Error processing wget log files: \(error.localizedDescription)"
                    }
                    continuation.resume()
                    return
                }

                await MainActor.run {
                    logOutput += "\nAll done. Your local mirror is at: \(repoPath)\n"
                    logOutput += "Download complete.\n"
                    isRunning = false
                    downloadProcess = nil
                    isPaused = false
                    // Show Open Folder button whenever the folder exists, even if errors occurred
                    showOpenFolderButton = (repoFolderURL != nil && FileManager.default.fileExists(atPath: repoFolderURL!.path))
                }
                continuation.resume()
            }
        }
    }
    
    func findWgetPath() -> String? {
        // 1. Try /usr/bin/env which wget
        let process = Process()
        let pipe = Pipe()
        process.launchPath = "/usr/bin/env"
        process.arguments = ["which", "wget"]
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            // Ignore and try fallback locations
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty, FileManager.default.isExecutableFile(atPath: output) {
            return output
        }
        // 2. Check common install locations
        let fallbackPaths = [
            "/opt/homebrew/bin/wget",
            "/usr/local/bin/wget",
            "/usr/bin/wget"
        ]
        for path in fallbackPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
    
    func openRepoFolder() {
        guard let url = repoFolderURL else { return }
        NSWorkspace.shared.open(url)
    }
}

#Preview {
    ContentView()
}

