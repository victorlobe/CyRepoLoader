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
import SWCompression

struct ContentView: View {
    @State private var repoURL: String = ""
    @State private var destDir: String = ""
    @State private var repoHistory: [String] = []
    @State private var isRunning: Bool = false
    @State private var logOutput: String = ""
    @State private var errorOutput: String = ""
    
    // MARK: - Performance optimization for large repos
    @State private var logStorage = DownloadLogStorage()
    @State private var maxLogLines: Int = 500 // Reduced limit for better performance with very large repos
    @State private var isLogTruncated: Bool = false
    @State private var isLogFlushScheduled: Bool = false
    @State private var showingPicker = false
    @State private var shouldAutoScroll: Bool = true
    @State private var isAtBottom: Bool = true
    @State private var downloadTask: URLSessionDownloadTask? = nil
    @State private var isPaused: Bool = false

    @State private var mirrorTask: Task<Void, Never>? = nil
    
    @State private var showOpenFolderButton: Bool = false

    @State private var selectedScheme: String = "https"
    private let selectedSchemeKey = "selectedScheme"
    
    @State private var downloadSummary: String? = nil
    
    // MARK: - Added state variables for simple log mode and progress tracking
    @State private var simpleLogMode: Bool = true
    @State private var progress: Double = 0
    @State private var filesTotal: Int = 0
    @State private var filesDownloaded: Int = 0
    
    // MARK: - New state variable for progress phase display in simple log mode
    @State private var progressPhase: String = ""
    
    // MARK: - New state variables for recursive mirror progress
    @State private var recursiveFilesTotal: Int = 0
    @State private var recursiveFilesDownloaded: Int = 0
    
    // MARK: - Control for recursive mirror phase
    @State private var skipRecursiveMirror: Bool = false
    
    // *** New state variable for last download folder URL ***
    @State private var lastDownloadFolderURL: URL? = nil

    // New state variable for Victor photo sheet presentation
    @State private var showVictorPhotoSheet = false

    // *** Added new state to track forbidden (paid/unauthorized) deb URLs ***
    @State private var forbiddenDebs: [String] = [] // Tracks forbidden (paid) deb URLs
    
