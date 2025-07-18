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
    @State private var downloadTask: URLSessionDownloadTask? = nil
    @State private var isPaused: Bool = false
    
    @State private var showOpenFolderButton: Bool = false
    
    @State private var selectedScheme: String = "https"
    
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
                HStack {
                    Picker("", selection: $selectedScheme) {
                        Text("").tag("")
                        Text("http://").tag("http")
                        Text("https://").tag("https")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 90)
                    .onChange(of: selectedScheme) { _ in
                        repoURL = repoURL.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
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
                                logOutput = ""
                                Task { await mirrorRepo() }
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

                        // Pause/Resume disabled for now because URLSession tasks are not trivially pausable
                        /*
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
                        */
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
        if let task = downloadTask {
            task.cancel()
            Task { await MainActor.run {
                errorOutput = "Download cancelled by user."
                isRunning = false
                downloadTask = nil
                isPaused = false
                showOpenFolderButton = false
            }}
        }
    }

    func pauseDownload() {
        // Pause/resume disabled for now
    }

    func resumeDownload() {
        // Pause/resume disabled for now
    }

    // MARK: - New mirrorRepo implementation
    
    func mirrorRepo() async {
        await MainActor.run {
            errorOutput = ""
        }

        await MainActor.run {
            isRunning = true
            logOutput = ""
            shouldAutoScroll = true
            showOpenFolderButton = false
        }

        await MainActor.run { logOutput += "Validating URL and destination directory...\n" }

        // Compose final URL string with selected scheme
        let cleanRepoURL = repoURL.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
        let finalURLString = (selectedScheme.isEmpty ? "" : selectedScheme + "://") + cleanRepoURL

        // Validate finalURLString
        let trimmedFinalURL = finalURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: trimmedFinalURL) else {
            await MainActor.run {
                errorOutput = "Invalid URL: Please enter a valid URL starting with http:// or https://"
                isRunning = false
            }
            return
        }
        guard let scheme = baseURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            await MainActor.run {
                errorOutput = "Invalid URL scheme: Use http:// or https://"
                isRunning = false
            }
            return
        }

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

        // Create repo folder path
        let urlHost = baseURL.host ?? "repo"
        let repoPath = URL(fileURLWithPath: expandedDestDir).appendingPathComponent(urlHost, isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: repoPath, withIntermediateDirectories: true, attributes: nil)
        } catch {
            await MainActor.run {
                errorOutput = "Failed to create destination directory: \(error.localizedDescription)"
                isRunning = false
            }
            return
        }

        await MainActor.run { logOutput += "Checking repo metadata files...\n" }

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
                    await MainActor.run { logOutput += "Trying \(url.absoluteString)...\n" }
                    let data = try await fetchURL(url)
                    await MainActor.run { logOutput += "Found \(filename) at \(url.absoluteString)\n" }
                    return data
                } catch {
                    await MainActor.run { logOutput += "Not found or error fetching \(filename) at \(url.absoluteString): \(error.localizedDescription)\n" }
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
            await MainActor.run { logOutput += "Parsed Release file fields: Suite=\(suite ?? "nil"), Codename=\(codename ?? "nil"), Components=\(components.isEmpty ? "main" : components.joined(separator: ", "))\n" }
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
                await MainActor.run { logOutput += "No Release file found at root; trying constructed subpaths for Packages files.\n" }
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
                errorOutput = "Failed to locate repo metadata files (Release, Packages, Packages.bz2, or Packages.gz)."
                isRunning = false
            }
            return
        }

        // Parse Packages or compressed Packages files for .deb relative paths if applicable
        var debRelativePaths: [String] = []
        if metadataName == "Packages" {
            await MainActor.run { logOutput += "Parsing Packages file...\n" }
            debRelativePaths = parsePackagesFile(metadata)
            if debRelativePaths.isEmpty {
                await MainActor.run {
                    errorOutput = "No .deb file URLs found in Packages file."
                    isRunning = false
                }
                return
            }
        } else if metadataName == "Packages.gz" {
            await MainActor.run { logOutput += "Parsing Packages.gz file...\n" }
            do {
                let packagesData = try decompressGzip(data: metadata)
                debRelativePaths = parsePackagesFile(packagesData)
                if debRelativePaths.isEmpty {
                    await MainActor.run {
                        errorOutput = "No .deb file URLs found in Packages.gz file."
                        isRunning = false
                    }
                    return
                }
            } catch {
                await MainActor.run {
                    errorOutput = "Failed to parse Packages.gz file: \(error.localizedDescription)"
                    isRunning = false
                }
                return
            }
        } else if metadataName == "Packages.bz2" {
            await MainActor.run { logOutput += "Parsing Packages.bz2 file...\n" }
            do {
                let packagesData = try decompressBz2(data: metadata)
                debRelativePaths = parsePackagesFile(packagesData)
                if debRelativePaths.isEmpty {
                    await MainActor.run {
                        errorOutput = "No .deb file URLs found in Packages.bz2 file."
                        isRunning = false
                    }
                    return
                }
            } catch {
                await MainActor.run {
                    errorOutput = "BZ2 decompression not supported yet. Cannot parse Packages.bz2."
                    isRunning = false
                }
                return
            }
        } else if metadataName == "Release" {
            // Release file found, but no Packages file; fallback to recursive mirror
            await recursiveMirrorRepo(from: repoBaseURL, to: repoPath)
            return
        }

        // Now join each relative path with repoBaseURL safely to form absolute URLs to download
        var debURLs: [URL] = []
        for relativePath in debRelativePaths {
            if let url = URL(string: relativePath), url.scheme == nil {
                // relative path - join with repoBaseURL
                let combinedURL = repoBaseURL.appendingPathComponent(relativePath)
                debURLs.append(combinedURL)
            } else if let url = URL(string: relativePath) {
                // absolute URL (with http/https)
                debURLs.append(url)
            }
        }

        // Start downloading all .deb files one by one
        await MainActor.run {
            logOutput += "Starting download of \(debURLs.count) .deb files...\n"
        }

        // Save to history
        await MainActor.run {
            saveHistoryURL(trimmedFinalURL)
        }

        // Download .deb files in sequence to preserve order and progress display
        for (index, debURL) in debURLs.enumerated() {
            if !isRunning {
                await MainActor.run { logOutput += "Download cancelled.\n" }
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
            } catch {
                await MainActor.run {
                    logOutput += "Failed to create directory \(localDir.path): \(error.localizedDescription)\n"
                }
                continue
            }

            // Download file if not exists or file size is zero
            if fileManager.fileExists(atPath: localFileURL.path) {
                do {
                    let attrs = try fileManager.attributesOfItem(atPath: localFileURL.path)
                    if let fileSize = attrs[.size] as? UInt64, fileSize > 0 {
                        await MainActor.run {
                            logOutput += "[\(index+1)/\(debURLs.count)] Skipping existing file: \(localRelativePath)\n"
                        }
                        continue
                    }
                } catch {
                    // ignore and proceed to download
                }
            }

            await MainActor.run {
                logOutput += "[\(index+1)/\(debURLs.count)] Downloading: \(localRelativePath)\n"
            }

            do {
                let fileData = try await fetchURL(debURL)
                try fileData.write(to: localFileURL)
                await MainActor.run {
                    logOutput += "Saved to \(localFileURL.path)\n"
                }
            } catch {
                await MainActor.run {
                    logOutput += "Failed to download \(debURL.absoluteString): \(error.localizedDescription)\n"
                    if errorOutput.isEmpty {
                        errorOutput = "Errors occurred during download. See log for details."
                    }
                }
            }
        }

        await MainActor.run {
            logOutput += "\nAll done. Your local mirror is at: \(repoPath.path)\n"
            logOutput += "Download complete.\n"
            isRunning = false
            downloadTask = nil
            isPaused = false
            showOpenFolderButton = (repoFolderURL != nil && fileManager.fileExists(atPath: repoFolderURL!.path))
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
    
    // Changed to return relative paths (String) instead of URLs
    func parsePackagesFile(_ data: Data) -> [String] {
        guard let content = String(data: data, encoding: .utf8) else { return [] }
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
    
    func openRepoFolder() {
        guard let url = repoFolderURL else { return }
        NSWorkspace.shared.open(url)
    }
    
    /// Recursively download all reachable files from a given base URL to the given destination directory (mimics wget -r)
    func recursiveMirrorRepo(from baseURL: URL, to localDir: URL) async {
        await MainActor.run { logOutput += "Packages files not found. Falling back to wget-style recursive mirror...\n" }
        
        // List of known index files to skip for recursion (already checked above)
        let skipFiles = Set(["Release", "Packages", "Packages.gz"])
        let fileManager = FileManager.default
        let session = URLSession.shared
        
        // Try to fetch index.html or directory file listing
        let indexFiles = ["index.html", "index.htm", "Index", ""]
        var foundListing = false
        for indexFile in indexFiles {
            let dirURL = indexFile.isEmpty ? baseURL : baseURL.appendingPathComponent(indexFile)
            do {
                let data = try await fetchURL(dirURL)
                if let html = String(data: data, encoding: .utf8) {
                    // Find all href links
                    let pattern = "href=\\\"([^\\\"]+)\\\""
                    let regex = try? NSRegularExpression(pattern: pattern)
                    let nsHtml = html as NSString
                    let matches = regex?.matches(in: html, range: NSRange(location: 0, length: nsHtml.length)) ?? []
                    var sublinks: [String] = []
                    for match in matches {
                        if let range = Range(match.range(at: 1), in: html) {
                            let href = String(html[range])
                            // Skip parent links
                            if href == "../" || href.hasPrefix("#") { continue }
                            // Avoid re-downloading index files
                            let lastComponent = URL(string: href)?.lastPathComponent ?? (href as NSString).lastPathComponent
                            if skipFiles.contains(lastComponent) { continue }
                            sublinks.append(href)
                        }
                    }
                    foundListing = true
                    for href in sublinks {
                        // Build new URL and local path
                        let subURL = URL(string: href, relativeTo: baseURL)?.absoluteURL ?? baseURL.appendingPathComponent(href)
                        let relativePath = subURL.path.replacingOccurrences(of: baseURL.path, with: "", options: .anchored)
                        let localFileURL = localDir.appendingPathComponent(relativePath)
                        if href.hasSuffix("/") {
                            // Recurse into subdirectory
                            do {
                                try fileManager.createDirectory(at: localFileURL, withIntermediateDirectories: true, attributes: nil)
                            } catch {}
                            await recursiveMirrorRepo(from: subURL, to: localFileURL)
                        } else {
                            // Download file
                            await MainActor.run { logOutput += "Recursively downloading: \(subURL.absoluteString)\n" }
                            do {
                                let fileData = try await fetchURL(subURL)
                                try fileData.write(to: localFileURL)
                                await MainActor.run { logOutput += "Saved recursively to \(localFileURL.path)\n" }
                            } catch {
                                await MainActor.run { logOutput += "Failed to download (recursive) \(subURL.absoluteString): \(error.localizedDescription)\n" }
                            }
                        }
                    }
                    break
                }
            } catch {
                // Ignore and try next index type
            }
        }
        if !foundListing {
            await MainActor.run { logOutput += "No directory listing found at \(baseURL.absoluteString), wget-style fallback could not enumerate subfiles.\n" }
        }
        await MainActor.run {
            logOutput += "Recursive mirror complete.\n"
            isRunning = false
            downloadTask = nil
            isPaused = false
            showOpenFolderButton = (repoFolderURL != nil && fileManager.fileExists(atPath: repoFolderURL!.path))
        }
    }
}

#Preview {
    ContentView()
}

