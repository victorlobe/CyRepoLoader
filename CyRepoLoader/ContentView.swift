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
    
    // *** New state variable for last download folder URL ***
    @State private var lastDownloadFolderURL: URL? = nil

    // Deduplication set for recursive mirror URLs
    private var alreadyMirroredURLs = Set<String>()
    
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
                    Text("CyRepoLoader")
                        .font(.title2)
                        .bold()
                    Text("by Victor")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Picker("", selection: $selectedScheme) {
                        Text("http://").tag("http")
                        Text("https://").tag("https")
                        Text("Custom").tag("")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 90)
                    .onChange(of: selectedScheme) { _ in
                        repoURL = repoURL.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
                        UserDefaults.standard.set(selectedScheme, forKey: selectedSchemeKey)
                    }
                    TextField("Cydia Repo URL", text: $repoURL)
                        .textFieldStyle(.roundedBorder)
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
                                mirrorTask = Task { await mirrorRepo() }
                            }
                        }
                }

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
                    Toggle("Full Log", isOn: .init(get: { !simpleLogMode }, set: { simpleLogMode = !$0 }))
                        .padding(.leading, 8)
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
                        downloadTask = nil
                        showOpenFolderButton = false
                        errorOutput = "" // Reset errors when starting a new download
                        downloadSummary = nil
                        logOutput = ""   // Clear log only when starting a new download
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
                    // New "Show in Finder" button per instructions
                    if !isRunning, let downloadURL = lastDownloadFolderURL {
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
                    VStack(alignment: .leading) {
                        if isRunning || filesTotal > 0 {
                            Text(progressPhase)
                                .font(.subheadline) // New
                                .foregroundColor(.primary) // New
                            
                            ProgressView(value: filesTotal > 0 ? min(max(progress, 0.0), 1.0) : 0.0)
                                .progressViewStyle(LinearProgressViewStyle())
                                .frame(maxWidth: .infinity)
                            
                            Text("Downloading \(filesDownloaded) of \(filesTotal) (.deb files)...")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .padding(.top, 2)
                        }
                        if let summary = downloadSummary, summary.localizedCaseInsensitiveContains("error") || summary.localizedCaseInsensitiveContains("failed") {
                            Text(summary)
                                .padding(.top, 6)
                                .foregroundColor(summary.localizedCaseInsensitiveContains("error") || summary.localizedCaseInsensitiveContains("failed") ? .red : .green)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 8)
                } else {
                    // Always show logOutput ScrollView, never hide or clear it except when starting new download
                    ScrollViewReader { proxy in
                        ZStack(alignment: .bottomTrailing) {
                            GeometryReader { geometry in
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(logOutput)
                                            .textSelection(.enabled)
                                            .font(.system(.footnote, design: .monospaced))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(8)
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
                
                if !isRunning, showOpenFolderButton, let repoFolderURL = repoFolderURL, FileManager.default.fileExists(atPath: repoFolderURL.path) {
                    Text("Download finished. You can open the download folder below.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                    
                    if let summary = downloadSummary, summary.localizedCaseInsensitiveContains("error") || summary.localizedCaseInsensitiveContains("failed") {
                        Text(summary)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundColor(summary.localizedCaseInsensitiveContains("error") || summary.localizedCaseInsensitiveContains("failed") ? .red : .green)
                    }
                    
                    Button("Open Folder") {
                        openRepoFolder()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
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
        }
        
        // Log start of session with selected repo and destination
        await MainActor.run {
            if !simpleLogMode {
                logOutput += "Starting download session.\n"
                logOutput += "Repo URL (selected scheme + repoURL): \(selectedScheme.isEmpty ? "" : selectedScheme + "://")\(repoURL.trimmingCharacters(in: .whitespacesAndNewlines))\n"
                logOutput += "Download destination directory: \(destDir)\n"
            }
        }

        await MainActor.run {
            isRunning = true
            logOutput = ""
            shouldAutoScroll = true
            showOpenFolderButton = false
            // Reset progress-related state at start
            progress = 0
            filesDownloaded = 0
            filesTotal = 0
            // MARK: - Set progressPhase at initial validation phase
            progressPhase = "Validating URL and destination"
        }

        // Compose final URL string with selected scheme
        let cleanRepoURL = repoURL.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
        let finalURLString = (selectedScheme.isEmpty ? "" : selectedScheme + "://") + cleanRepoURL

        // Validate finalURLString
        let trimmedFinalURL = finalURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        await MainActor.run {
            if !simpleLogMode {
                logOutput += "Validating URL: \(trimmedFinalURL)\n"
            }
        }
        guard let baseURL = URL(string: trimmedFinalURL) else {
            await MainActor.run {
                if !simpleLogMode {
                    logOutput += "Invalid URL format.\n"
                }
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
                if !simpleLogMode {
                    logOutput += "Invalid URL scheme: \(baseURL.scheme ?? "none")\n"
                }
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
            if !simpleLogMode {
                logOutput += "URL scheme is valid: \(scheme)\n"
            }
        }

        // Validate destDir
        let expandedDestDir = (destDir as NSString).expandingTildeInPath
        await MainActor.run {
            if !simpleLogMode {
                logOutput += "Validating destination directory: \(expandedDestDir)\n"
            }
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandedDestDir, isDirectory: &isDir), isDir.boolValue else {
            await MainActor.run {
                if !simpleLogMode {
                    logOutput += "Invalid destination directory: does not exist or not a directory.\n"
                }
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
            if !simpleLogMode {
                logOutput += "Destination directory is valid.\n"
            }
        }

        // Create repo folder path
        let urlHost = baseURL.host ?? "repo"
        let repoPath = URL(fileURLWithPath: expandedDestDir).appendingPathComponent(urlHost, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true, attributes: nil)
            await MainActor.run {
                if !simpleLogMode {
                    logOutput += "Created repo directory at \(repoPath.path)\n"
                }
            }
        } catch {
            await MainActor.run {
                if !simpleLogMode {
                    logOutput += "Failed to create repo directory: \(error.localizedDescription)\n"
                }
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
            if !simpleLogMode {
                logOutput += "Checking repo metadata files...\n"
            }
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
        let fallbackSubpaths = [
            "/./",
            "/dists/stable/main/binary-iphoneos-arm/"
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
                        if !simpleLogMode {
                            logOutput += "Trying \(url.absoluteString)...\n"
                        }
                    }
                    let data = try await fetchURL(url)
                    await MainActor.run { 
                        if !simpleLogMode {
                            logOutput += "Found \(filename) at \(url.absoluteString)\n"
                        }
                    }
                    return data
                } catch {
                    await MainActor.run { 
                        if !simpleLogMode {
                            logOutput += "Not found or error fetching \(filename) at \(url.absoluteString): \(error.localizedDescription)\n"
                        }
                    }
                }
            }
            return nil
        }

        // First, try root metadata files (Release, Packages, etc) as before
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
            let classicSubpath = "/dists/stable/main/binary-iphoneos-arm/"
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

        // Expliziter BigBoss-Debian-Standardpfad-Test: try /dists/stable/main/binary-iphoneos-arm/Packages.bz2 explicitly
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
                let subpath = "/dists/\(release)/\(comp)/binary-iphoneos-arm/"
                constructedSubpaths.append(subpath)
            }
        }

        if suite != nil || codename != nil {
            await MainActor.run {
                if !simpleLogMode {
                    logOutput += "Parsed Release file fields: Suite=\(suite ?? "nil"), Codename=\(codename ?? "nil"), Components=\(components.isEmpty ? "main" : components.joined(separator: ", "))\n"
                }
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
                    if !simpleLogMode {
                        logOutput += "No Release file found at root; trying constructed subpaths for Packages files.\n"
                    }
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
                // Try fallback hardcoded subpaths if constructed subpaths failed
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

        guard let metadataURL = foundMetadataURL, let metadata = metadataData, let metadataName = metadataFileName else {
            await MainActor.run {
                if !simpleLogMode {
                    logOutput += "Failed to locate repo metadata files (Release, Packages, Packages.bz2, or Packages.gz).\n"
                }
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
                if !simpleLogMode {
                    logOutput += "Parsing Packages file...\n"
                }
                progressPhase = "Parsing Packages file..."
            }
        } else if metadataName == "Packages.gz" {
            await MainActor.run {
                if !simpleLogMode {
                    logOutput += "Parsing Packages.gz file...\n"
                    logOutput += "Packages.gz size: \(metadata.count) bytes\n"
                }
                progressPhase = "Parsing Packages.gz file..."
            }
        } else if metadataName == "Packages.bz2" {
            await MainActor.run {
                if !simpleLogMode {
                    logOutput += "Parsing Packages.bz2 file...\n"
                    logOutput += "Packages.bz2 size: \(metadata.count) bytes\n"
                }
                progressPhase = "Parsing Packages.bz2 file..."
            }
        }

        // Parse Packages or compressed Packages files for .deb relative paths if applicable
        var debRelativePaths: [String] = []
        if metadataName == "Packages" {
            debRelativePaths = await parsePackagesFile(metadata)
            if debRelativePaths.isEmpty {
                await MainActor.run {
                    if !simpleLogMode {
                        logOutput += "No .deb file URLs found in Packages file.\n"
                    }
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
                    if !simpleLogMode {
                        logOutput += "Successfully decompressed Packages.gz, size after decompression: \(packagesData.count) bytes\n"
                    }
                }
                debRelativePaths = await parsePackagesFile(packagesData)
                if debRelativePaths.isEmpty {
                    await MainActor.run {
                        if !simpleLogMode {
                            logOutput += "No .deb file URLs found in Packages.gz file after decompression.\n"
                        }
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
                    if !simpleLogMode {
                        logOutput += "Failed to decompress Packages.gz: \(error.localizedDescription)\n"
                    }
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
                    if !simpleLogMode {
                        logOutput += "Packages.bz2 decompressed, size: \(packagesData.count) Bytes\n"
                    }
                }
                if let content = String(data: packagesData, encoding: .utf8) {
                    await MainActor.run { 
                        if !simpleLogMode {
                            logOutput += "--- Packages.bz2 Preview (UTF-8, first 1000 chars):\n\(content.prefix(1000))\n------------------------------\n"
                        }
                    }
                } else if let content = String(data: packagesData, encoding: .isoLatin1) {
                    await MainActor.run { 
                        if !simpleLogMode {
                            logOutput += "--- Packages.bz2 Preview (Latin1, first 1000 chars):\n\(content.prefix(1000))\n------------------------------\n"
                        }
                    }
                } else {
                    await MainActor.run { 
                        if !simpleLogMode {
                            logOutput += "Could not decode Packages.bz2 as UTF-8 or Latin1.\n"
                        }
                    }
                }
                debRelativePaths = await parsePackagesFile(packagesData)
                if debRelativePaths.isEmpty {
                    await MainActor.run {
                        if !simpleLogMode {
                            logOutput += "No .deb file URLs found in Packages.bz2 file after decompression.\n"
                        }
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
                    if !simpleLogMode {
                        logOutput += "BZ2 decompression failed or not supported: \(error.localizedDescription)\n"
                    }
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
                if !simpleLogMode {
                    logOutput += "Release file found, but no Packages file; starting recursive mirror...\n"
                }
            }
            await recursiveMirrorRepo(from: repoBaseURL, to: repoPath, isTopLevel: true)
            return
        }

        // MARK: - Set progressPhase when preparing download list
        await MainActor.run {
            if !simpleLogMode {
                logOutput += "Preparing download list with \(debRelativePaths.count) entries from \(metadataName)...\n"
            }
            progressPhase = "Preparing download list..."
        }

        // Now join each relative path with repoBaseURL safely to form absolute URLs to download
        var debURLs: [URL] = []
        let repoRootURL: URL
        if let host = baseURL.host {
            // Nur das Protokoll + Host + evtl. Pfad bis "cydia"
            var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            comps?.path = "/repofiles/cydia/"
            repoRootURL = comps?.url ?? baseURL
        } else {
            repoRootURL = baseURL
        }
        for relativePath in debRelativePaths {
            if let url = URL(string: relativePath), url.scheme == nil {
                // Prüfe auf BigBoss: beginnt mit "debs2.0/"
                if relativePath.hasPrefix("debs2.0/") {
                    let combinedURL = repoRootURL.appendingPathComponent(relativePath)
                    debURLs.append(combinedURL)
                } else {
                    let combinedURL = repoBaseURL.appendingPathComponent(relativePath)
                    debURLs.append(combinedURL)
                }
            } else if let url = URL(string: relativePath) {
                debURLs.append(url)
            }
        }
        // Damit werden für BigBoss und ähnlich strukturierte Repos die .deb-Downloads korrekt erzeugt.

        // MARK: - Setup progress tracking before download loop and update phase
        await MainActor.run {
            if !simpleLogMode {
                logOutput += "Starting download of \(debURLs.count) .deb files...\n"
            }
            filesTotal = debURLs.count
            filesDownloaded = 0
            progress = 0
            // MARK: - Update progressPhase for downloading
            progressPhase = "Downloading .deb files..."
        }

        // Save to history
        await MainActor.run {
            saveHistoryURL(trimmedFinalURL)
        }

        var downloadIssues: [String] = []

        // Download .deb files in sequence to preserve order and progress display
        for (index, debURL) in debURLs.enumerated() {
            if Task.isCancelled || !isRunning {
                break
            }

            // Calculate local file path relative to repoBaseURL
            var localRelativePath = debURL.path
            if let baseHost = repoBaseURL.host, baseHost == debURL.host {
                let basePath = repoBaseURL.path
                if localRelativePath.hasPrefix(basePath) {
                    localRelativePath = String(localRelativePath.dropFirst(basePath.count))
                }
            }
            if localRelativePath.hasPrefix("/") { localRelativePath.removeFirst() }
            let localFileURL = repoPath.appendingPathComponent(localRelativePath)

            // Ensure directory exists
            let localDir = localFileURL.deletingLastPathComponent()
            do {
                try fileManager.createDirectory(at: localDir, withIntermediateDirectories: true, attributes: nil)
                await MainActor.run {
                    if !simpleLogMode {
                        logOutput += "Ensured directory exists: \(localDir.path)\n"
                    }
                }
            } catch {
                await MainActor.run {
                    if !simpleLogMode {
                        logOutput += "Failed to create directory \(localDir.path): \(error.localizedDescription)\n"
                    }
                }
                continue
            }

            // Download file if not exists or file size is zero
            if fileManager.fileExists(atPath: localFileURL.path) {
                do {
                    let attrs = try fileManager.attributesOfItem(atPath: localFileURL.path)
                    if let fileSize = attrs[.size] as? UInt64, fileSize > 0 {
                        await MainActor.run {
                            if !simpleLogMode {
                                logOutput += "[\(index+1)/\(debURLs.count)] Skipping existing file: \(localRelativePath), size: \(fileSize) bytes\n"
                            }
                            filesDownloaded += 1
                            progress = Double(filesDownloaded) / Double(filesTotal)
                        }
                        continue
                    }
                } catch {
                    // ignore and proceed to download
                }
            }

            await MainActor.run {
                if !simpleLogMode {
                    logOutput += "[\(index+1)/\(debURLs.count)] Downloading: \(localRelativePath)\n"
                }
            }

            do {
                let fileData = try await fetchURL(debURL)
                try fileData.write(to: localFileURL)
                await MainActor.run {
                    if !simpleLogMode {
                        logOutput += "Saved to \(localFileURL.path), size: \(fileData.count) bytes\n"
                    }
                    // MARK: - Update progress after successful file download
                    filesDownloaded += 1
                    progress = Double(filesDownloaded) / Double(filesTotal)
                }
            } catch {
                await MainActor.run {
                    if !simpleLogMode {
                        logOutput += "Failed to download \(debURL.absoluteString): \(error.localizedDescription)\n"
                    }
                    if errorOutput.isEmpty {
                        errorOutput = "Errors occurred during download. See log for details."
                    }
                    // Still update progress for failed file (count as downloaded for progress bar)
                    filesDownloaded += 1
                    progress = Double(filesDownloaded) / Double(filesTotal)
                }
                downloadIssues.append("\(localRelativePath)")
            }
        }

        // Additional step: Mirror anything else in the repo
        // Recursively mirror all remaining files (icons, banners, html, etc.) for full repo hosting
        await MainActor.run {
            if !simpleLogMode {
                logOutput += "Starting recursive mirror of remaining repo files...\n"
            }
        }
        await recursiveMirrorRepo(from: baseURL, to: repoPath, isTopLevel: true)

        await MainActor.run {
            if Task.isCancelled {
                if !simpleLogMode {
                    logOutput += "\nDownload cancelled by user.\n"
                }
                downloadSummary = nil
                // MARK: - Set progressPhase on cancel
                progressPhase = "Download cancelled"
            } else {
                if !simpleLogMode {
                    logOutput += "\nAll done. Your local mirror is at: \(repoPath.path)\n"
                    logOutput += "Download complete.\n"
                }
                // Clear previous errors on success
                errorOutput = ""
                if downloadIssues.isEmpty {
                    // Removed assignment of downloadSummary = "Success"
                    // downloadSummary = "Success"
                } else {
                    let maxDisplay = 10
                    let displayList = downloadIssues.prefix(maxDisplay).joined(separator: "\n")
                    let moreText = downloadIssues.count > maxDisplay ? "\n..." : ""
                    let baseSummary = "Failed to download \(downloadIssues.count) file(s):\n\(displayList)\(moreText)"
                    downloadSummary = baseSummary
                    if !simpleLogMode {
                        logOutput += "Failed to download \(downloadIssues.count) files.\n"
                    }
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
            }
            // Append summary line to logOutput before writing log file
            if Task.isCancelled {
                logOutput += "Summary: Operation cancelled by user.\n"
            } else if downloadIssues.isEmpty && errorOutput.isEmpty {
                logOutput += "Summary: Download complete. No errors encountered.\n"
            } else if !downloadIssues.isEmpty {
                logOutput += "Summary: Download finished with \(downloadIssues.count) errors. See above for details.\n"
            } else if !errorOutput.isEmpty {
                logOutput += "Summary: Completed with error: \(errorOutput)\n"
            }
            // Write log file at end
            writeLogFile(to: repoPath, log: logOutput)
            isRunning = false
            downloadTask = nil
            isPaused = false
            // MARK: - Ensure progress is set to 1.0 after completion
            progress = 1.0
            mirrorTask = nil
        }
    }

    // MARK: - Helper to fetch URL with Cydia User-Agent
    
    func fetchURL(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        //request.setValue("Cydia/1.1.30", forHTTPHeaderField: "User-Agent")
        request.setValue("Telesphoreo APT-HTTP/1.0.592", forHTTPHeaderField: "User-Agent")
        request.setValue("iPhone6,1", forHTTPHeaderField: "X-Machine")
        request.setValue("8843d7f92416211de9ebb963ff4ce28125932878", forHTTPHeaderField: "X-Unique-ID")
        request.setValue("10.1.1", forHTTPHeaderField: "X-Firmware")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResp = response as? HTTPURLResponse,
              (200...299).contains(httpResp.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: - Parse Packages file to extract .deb relative paths
    
    // Changed to async, returns relative paths (String) instead of URLs, with logging
    func parsePackagesFile(_ data: Data) async -> [String] {
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
        await MainActor.run { logOutput += "parsePackagesFile: Found \(debRelativePaths.count) .deb-Pfade\n" }
        if debRelativePaths.isEmpty {
            await MainActor.run { logOutput += "Erste 500 Zeichen der Packages-Datei zur Diagnose: \n" + (content.prefix(500)) + "\n" }
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
            DispatchQueue.main.async {
                logOutput += "Failed to write log file: \(error.localizedDescription)\n"
            }
        }
    }
    
    func openRepoFolder() {
        guard let url = repoFolderURL else { return }
        NSWorkspace.shared.open(url)
    }
    
    /// Recursively download all reachable files from a given base URL to the given destination directory (mimics wget -r)
    func recursiveMirrorRepo(from baseURL: URL, to localDir: URL, isTopLevel: Bool = true) async {
        await MainActor.run { 
            if !simpleLogMode {
                logOutput += "Recursively mirroring: \(baseURL.absoluteString)\n"
            }
            progressPhase = "Downloading Metadata..."
        }
        let session = URLSession.shared
        let fileManager = FileManager.default
        // Track visited URLs globally for this session to avoid loops
        struct Static {
            static var visited = Set<String>()
        }
        let baseString = baseURL.absoluteString
        guard !Static.visited.contains(baseString) else { return }
        Static.visited.insert(baseString)
        // Fetch directory HTML/listing
        do {
            let data = try await fetchURL(baseURL)
            guard let html = String(data: data, encoding: .utf8) else { return }
            // Extract all href and src attributes
            let patterns = ["href\\s*=\\s*\"([^\"]+)\"", "src\\s*=\\s*\"([^\"]+)\""]
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
                            sublinks.insert(link)
                        }
                    }
                }
            }
            // Normalize links and deduplicate
            for link in sublinks {
                let subURL = URL(string: link, relativeTo: baseURL)?.absoluteURL ?? baseURL.appendingPathComponent(link)
                let relativePath = subURL.path.replacingOccurrences(of: baseURL.path, with: "", options: .anchored)
                let localFileURL = localDir.appendingPathComponent(relativePath)
                let isDirectory = link.hasSuffix("/")
                if isDirectory {
                    do { 
                        try fileManager.createDirectory(at: localFileURL, withIntermediateDirectories: true, attributes: nil) 
                        await MainActor.run {
                            if !simpleLogMode {
                                logOutput += "Created directory for recursive mirror: \(localFileURL.path)\n"
                            }
                        }
                    } catch {
                        await MainActor.run {
                            if !simpleLogMode {
                                logOutput += "Failed to create directory during recursive mirror: \(localFileURL.path): \(error.localizedDescription)\n"
                            }
                        }
                    }
                    await recursiveMirrorRepo(from: subURL, to: localFileURL, isTopLevel: false)
                } else {
                    await MainActor.run { 
                        if !simpleLogMode {
                            logOutput += "Recursively downloading: \(subURL.absoluteString)\n"
                        }
                    }
                    do {
                        // Do not overwrite files already downloaded by the main pass
                        if !fileManager.fileExists(atPath: localFileURL.path) {
                            let fileData = try await fetchURL(subURL)
                            try fileData.write(to: localFileURL)
                            await MainActor.run {
                                if !simpleLogMode {
                                    logOutput += "Saved recursively to \(localFileURL.path)\n"
                                }
                            }
                        }
                    } catch {
                        await MainActor.run { 
                            if !simpleLogMode {
                                logOutput += "Failed to download (recursive) \(subURL.absoluteString): \(error.localizedDescription)\n"
                            }
                        }
                    }
                }
            }
        } catch {
            // Not a directory or not listing, nothing to do
            await MainActor.run {
                if !simpleLogMode {
                    logOutput += "Directory fetch failed or not a directory: \(baseURL.absoluteString)\n"
                    logOutput += "Error: \(error.localizedDescription)\n"
                }
            }
        }
        await MainActor.run {
            if Task.isCancelled {
                if !simpleLogMode {
                    logOutput += "\nRecursive mirror cancelled.\n"
                }
                progressPhase = "Download cancelled"
            } else {
                progressPhase = "Download complete"
                downloadSummary = "Recursive mirror complete."
            }
            if isTopLevel {
                // Append summary line to logOutput before writing log file
                if Task.isCancelled {
                    logOutput += "Summary: Operation cancelled by user.\n"
                } else if errorOutput.isEmpty {
                    logOutput += "Summary: Recursive mirror completed successfully.\n"
                } else {
                    logOutput += "Summary: Recursive mirror completed with errors: \(errorOutput)\n"
                }
                isRunning = false
                downloadTask = nil
                isPaused = false
                showOpenFolderButton = (repoFolderURL != nil && fileManager.fileExists(atPath: repoFolderURL!.path))
                // Write log file at end
                writeLogFile(to: localDir, log: logOutput)
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

#Preview {
    ContentView()
}