    private var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(version) (\(build))"
    }
    
    private var repoFolderURL: URL? {
        let trimmedRepoURL = repoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRepoURL.isEmpty else { return nil }
        let url = URL(string: trimmedRepoURL.hasPrefix("http") ? trimmedRepoURL : (selectedScheme.isEmpty ? "" : selectedScheme + "://") + trimmedRepoURL)
        let expandedDestDir = (destDir as NSString).expandingTildeInPath
        guard let url else { return nil }
        // Build a unique folder name for host + subpath (e.g., cydia.invoxiplaygames.uk_beta)
        let host = url.host ?? "repo"
        var pathComponent = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !pathComponent.isEmpty {
            // Replace / with _ to avoid subfoldering and illegal characters
            pathComponent = pathComponent.replacingOccurrences(of: "/", with: "_")
            return URL(fileURLWithPath: expandedDestDir).appendingPathComponent("\(host)_\(pathComponent)", isDirectory: true)
        } else {
            return URL(fileURLWithPath: expandedDestDir).appendingPathComponent(host, isDirectory: true)
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 6) {
                    Text("CyRepoLoader")
                        .font(.title2)
                        .bold()
                    Button {
                        showVictorPhotoSheet = true
                    } label: {
                        Text("by Victor")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                HStack {
                    Picker("", selection: $selectedScheme) {
                        Text("http://").tag("http")
                        Text("https://").tag("https")
                        Text("Custom").tag("")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 90)
                    .disabled(isRunning)
                    .onChange(of: selectedScheme) { _ in
                        repoURL = repoURL.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
                        UserDefaults.standard.set(selectedScheme, forKey: selectedSchemeKey)
                    }
                    TextField("Cydia Repo URL", text: $repoURL)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isRunning)
                        .onChange(of: repoURL) { newValue in
                            let cleaned = newValue.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
                            if repoURL != cleaned { repoURL = cleaned }
                        }
                        .onSubmit {
                            if !isRunning && !repoURL.isEmpty && !destDir.isEmpty {
                                isPaused = false
                                downloadTask = nil
                                showOpenFolderButton = false
                                errorOutput = ""
                                downloadSummary = nil
                                logOutput = ""
                                logStorage.reset()
                                forbiddenDebs = [] // Reset forbidden debs at start
                                isLogFlushScheduled = false
                                mirrorTask = Task { await mirrorRepo() }
                            }
                        }
                }

                HStack {
                    TextField("Download Destination", text: $destDir)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isRunning)
                    Button("Choose") {
                        showingPicker = true
                    }
                    .disabled(isRunning)
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
                    Toggle("Full Log", isOn: .init(get: { !simpleLogMode }, set: { simpleLogMode = !$0 }))
                        .padding(.leading, 8)
                    Toggle("Skip Additional Files", isOn: $skipRecursiveMirror)
                        .padding(.leading, 8)
                        .disabled(isRunning)
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    var foundValidFolder = false
                    let group = DispatchGroup()

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
                        downloadTask = nil
                        showOpenFolderButton = false
                        errorOutput = "" // Reset errors when starting a new download
                        downloadSummary = nil
                        logOutput = ""   // Clear log only when starting a new download
                        logStorage.reset()
                        forbiddenDebs = [] // Reset forbidden debs at start
                        isLogFlushScheduled = false
                        mirrorTask = Task { await mirrorRepo() }
                    }
                    .disabled(isRunning || repoURL.isEmpty || destDir.isEmpty)
                    .buttonStyle(.borderedProminent)

                    if isRunning {
                        Button("Cancel") {
                            cancelDownload()
                        }
                        .buttonStyle(.bordered)
                    }
                    // Show "Show in Finder" whenever we have a valid lastDownloadFolderURL (also during download)
                    if let downloadURL = lastDownloadFolderURL {
                        Button {
                            NSWorkspace.shared.open(downloadURL)
                        } label: {
                            Label("Show in Finder", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                
                // MARK: - Removed old Toggle here
                
                // MARK: - Conditionally show simple progress bar or full log output ScrollView
                if simpleLogMode {
                    DownloadStatusPanel(
                        phase: progressPhase,
                        isRunning: isRunning,
                        progress: progress,
                        filesDownloaded: filesDownloaded,
                        filesTotal: filesTotal,
                        recursiveFilesDownloaded: recursiveFilesDownloaded,
                        recursiveFilesTotal: recursiveFilesTotal,
                        errorMessage: errorOutput,
                        summary: downloadSummary
                    )
                } else {
                    // Always show logOutput ScrollView, never hide or clear it except when starting new download
                    ScrollViewReader { proxy in
                        ZStack(alignment: .bottomTrailing) {
                            GeometryReader { geometry in
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 0) {
                                        LazyVStack(alignment: .leading, spacing: 0) {
                                            if isLogTruncated {
                                                Text("⚠️ Log truncated to prevent UI lag. Showing last \(maxLogLines) entries.")
                                                    .font(.caption)
                                                    .foregroundColor(.orange)
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 4)
                                            }
                                            Text(logOutput)
                                                .textSelection(.enabled)
                                                .font(.system(.footnote, design: .monospaced))
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(8)
                                        }
                                        Color.clear.frame(height: 1).id("logEnd")
                                    }
                                    // Background GeometryReader for total content height to track lastLogHeight
                                    .background(GeometryReader { innerGeo in
                                        Color.clear.preference(key: LogScrollBottomKey.self, value: innerGeo.frame(in: .global).maxY)
                                    })
                                }
                                .frame(maxHeight: 250)
                                .gesture(
                                    DragGesture().onChanged { _ in
                                        // User started dragging (scrolling), disable auto-scroll
                                        shouldAutoScroll = false
                                    }
                                )
                                // Update isAtBottom and shouldAutoScroll based on scroll position
                                .onPreferenceChange(LogScrollBottomKey.self) { value in
                                    let scrollViewFrameMaxY = geometry.frame(in: .global).maxY
                                    // If content bottom (value) is less or equal to scrollView bottom + threshold, consider at bottom
                                    if value <= scrollViewFrameMaxY + 10.0 {
                                        isAtBottom = true
                                        shouldAutoScroll = true
                                    } else {
                                        isAtBottom = false
                                        shouldAutoScroll = false
                                    }
                                }
                                .onAppear {
                                    // On appear, assume at bottom and enable auto-scroll
                                    isAtBottom = true
                                    shouldAutoScroll = true
                                }
                                // Only auto-scroll when user has not manually scrolled up
                                .onChange(of: logOutput) { _ in
                                    if shouldAutoScroll {
                                        withAnimation {
                                            proxy.scrollTo("logEnd", anchor: .bottom)
                                        }
                                    }
                                }
                            }
                            if !isAtBottom {
                                Button(action: {
                                    withAnimation {
                                        proxy.scrollTo("logEnd", anchor: .bottom)
                                    }
                                    // User pressed "scroll to bottom" button, enable auto-scroll
                                    shouldAutoScroll = true
                                    isAtBottom = true
                                }) {
                                    Image(systemName: "arrow.down.to.line")
                                        .padding(8)
                                        .background(Color.gray.opacity(0.7))
                                        .clipShape(Circle())
                                        .foregroundColor(.white)
                                        .shadow(radius: 3)
                                }
                                .padding([.trailing, .bottom], 12)
                            }
                        }
                    }
                }
                
                if !isRunning && !errorOutput.isEmpty {
                    Text(errorOutput)
                        .foregroundColor(errorOutput.localizedCaseInsensitiveContains("warning") ? .orange : .red)
                        .padding(8)
                        .background(errorOutput.localizedCaseInsensitiveContains("warning") ? Color.orange.opacity(0.15) : Color.red.opacity(0.15))
                        .cornerRadius(6)
                        .padding(.top, 5)
                }

                if !isRunning, let downloadSummary, !downloadSummary.isEmpty {
                    ScrollView {
                        Text(downloadSummary)
                            .textSelection(.enabled)
                            .font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 120)
                    .background(Color.orange.opacity(0.12))
                    .cornerRadius(6)
                }
                
                Spacer()
                
                if !repoHistory.isEmpty {
                    Text("History")
                        .font(.headline)
                        .padding(.top, 4)
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(repoHistory, id: \.self) { url in
                                HStack {
                                    Button {
                                        if url.hasPrefix("http://") {
                                            selectedScheme = "http"
                                            repoURL = String(url.dropFirst("http://".count))
                                        } else if url.hasPrefix("https://") {
                                            selectedScheme = "https"
                                            repoURL = String(url.dropFirst("https://".count))
                                        } else {
                                            selectedScheme = ""
                                            repoURL = url
                                        }
                                        repoURL = repoURL.replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
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
            }
            .padding()
            .onAppear {
                let defaults = UserDefaults.standard
                destDir = defaults.string(forKey: "destDir") ?? ""
                repoHistory = defaults.stringArray(forKey: "repoHistory") ?? []
                if let savedScheme = UserDefaults.standard.string(forKey: selectedSchemeKey), !savedScheme.isEmpty {
                    selectedScheme = savedScheme
                }
                // Initialize logOutput based on current simpleLogMode and retained log entries
                if simpleLogMode {
                    // In simple mode, logOutput is empty or summary only
                    logOutput = ""
                } else {
                    flushLogOutput()
                }
            }
            .onChange(of: simpleLogMode) { newValue in
                // When toggling simpleLogMode, update logOutput accordingly
                if newValue {
                    // simpleLogMode is true: show minimal or empty log output
                    logOutput = ""
                } else {
                    // simpleLogMode is false: show full log output
                    flushLogOutput()
                }
            }
            .sheet(isPresented: $showVictorPhotoSheet) {
                VictorPhotoSheet()
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
        let updated = repoHistory.filter { $0 != url }
        repoHistory = updated
        let defaults = UserDefaults.standard
        defaults.set(updated, forKey: "repoHistory")
    }

    func cancelDownload() {
        mirrorTask?.cancel()
        mirrorTask = nil
        Task { await MainActor.run {
            errorOutput = "Download cancelled by user."
            downloadSummary = nil
            isRunning = false
            downloadTask = nil
            isPaused = false
            showOpenFolderButton = false
            progress = 0
            filesDownloaded = 0
            filesTotal = 0
            recursiveFilesDownloaded = 0
            recursiveFilesTotal = 0
            // MARK: - Set progressPhase to "Download cancelled" on cancel
            progressPhase = "Download cancelled"
        }}
    }

    func pauseDownload() {
        // Pause/resume disabled for now
    }

    func resumeDownload() {
        // Pause/resume disabled for now
    }

    // MARK: - New mirrorRepo implementation with simpleLogMode progress tracking
    
    func mirrorRepo() async {
        // MARK: - Reset progressPhase at start
        await MainActor.run {
            progressPhase = ""
        }
        
        await MainActor.run {
            errorOutput = ""
            downloadSummary = nil
            forbiddenDebs = [] // Reset forbidden debs at start
            logStorage.reset()
            isLogTruncated = false
            isLogFlushScheduled = false
        }
        
        // Log start of session with selected repo and destination
        await updateLogAsync("🚀 Starting download session.\n")
        await updateLogAsync("📦 Repo URL (selected scheme + repoURL): \(selectedScheme.isEmpty ? "" : selectedScheme + "://")\(repoURL.trimmingCharacters(in: .whitespacesAndNewlines))\n")
        await updateLogAsync("📁 Download destination directory: \(destDir)\n")

        await MainActor.run {
            isRunning = true
            logOutput = ""
            shouldAutoScroll = true
            showOpenFolderButton = false
            // Reset progress-related state at start
            progress = 0
            filesDownloaded = 0
            filesTotal = 0
            recursiveFilesDownloaded = 0
            recursiveFilesTotal = 0
            // MARK: - Set progressPhase at initial validation phase
            progressPhase = "Validating URL and destination"
        }
        let shouldSkipRecursiveMirror = skipRecursiveMirror

        // Compose final URL string with selected scheme
        let cleanRepoURL = repoURL.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
        let finalURLString = (selectedScheme.isEmpty ? "" : selectedScheme + "://") + cleanRepoURL

        // Validate finalURLString
        let trimmedFinalURL = finalURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        await MainActor.run {
            appendLogMessage("🔍 Validating URL: \(trimmedFinalURL)\n")
        }
        guard let baseURL = URL(string: trimmedFinalURL) else {
            await MainActor.run {
                appendLogMessage("❌ Invalid URL format.\n")
                errorOutput = "Invalid URL: Please enter a valid URL starting with http:// or https://"
                downloadSummary = nil
                isRunning = false
                mirrorTask = nil
                progress = 0
                filesDownloaded = 0
                filesTotal = 0
                // MARK: - Set progressPhase to error
                progressPhase = "Error"
            }
            return
        }
        guard let scheme = baseURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            await MainActor.run {
                appendLogMessage("❌ Invalid URL scheme: \(baseURL.scheme ?? "none")\n")
                errorOutput = "Invalid URL scheme: Use http:// or https://"
                downloadSummary = nil
                isRunning = false
                mirrorTask = nil
                progress = 0
                filesDownloaded = 0
                filesTotal = 0
                // MARK: - Set progressPhase to error
                progressPhase = "Error"
            }
            return
        }
        await MainActor.run {
            appendLogMessage("✅ URL scheme is valid: \(scheme)\n")
        }

        // Validate destDir
        let expandedDestDir = (destDir as NSString).expandingTildeInPath
        await MainActor.run {
            appendLogMessage("📂 Validating destination directory: \(expandedDestDir)\n")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedDestDir, isDirectory: &isDir), isDir.boolValue else {
            await MainActor.run {
                appendLogMessage("❌ Invalid destination directory: does not exist or not a directory.\n")
                errorOutput = "Invalid destination: The download destination must be an existing folder."
                downloadSummary = nil
                isRunning = false
                mirrorTask = nil
                progress = 0
                filesDownloaded = 0
                filesTotal = 0
                // MARK: - Set progressPhase to error
                progressPhase = "Error"
            }
            return
        }
        await MainActor.run {
            appendLogMessage("✅ Destination directory is valid.\n")
        }

        // Create repo folder path with host + subpath logic
        let host = baseURL.host ?? "repo"
        var pathComponent = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let repoPath: URL
        if !pathComponent.isEmpty {
            pathComponent = pathComponent.replacingOccurrences(of: "/", with: "_")
            repoPath = URL(fileURLWithPath: expandedDestDir).appendingPathComponent("\(host)_\(pathComponent)", isDirectory: true)
        } else {
            repoPath = URL(fileURLWithPath: expandedDestDir).appendingPathComponent(host, isDirectory: true)
        }

        do {
            try FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true, attributes: nil)
            await MainActor.run {
                appendLogMessage("📁 Created repo directory at \(repoPath.path)\n")
                // Make "Show in Finder" available right after directory creation
                lastDownloadFolderURL = repoPath
                showOpenFolderButton = true
            }
        } catch {
            await MainActor.run {
                appendLogMessage("❌ Failed to create repo directory: \(error.localizedDescription)\n")
                errorOutput = "Failed to create destination directory: \(error.localizedDescription)"
                downloadSummary = nil
                isRunning = false
                mirrorTask = nil
                progress = 0
                filesDownloaded = 0
                filesTotal = 0
                // MARK: - Set progressPhase to error
                progressPhase = "Error"
            }
            return
        }

        // MARK: - Set progressPhase when searching metadata files
        await MainActor.run {
            appendLogMessage("🔍 Checking repo metadata files...\n")
            progressPhase = "Searching repo metadata files..."
        }

        let fileManager = FileManager.default

        // Define possible metadata file names to try
        let metadataFiles = [
            "Release",
            "Packages",
            "Packages.bz2",
            "Packages.gz"
        ]
        // Common hardcoded fallback sub-paths to try if root not found or suite/codename missing
        // Removed leading slashes to be relative subpaths under user-supplied baseURL
        let fallbackSubpaths = [
            "./",
            "dists/stable/main/binary-iphoneos-arm/"
        ]

        var repoBaseURL = baseURL
        var foundMetadataURL: URL? = nil
        var metadataData: Data? = nil
        var metadataFileName: String? = nil

        // Helper function to try fetch metadata file at given base URL and filename,
        // trying both base URL with and without trailing slash for robustness
        func tryMetadataFile(base: URL, filename: String) async -> Data? {
            // Prepare candidate URLs (with and without trailing slash)
            var candidateURLs: [URL] = []
            if base.absoluteString.hasSuffix("/") {
                candidateURLs.append(base.appendingPathComponent(filename))
            } else {
                candidateURLs.append(base.appendingPathComponent(filename))
                if let urlWithSlash = URL(string: base.absoluteString + "/") {
                    candidateURLs.append(urlWithSlash.appendingPathComponent(filename))
                }
            }
            for url in candidateURLs {
                do {
                    await MainActor.run {
                        appendLogMessage("🔍 Trying \(url.absoluteString)...\n")
                    }
                    let data = try await fetchURL(url)
                    await MainActor.run {
                        appendLogMessage("✅ Found \(filename) at \(url.absoluteString)\n")
                    }
                    return data
                } catch {
                    await MainActor.run {
                        appendLogMessage("⚠️ Not found or error fetching \(filename) at \(url.absoluteString): \(error.localizedDescription)\n")
                    }
                }
            }
            return nil
        }

        // Always search for metadata files at the user-supplied baseURL (including any subpath) first.
        outerLoop: for filename in metadataFiles {
            if let data = await tryMetadataFile(base: baseURL, filename: filename) {
                foundMetadataURL = baseURL.appendingPathComponent(filename)
                metadataData = data
                metadataFileName = filename
                break outerLoop
            }
        }

        // Always try the classic subpath for Cydia repos (BigBoss etc), even if no Release file exists
        if foundMetadataURL == nil {
            let classicSubpath = "dists/stable/main/binary-iphoneos-arm/"
            if let classicURL = URL(string: classicSubpath, relativeTo: baseURL)?.absoluteURL {
                for filename in ["Packages", "Packages.gz", "Packages.bz2"] {
                    if let data = await tryMetadataFile(base: classicURL, filename: filename) {
                        foundMetadataURL = classicURL.appendingPathComponent(filename)
                        metadataData = data
                        metadataFileName = filename
                        repoBaseURL = classicURL
                        break
                    }
                }
            }
        }

        // Expliziter BigBoss-Debian-Standardpfad-Test: try dists/stable/main/binary-iphoneos-arm/Packages.bz2 explicitly
        let debianPackagesBZ2 = "dists/stable/main/binary-iphoneos-arm/Packages.bz2"
        if foundMetadataURL == nil {
            if let debianURL = URL(string: debianPackagesBZ2, relativeTo: baseURL)?.absoluteURL {
                if let data = await tryMetadataFile(base: debianURL.deletingLastPathComponent(), filename: "Packages.bz2") {
                    foundMetadataURL = debianURL
                    metadataData = data
                    metadataFileName = "Packages.bz2"
                    repoBaseURL = debianURL.deletingLastPathComponent()
                }
            }
        }

        // If Release file found at root, parse its Suite, Codename, Components fields to build subpaths
        var suite: String? = nil
        var codename: String? = nil
        var components: [String] = []

        if metadataFileName == "Release", let metadata = metadataData {
            // Parse Release file content (key: value)
            if let content = String(data: metadata, encoding: .utf8) {
                func parseField(_ key: String) -> String? {
                    let pattern = "^\(key):\\s*(.*)$"
                    if let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) {
                        let nsContent = content as NSString
                        if let match = regex.firstMatch(in: content, options: [], range: NSRange(location: 0, length: nsContent.length)) {
                            let range = match.range(at: 1)
                            if range.location != NSNotFound {
                                return nsContent.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                    }
                    return nil
                }
                suite = parseField("Suite")
                codename = parseField("Codename")
                if let comps = parseField("Components") {
                    components = comps.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                }
            }
        }

        // Construct subpaths to try for Packages files based on suite/codename/components
        var constructedSubpaths: [String] = []

        // Helper to append subpaths for a given release name (suite or codename)
        func addSubpaths(forRelease release: String) {
            for comp in components.isEmpty ? ["main"] : components {
                let subpath = "dists/\(release)/\(comp)/binary-iphoneos-arm/"
                constructedSubpaths.append(subpath)
            }
        }

        if suite != nil || codename != nil {
            await MainActor.run {
                appendLogMessage("Parsed Release file fields: Suite=\(suite ?? "nil"), Codename=\(codename ?? "nil"), Components=\(components.isEmpty ? "main" : components.joined(separator: ", "))\n")
            }
        }

        if let suite = suite, !suite.isEmpty {
            addSubpaths(forRelease: suite)
        }
        if let codename = codename, !codename.isEmpty, codename != suite {
            addSubpaths(forRelease: codename)
        }
        // If no suite/codename or no components, fallback to existing hardcoded fallbacks
        if constructedSubpaths.isEmpty {
            constructedSubpaths.append(contentsOf: fallbackSubpaths)
        }

        // If we didn't find a Release file at root or need to try Packages files in those subpaths:
        if metadataFileName != "Release" {
            // If no Release found, also try constructed subpaths if any (e.g. suite/codename paths)
            if !constructedSubpaths.isEmpty {
                await MainActor.run {
                    appendLogMessage("No Release file found at root; trying constructed subpaths for Packages files.\n")
                }
            }
        }

        // Now try Packages files in constructed subpaths in priority order
        if metadataFileName == "Release" || metadataFileName == nil {
            var foundInSubpath = false
            subpathLoop: for subpath in constructedSubpaths {
                guard let subURL = URL(string: subpath, relativeTo: baseURL)?.absoluteURL else { continue }
                for filename in ["Packages", "Packages.gz", "Packages.bz2"] {
                    if let data = await tryMetadataFile(base: subURL, filename: filename) {
                        foundMetadataURL = subURL.appendingPathComponent(filename)
                        metadataData = data
                        metadataFileName = filename
                        repoBaseURL = subURL
                        foundInSubpath = true
                        break subpathLoop
                    }
                }
            }
            if !foundInSubpath, metadataFileName == "Release" {
                // Fallbacks are always children of the user-supplied baseURL, never host root.
                fallbackLoop: for fallbackSubpath in fallbackSubpaths {
                    guard let fallbackURL = URL(string: fallbackSubpath, relativeTo: baseURL)?.absoluteURL else { continue }
                    for filename in ["Packages", "Packages.gz", "Packages.bz2"] {
                        if let data = await tryMetadataFile(base: fallbackURL, filename: filename) {
                            foundMetadataURL = fallbackURL.appendingPathComponent(filename)
                            metadataData = data
                            metadataFileName = filename
                            repoBaseURL = fallbackURL
                            break fallbackLoop
                        }
                    }
                }
            }
        }

        guard foundMetadataURL != nil, let metadata = metadataData, let metadataName = metadataFileName else {
            await MainActor.run {
                appendLogMessage("❌ Failed to locate repo metadata files (Release, Packages, Packages.bz2, or Packages.gz).\n")
                errorOutput = "Failed to locate repo metadata files (Release, Packages, Packages.bz2, or Packages.gz)."
                downloadSummary = nil
                isRunning = false
                mirrorTask = nil
                progress = 0
                filesDownloaded = 0
                filesTotal = 0
                // MARK: - Set progressPhase to error
                progressPhase = "Error"
            }
            return
        }

        // MARK: - Set progressPhase when parsing Packages file
        if metadataName == "Packages" {
            await MainActor.run {
                appendLogMessage("📦 Parsing Packages file...\n")
                progressPhase = "Parsing Packages file..."
            }
        } else if metadataName == "Packages.gz" {
            await MainActor.run {
                appendLogMessage("📦 Parsing Packages.gz file...\n")
                appendLogMessage("📊 Packages.gz size: \(metadata.count) bytes\n")
                progressPhase = "Parsing Packages.gz file..."
            }
        } else if metadataName == "Packages.bz2" {
            await MainActor.run {
                appendLogMessage("📦 Parsing Packages.bz2 file...\n")
                appendLogMessage("📊 Packages.bz2 size: \(metadata.count) bytes\n")
                progressPhase = "Parsing Packages.bz2 file..."
            }
        }

        // Parse Packages or compressed Packages files for .deb relative paths if applicable
        var debRelativePaths: [String] = []
        if metadataName == "Packages" {
            debRelativePaths = await parsePackagesFile(metadata)
            if debRelativePaths.isEmpty {
                await MainActor.run {
                    appendLogMessage("No .deb file URLs found in Packages file.\n")
                    errorOutput = "No .deb file URLs found in Packages file."
                    downloadSummary = nil
                    isRunning = false
                    mirrorTask = nil
                    progress = 0
                    filesDownloaded = 0
                    filesTotal = 0
                    // MARK: - Set progressPhase to error
                    progressPhase = "Error"
                }
                return
            }
        } else if metadataName == "Packages.gz" {
            do {
                let packagesData = try decompressGzip(data: metadata)
                await MainActor.run {
                    appendLogMessage("✅ Successfully decompressed Packages.gz, size after decompression: \(packagesData.count) bytes\n")
                }
                debRelativePaths = await parsePackagesFile(packagesData)
                if debRelativePaths.isEmpty {
                    await MainActor.run {
                        appendLogMessage("❌ No .deb file URLs found in Packages.gz file after decompression.\n")
                        errorOutput = "No .deb file URLs found in Packages.gz file."
                        downloadSummary = nil
                        isRunning = false
                        mirrorTask = nil
                        progress = 0
                        filesDownloaded = 0
                        filesTotal = 0
                        // MARK: - Set progressPhase to error
                        progressPhase = "Error"
                    }
                    return
                }
            } catch {
                await MainActor.run {
                    appendLogMessage("❌ Failed to decompress Packages.gz: \(error.localizedDescription)\n")
                    errorOutput = "Failed to parse Packages.gz file: \(error.localizedDescription)"
                    downloadSummary = nil
                    isRunning = false
                    mirrorTask = nil
                    progress = 0
                    filesDownloaded = 0
                    filesTotal = 0
                    // MARK: - Set progressPhase to error
                    progressPhase = "Error"
                }
                return
            }
        } else if metadataName == "Packages.bz2" {
            do {
                let packagesData = try decompressBz2(data: metadata)
                await MainActor.run {
                    appendLogMessage("✅ Packages.bz2 decompressed, size: \(packagesData.count) Bytes\n")
                }
                if let content = String(data: packagesData, encoding: .utf8) {
                    await updateLogAsync("--- Packages.bz2 Preview (UTF-8, first 1000 chars):\n\(content.prefix(1000))\n------------------------------\n")
                } else if let content = String(data: packagesData, encoding: .isoLatin1) {
                    await updateLogAsync("--- Packages.bz2 Preview (Latin1, first 1000 chars):\n\(content.prefix(1000))\n------------------------------\n")
                } else {
                    await updateLogAsync("❌ Could not decode Packages.bz2 as UTF-8 or Latin1.\n")
                }
                debRelativePaths = await parsePackagesFile(packagesData)
                if debRelativePaths.isEmpty {
                    await MainActor.run {
                        appendLogMessage("❌ No .deb file URLs found in Packages.bz2 file after decompression.\n")
                        errorOutput = "No .deb file URLs found in Packages.bz2 file."
                        downloadSummary = nil
                        isRunning = false
                        mirrorTask = nil
                        progress = 0
                        filesDownloaded = 0
                        filesTotal = 0
                        // MARK: - Set progressPhase to error
                        progressPhase = "Error"
                    }
                    return
                }
            } catch {
                await MainActor.run {
                    appendLogMessage("❌ BZ2 decompression failed or not supported: \(error.localizedDescription)\n")
                    errorOutput = "BZ2 decompression not supported yet. Cannot parse Packages.bz2."
                    downloadSummary = nil
                    isRunning = false
                    mirrorTask = nil
                    progress = 0
                    filesDownloaded = 0
                    filesTotal = 0
                    // MARK: - Set progressPhase to error
                    progressPhase = "Error"
                }
                return
            }
        } else if metadataName == "Release" {
            // Release file found, but no Packages file; fallback to recursive mirror
            await MainActor.run {
                appendLogMessage("📋 Release file found, but no Packages file; starting recursive mirror...\n")
            }
            let visitTracker = URLVisitTracker()
            await recursiveMirrorRepo(from: repoBaseURL, to: repoPath, isTopLevel: true, visitTracker: visitTracker, rootHost: repoBaseURL.host)
            return
        }

        // MARK: - Set progressPhase when preparing download list
        await MainActor.run {
            appendLogMessage("Preparing download list with \(debRelativePaths.count) entries from \(metadataName)...\n")
            progressPhase = "Preparing download list..."
        }

        // Now join each relative path with repoBaseURL safely to form absolute URLs to download
        var debURLs: [URL] = []
        for relativePath in debRelativePaths {
            if let url = RepoURLResolver.packageURL(for: relativePath, repoBaseURL: repoBaseURL, originalBaseURL: baseURL) {
                debURLs.append(url)
            } else {
                await updateLogAsync("⚠️ Could not resolve package path: \(relativePath)\n")
            }
        }
        // Damit werden für BigBoss und ähnlich strukturierte Repos die .deb-Downloads korrekt erzeugt.

        // MARK: - Setup progress tracking before download loop and update phase
        await MainActor.run {
            appendLogMessage("🚀 Starting download of \(debURLs.count) .deb files...\n")
            filesTotal = debURLs.count
            filesDownloaded = 0
            progress = 0
            // MARK: - Update progressPhase for downloading
            progressPhase = "Downloading .deb files..."
        }

        if let message = await validatePackageURLsBeforeDownload(debURLs) {
            await MainActor.run {
                appendLogMessage("❌ \(message)\n")
                errorOutput = message
                downloadSummary = message
                isRunning = false
                mirrorTask = nil
                progressPhase = "Error"
            }
            writeLogFile(to: repoPath, log: await MainActor.run { logStorage.fullOutput })
            return
        }

        // Save to history
        await MainActor.run {
            saveHistoryURL(trimmedFinalURL)
        }

        let issueCollector = MirrorIssueCollector()
        forbiddenDebs = [] // Reset forbiddenDebs here again in case

        // Download .deb files in controlled batches for stability
        let batchSize = 2 // Reduced batch size for better stability
        let totalFiles = debURLs.count
        
        for batchStart in stride(from: 0, to: totalFiles, by: batchSize) {
            if Task.isCancelled || !isRunning {
                break
            }
            
            let batchEnd = min(batchStart + batchSize, totalFiles)
            let currentBatch = Array(debURLs[batchStart..<batchEnd])
            
            // Process current batch in parallel
            await withTaskGroup(of: Void.self) { group in
                for (batchIndex, debURL) in currentBatch.enumerated() {
                    let actualIndex = batchStart + batchIndex
                    group.addTask {
                        await downloadDebFile(at: actualIndex, url: debURL, totalCount: totalFiles, repoPath: repoPath, issueCollector: issueCollector)
                    }
                }
                await group.waitForAll()
            }
            
            // Longer delay between batches to prevent overwhelming the system
            if batchEnd < totalFiles {
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second delay between batches
            }
        }

        let issueSnapshot = await issueCollector.snapshot()
        let downloadIssues = issueSnapshot.failed
        await MainActor.run {
            forbiddenDebs = issueSnapshot.restricted
        }

        // Additional step: Mirror anything else in the repo
        // Recursively mirror all remaining files (icons, banners, html, etc.) for full repo hosting
        if !shouldSkipRecursiveMirror {
            await MainActor.run {
                appendLogMessage("🔄 Starting recursive mirror of remaining repo files...\n")
                progressPhase = "Downloading additional repo files..."
            }
            let visitTracker = URLVisitTracker()
            
            // Run recursive mirror in a separate task to prevent UI hanging
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await recursiveMirrorRepo(from: baseURL, to: repoPath, isTopLevel: true, visitTracker: visitTracker, rootHost: baseURL.host)
                }
                
                // Wait for completion or cancellation
                await group.waitForAll()
            }
        } else {
            await MainActor.run {
                appendLogMessage("⏭️ Skipping recursive mirror phase (user preference).\n")
            }
        }

        if Task.isCancelled {
            await updateLogAsync("\n🛑 Download cancelled by user.\n")
            await MainActor.run {
                downloadSummary = nil
                // MARK: - Set progressPhase on cancel
                progressPhase = "Download cancelled"
            }
        } else {
            await updateLogAsync("\n🎉 All done. Your local mirror is at: \(repoPath.path)\n")
            await updateLogAsync("✅ Download complete.\n")
            await MainActor.run {
                // Clear previous errors on success
                errorOutput = ""
                // MARK: - Compose download summary including forbidden debs
                var summaryParts: [String] = []
                if !forbiddenDebs.isEmpty {
                    summaryParts.append("The following packages could not be downloaded because they are restricted (possibly paid or unauthorized):\n" + forbiddenDebs.joined(separator: "\n"))
                }
                if !downloadIssues.isEmpty {
                    summaryParts.append("Failed to download \(downloadIssues.count) other file(s):\n" + downloadIssues.joined(separator: "\n"))
                }
                if summaryParts.isEmpty {
                    // No errors or forbidden files
                    // Removed assignment of downloadSummary = "Success"
                    // downloadSummary = "Success"
                } else {
                    downloadSummary = summaryParts.joined(separator: "\n\n")
                }
                // *** Updated to set lastDownloadFolderURL and showOpenFolderButton ***
                if fileManager.fileExists(atPath: repoPath.path) {
                    lastDownloadFolderURL = repoPath
                    showOpenFolderButton = true
                } else {
                    lastDownloadFolderURL = nil
                    showOpenFolderButton = false
                }
                // MARK: - Set progressPhase on completion
                progressPhase = "Download complete"

                // If there were any errors and simple log mode is active, auto-switch to full log mode and display full log.
                if (!forbiddenDebs.isEmpty || !downloadIssues.isEmpty) && simpleLogMode {
                    simpleLogMode = false
                    flushLogOutput()
                }
            }
            
            // Log forbidden files
            if !forbiddenDebs.isEmpty {
                await updateLogAsync("🚫 Restricted files (forbidden/paid): \(forbiddenDebs.count) packages\n")
                for forbiddenFile in forbiddenDebs {
                    await updateLogAsync(" - \(forbiddenFile)\n")
                }
            }
            if !downloadIssues.isEmpty {
                await updateLogAsync("❌ Failed to download \(downloadIssues.count) files.\n")
            }
        }
        
        // Append summary line to logOutput before writing log file
        if Task.isCancelled {
            await updateLogAsync("📋 Summary: Operation cancelled by user.\n")
        } else if forbiddenDebs.isEmpty && downloadIssues.isEmpty && errorOutput.isEmpty {
            await updateLogAsync("📋 Summary: Download complete. No errors encountered.\n")
        } else {
            await updateLogAsync("📋 Summary: Download finished with issues.\n")
            if !forbiddenDebs.isEmpty {
                await updateLogAsync("🚫 Restricted (forbidden/paid) packages: \(forbiddenDebs.count)\n")
            }
            if !downloadIssues.isEmpty {
                await updateLogAsync("❌ Failed to download \(downloadIssues.count) files.\n")
            }
            if !errorOutput.isEmpty {
                await updateLogAsync("❌ Errors: \(errorOutput)\n")
            }
        }
        
        await MainActor.run {
            flushLogOutput()
            // Write log file at end
            writeLogFile(to: repoPath, log: logStorage.fullOutput)
            isRunning = false
            downloadTask = nil
            isPaused = false
            // MARK: - Ensure progress is set to 1.0 after completion
            progress = 1.0
            mirrorTask = nil
        }
    }

    // MARK: - Optimized log update function to prevent UI lag
    private func updateLogAsync(_ message: String) async {
        await MainActor.run {
            appendLogMessage(message)
        }
    }

    @MainActor
    private func appendLogMessage(_ message: String) {
        let didTruncate = logStorage.append(message, maxVisibleEntries: maxLogLines)
        if didTruncate {
            isLogTruncated = true
        }

        scheduleLogFlush()
    }

    @MainActor
    private func scheduleLogFlush() {
        guard !isLogFlushScheduled else { return }
        isLogFlushScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            flushLogOutput()
        }
    }

    @MainActor
    private func flushLogOutput() {
        isLogFlushScheduled = false
        logOutput = simpleLogMode ? "" : logStorage.visibleText()
    }

    private func validatePackageURLsBeforeDownload(_ urls: [URL]) async -> String? {
        let sample = Array(urls.prefix(8))
        guard !sample.isEmpty else {
            return "No package download URLs could be prepared from the Packages metadata."
        }

        await updateLogAsync("🔎 Checking first \(sample.count) package URLs before mass download...\n")

        var hardMissingCount = 0
        var checkedCount = 0
        for url in sample {
            if Task.isCancelled {
                return "Download cancelled by user."
            }

            do {
                let statusCode = try await fetchStatusCode(url)
                checkedCount += 1
                if statusCode == 404 || statusCode == 410 {
                    hardMissingCount += 1
                    await updateLogAsync("⚠️ Preflight missing: HTTP \(statusCode) \(url.absoluteString)\n")
                } else if (200...399).contains(statusCode) || statusCode == 401 || statusCode == 403 {
                    await updateLogAsync("✅ Preflight accepted: HTTP \(statusCode) \(url.absoluteString)\n")
                    return nil
                } else {
                    await updateLogAsync("⚠️ Preflight unusual status: HTTP \(statusCode) \(url.absoluteString)\n")
                }
            } catch {
                await updateLogAsync("⚠️ Preflight could not check \(url.absoluteString): \(error.localizedDescription)\n")
            }
        }

        if checkedCount > 0, hardMissingCount == checkedCount {
            return "The repo metadata points to package files that are missing on the server. Stopped before downloading \(urls.count) packages to avoid thousands of HTTP 404 errors."
        }

        return nil
    }
    
    // MARK: - Helper function for parallel .deb file downloads
    
    func downloadDebFile(at index: Int, url debURL: URL, totalCount: Int, repoPath: URL, issueCollector: MirrorIssueCollector) async {
        let fileManager = FileManager.default
        
        // Calculate local file path relative to repoBaseURL
        let localRelativePath = RepoURLResolver.localRelativePath(for: debURL)
        let localFileURL = repoPath.appendingPathComponent(localRelativePath)

        // Ensure directory exists
        let localDir = localFileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: localDir, withIntermediateDirectories: true, attributes: nil)
            await updateLogAsync("📁 Ensured directory exists: \(localDir.path)\n")
        } catch {
            await updateLogAsync("❌ Failed to create directory \(localDir.path): \(error.localizedDescription)\n")
            return
        }

        // Download file if not exists or file size is zero
        if fileManager.fileExists(atPath: localFileURL.path) {
            do {
                let attrs = try fileManager.attributesOfItem(atPath: localFileURL.path)
                if let fileSize = attrs[.size] as? UInt64, fileSize > 0 {
                    await updateLogAsync("⏭️ [\(index+1)/\(totalCount)] Skipping existing file: \(localRelativePath), size: \(fileSize) bytes\n")
                    await MainActor.run {
                        filesDownloaded += 1
                        progress = Double(filesDownloaded) / Double(filesTotal)
                    }
                    return
                }
            } catch {
                // ignore and proceed to download
            }
        }

        await updateLogAsync("⬇️ [\(index+1)/\(totalCount)] Downloading: \(localRelativePath)\n")

        do {
            let fileData = try await fetchURL(debURL)
            try fileData.write(to: localFileURL)
            await updateLogAsync("✅ Saved to \(localFileURL.path), size: \(fileData.count) bytes\n")
            await MainActor.run {
                // MARK: - Update progress after successful file download
                filesDownloaded += 1
                progress = Double(filesDownloaded) / Double(filesTotal)
            }
        } catch {
            await updateLogAsync("❌ Failed to download \(debURL.absoluteString): \(error.localizedDescription)\n")
            await MainActor.run {
                if errorOutput.isEmpty {
                    errorOutput = "Errors occurred during download. See log for details."
                }
                // Still update progress for failed file (count as downloaded for progress bar)
                filesDownloaded += 1
                progress = Double(filesDownloaded) / Double(filesTotal)
            }
            if let statusError = error as? HTTPStatusError, statusError.isRestricted {
                await issueCollector.addRestricted(localRelativePath)
            } else {
                await issueCollector.addFailed(localRelativePath)
            }
        }
    }
    
    // MARK: - Helper to fetch URL with Cydia User-Agent
    
    func fetchURL(_ url: URL) async throws -> Data {
        let request = cydiaRequest(url: url, method: "GET")
        let (data, response) = try await CydiaHTTPClient.session.data(for: request)
        guard let httpResp = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200...299).contains(httpResp.statusCode) else {
            throw HTTPStatusError(statusCode: httpResp.statusCode, url: url)
        }
        return data
    }

    func fetchStatusCode(_ url: URL) async throws -> Int {
        let request = cydiaRequest(url: url, method: "HEAD")
        let (_, response) = try await CydiaHTTPClient.session.data(for: request)
        guard let httpResp = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return httpResp.statusCode
    }

    private func cydiaRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Telesphoreo APT-HTTP/1.0.592", forHTTPHeaderField: "User-Agent")
        request.setValue("iPhone6,1", forHTTPHeaderField: "X-Machine")
        request.setValue("8843d7f92416211de9ebb963ff4ce28125932878", forHTTPHeaderField: "X-Unique-ID")
        request.setValue("10.1.1", forHTTPHeaderField: "X-Firmware")
        return request
    }

    // MARK: - Optimized Packages file parser for large files
    
    // Changed to async, returns relative paths (String) instead of URLs, with logging
    func parsePackagesFile(_ data: Data) async -> [String] {
        // Process in background to prevent UI blocking
        let debRelativePaths = await Task.detached { () -> [String] in
            let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            guard let content else { return [] }
            var debRelativePaths: [String] = []
            let lines = content.components(separatedBy: .newlines)
            var currentPackageDict: [String: String] = [:]

            func foundDebRelativePath(from dict: [String: String]) -> String? {
                guard let filename = dict["Filename"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !filename.isEmpty else { return nil }
                return filename
            }

            for line in lines {
                if line.isEmpty {
                    // block ended, process current package
                    if let debPath = foundDebRelativePath(from: currentPackageDict) {
                        debRelativePaths.append(debPath)
                    }
                    currentPackageDict.removeAll()
                } else if let colonRange = line.range(of: ":") {
                    let key = String(line[..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    let value = String(line[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    if let oldValue = currentPackageDict[key] {
                        currentPackageDict[key] = oldValue + "\n" + value
                    } else {
                        currentPackageDict[key] = value
                    }
                }
            }
            // Last package block (if no trailing newline)
            if !currentPackageDict.isEmpty, let debPath = foundDebRelativePath(from: currentPackageDict) {
                debRelativePaths.append(debPath)
            }
            
            return debRelativePaths
        }.value
        
        await updateLogAsync("📦 parsePackagesFile: Found \(debRelativePaths.count) .deb-Pfade\n")
        if debRelativePaths.isEmpty {
            await updateLogAsync("🔍 Erste 500 Zeichen der Packages-Datei zur Diagnose: \n" + (String(data: data, encoding: .utf8)?.prefix(500) ?? "Could not decode") + "\n")
        }
        return debRelativePaths
    }
    
    // MARK: - Decompress gzip data
    func decompressGzip(data: Data) throws -> Data {
        // SWCompression will unpack the first member of the .gz archive
        return try GzipArchive.unarchive(archive: data)
    }

    // MARK: - Decompress bz2 data
    func decompressBz2(data: Data) throws -> Data {
        // BZip2.decompress returns the raw decompressed bytes
        return try BZip2.decompress(data: data)
    }
    
    // MARK: - Helper to write the log file
    private func writeLogFile(to folder: URL, log: String) {
        let logFileURL = folder.appendingPathComponent("download.log")
        do {
            try log.write(to: logFileURL, atomically: true, encoding: .utf8)
        } catch {
            Task {
                await updateLogAsync("Failed to write log file: \(error.localizedDescription)\n")
            }
        }
    }
    
    func openRepoFolder() {
        guard let url = repoFolderURL else { return }
        NSWorkspace.shared.open(url)
    }
    
    /// Recursively download all reachable files from a given base URL to the given destination directory (mimics wget -r)
    func recursiveMirrorRepo(
        from baseURL: URL,
        to localDir: URL,
        isTopLevel: Bool = true,
        visitTracker: URLVisitTracker,
        rootHost: String?,
        depth: Int = 0,
        maxDepth: Int = 8
    ) async {
        await updateLogAsync("🔄 Recursively mirroring: \(baseURL.absoluteString)\n")
        await MainActor.run {
            progressPhase = "Downloading additional repo files..."
        }
        
        let fileManager = FileManager.default

        guard depth <= maxDepth else {
            await updateLogAsync("⚠️ Recursive mirror depth limit reached at \(baseURL.absoluteString)\n")
            return
        }

        guard await visitTracker.markIfNew(baseURL) else { return }
        
        // Check for cancellation before proceeding
        if Task.isCancelled {
            await updateLogAsync("🛑 Recursive mirror cancelled.\n")
            await MainActor.run {
                progressPhase = "Download cancelled"
            }
            return
        }
        
        // Fetch directory HTML/listing
        do {
            let data = try await fetchURL(baseURL)
            guard let html = String(data: data, encoding: .utf8) else { return }
            
            // Extract all href and src attributes
            let patterns = ["(?:href|src)\\s*=\\s*[\"']([^\"']+)[\"']"]
            var sublinks: Set<String> = []
            for pattern in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                    let nsHtml = html as NSString
                    let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHtml.length))
                    for match in matches {
                        if let range = Range(match.range(at: 1), in: html) {
                            let link = String(html[range])
                            // Skip parent and in-page links
                            if link == "../" || link.hasPrefix("#") { continue }
                            if link.localizedCaseInsensitiveContains("javascript:") { continue }
                            if link.localizedCaseInsensitiveContains("mailto:") { continue }
                            sublinks.insert(link)
                        }
                    }
                }
            }
            
            // Filter out debs directory to avoid nested structures
            let filteredLinks = sublinks.filter { link in
                // Skip debs directory to prevent nested debs/debs structure
                if link == "debs/" || link.hasPrefix("debs/") {
                    return false
                }
                // Skip files that are already downloaded by the main pass
                let localFileURL = localDir.appendingPathComponent(link)
                if fileManager.fileExists(atPath: localFileURL.path) {
                    return false
                }
                guard let subURL = URL(string: link, relativeTo: baseURL)?.absoluteURL else {
                    return false
                }
                guard subURL.scheme == "http" || subURL.scheme == "https" else {
                    return false
                }
                guard rootHost == nil || subURL.host == rootHost else {
                    return false
                }
                return true
            }
            
            // Count files for progress tracking
            let fileLinks = filteredLinks.filter { !$0.hasSuffix("/") }
            if isTopLevel {
                await MainActor.run {
                    recursiveFilesTotal = fileLinks.count
                    recursiveFilesDownloaded = 0
                }
            }
            
            // Normalize links and deduplicate
            for link in filteredLinks {
                // Check for cancellation before each file
                if Task.isCancelled {
                    await MainActor.run {
                        appendLogMessage("🛑 Recursive mirror cancelled during file processing.\n")
                        progressPhase = "Download cancelled"
                    }
                    return
                }
                
                guard let subURL = URL(string: link, relativeTo: baseURL)?.absoluteURL else { continue }
                guard subURL.scheme == "http" || subURL.scheme == "https" else { continue }
                guard rootHost == nil || subURL.host == rootHost else {
                    await updateLogAsync("⏭️ Skipping off-site URL during recursive mirror: \(subURL.absoluteString)\n")
                    continue
                }
                let relativePath = RepoURLResolver.localRelativePath(for: subURL, relativeTo: baseURL)
                let localFileURL = localDir.appendingPathComponent(relativePath)
                let isDirectory = link.hasSuffix("/")
                
                if isDirectory {
                    do {
                        try fileManager.createDirectory(at: localFileURL, withIntermediateDirectories: true, attributes: nil)
                        await updateLogAsync("📁 Created directory for recursive mirror: \(localFileURL.path)\n")
                    } catch {
                        await updateLogAsync("❌ Failed to create directory during recursive mirror: \(localFileURL.path): \(error.localizedDescription)\n")
                    }
                    await recursiveMirrorRepo(
                        from: subURL,
                        to: localFileURL,
                        isTopLevel: false,
                        visitTracker: visitTracker,
                        rootHost: rootHost,
                        depth: depth + 1,
                        maxDepth: maxDepth
                    )
                } else {
                    await updateLogAsync("⬇️ Recursively downloading: \(subURL.absoluteString)\n")
                    do {
                        // Do not overwrite files already downloaded by the main pass
                        if !fileManager.fileExists(atPath: localFileURL.path) {
                            let fileData = try await fetchURL(subURL)
                            try fileData.write(to: localFileURL)
                            await updateLogAsync("✅ Saved recursively to \(localFileURL.path)\n")
                            await MainActor.run {
                                recursiveFilesDownloaded += 1
                            }
                        } else {
                            await MainActor.run {
                                recursiveFilesDownloaded += 1
                            }
                        }
                    } catch {
                        await updateLogAsync("❌ Failed to download (recursive) \(subURL.absoluteString): \(error.localizedDescription)\n")
                        await MainActor.run {
                            recursiveFilesDownloaded += 1
                        }
                    }
                }
            }
        } catch {
            // Not a directory or not listing, nothing to do
            await updateLogAsync("⚠️ Directory fetch failed or not a directory: \(baseURL.absoluteString)\n")
            await updateLogAsync("❌ Error: \(error.localizedDescription)\n")
        }
        
        if Task.isCancelled {
            await updateLogAsync("\n🛑 Recursive mirror cancelled.\n")
            await MainActor.run {
                progressPhase = "Download cancelled"
            }
        } else {
            await MainActor.run {
                progressPhase = "Download complete"
                downloadSummary = "Recursive mirror complete."
            }
        }
        
        if isTopLevel {
            // Append summary line to logOutput before writing log file
            if Task.isCancelled {
                await updateLogAsync("📋 Summary: Operation cancelled by user.\n")
            } else if errorOutput.isEmpty {
                await updateLogAsync("📋 Summary: Recursive mirror completed successfully.\n")
            } else {
                await updateLogAsync("📋 Summary: Recursive mirror completed with errors: \(errorOutput)\n")
            }
            await MainActor.run {
                flushLogOutput()
                isRunning = false
                downloadTask = nil
                isPaused = false
                showOpenFolderButton = (repoFolderURL != nil && fileManager.fileExists(atPath: repoFolderURL!.path))
                // Write log file at end
                writeLogFile(to: localDir, log: logStorage.fullOutput)
                mirrorTask = nil
            }
        }
    }
}

struct LogScrollBottomKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct VictorPhotoSheet: View {
    // The image asset should be named "victor_photo" in the Asset Catalog.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image("victor")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 300, maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 8)
            Text("Hey, i´m Victor 🤠")
                .font(.headline)
                .foregroundColor(.primary)
            Button("Hey Victor") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(minWidth: 350, minHeight: 400)
    }
}

#Preview {
    ContentView()
}
