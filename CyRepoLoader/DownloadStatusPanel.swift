import SwiftUI

struct DownloadStatusPanel: View {
    let phase: String
    let isRunning: Bool
    let progress: Double
    let filesDownloaded: Int
    let filesTotal: Int
    let recursiveFilesDownloaded: Int
    let recursiveFilesTotal: Int
    let errorMessage: String
    let summary: String?

    private var status: DownloadStatusPresentation {
        DownloadStatusPresentation(
            phase: phase,
            isRunning: isRunning,
            errorMessage: errorMessage,
            summary: summary
        )
    }

    private var displayedProgress: Double {
        if recursiveFilesTotal > 0 {
            return clamped(Double(recursiveFilesDownloaded) / Double(recursiveFilesTotal))
        }
        if filesTotal > 0 {
            return clamped(progress)
        }
        return status.kind == .complete ? 1.0 : 0.0
    }

    private var progressText: String {
        if recursiveFilesTotal > 0 {
            return "\(recursiveFilesDownloaded) of \(recursiveFilesTotal) additional files"
        }
        if filesTotal > 0 {
            return "\(filesDownloaded) of \(filesTotal) packages"
        }
        return status.kind.shortLabel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: status.kind.systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(status.kind.tint)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(status.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(status.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Text(status.kind.shortLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(status.kind.tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(status.kind.tint.opacity(0.12))
                    .clipShape(Capsule())
            }

            ProgressView(value: displayedProgress)
                .progressViewStyle(.linear)
                .tint(status.kind.tint)

            HStack(spacing: 8) {
                StatusMetric(label: "Progress", value: progressText)

                if isRunning {
                    StatusMetric(label: "Mode", value: recursiveFilesTotal > 0 ? "Additional files" : "Packages")
                } else if status.kind == .complete {
                    StatusMetric(label: "Result", value: "Ready")
                } else if status.kind == .failed {
                    StatusMetric(label: "Result", value: "Needs attention")
                }
            }
        }
        .padding(12)
        .background(.regularMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(status.kind.tint.opacity(0.22), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.vertical, 8)
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0.0), 1.0)
    }
}

private struct StatusMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct DownloadStatusPresentation {
    let kind: DownloadStatusKind
    let title: String
    let detail: String

    init(phase: String, isRunning: Bool, errorMessage: String, summary: String?) {
        let normalizedPhase = phase.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasError = !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if normalizedPhase == "Download complete" {
            kind = .complete
            title = "Download complete"
            detail = summary?.isEmpty == false ? "Finished with notes. Open Full Log for details." : "Repo mirror finished successfully."
        } else if normalizedPhase == "Download cancelled" {
            kind = .cancelled
            title = "Download cancelled"
            detail = "The current mirror task was stopped."
        } else if normalizedPhase == "Error" || hasError {
            kind = .failed
            title = "Needs attention"
            detail = errorMessage.isEmpty ? "Something went wrong. Open Full Log for details." : errorMessage
        } else if normalizedPhase.localizedCaseInsensitiveContains("metadata") {
            kind = .working
            title = "Finding repo metadata"
            detail = "Looking for Release and Packages files."
        } else if normalizedPhase.localizedCaseInsensitiveContains("parsing") {
            kind = .working
            title = "Reading package list"
            detail = "Parsing metadata and preparing package downloads."
        } else if normalizedPhase.localizedCaseInsensitiveContains("additional") {
            kind = .working
            title = "Mirroring additional files"
            detail = "Downloading icons, depictions, and other repo assets."
        } else if normalizedPhase.localizedCaseInsensitiveContains("download") {
            kind = .working
            title = "Downloading packages"
            detail = "Saving package files into the selected folder."
        } else if normalizedPhase.localizedCaseInsensitiveContains("validating") {
            kind = .working
            title = "Checking setup"
            detail = "Validating the repo URL and destination folder."
        } else if isRunning {
            kind = .working
            title = normalizedPhase.isEmpty ? "Preparing download" : normalizedPhase
            detail = "Working through the current repo step."
        } else {
            kind = .idle
            title = "Ready"
            detail = "Choose a repo and destination to start."
        }
    }
}

private enum DownloadStatusKind {
    case idle
    case working
    case complete
    case failed
    case cancelled

    var systemImage: String {
        switch self {
        case .idle:
            return "tray"
        case .working:
            return "arrow.down.circle"
        case .complete:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .cancelled:
            return "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .idle:
            return .secondary
        case .working:
            return .accentColor
        case .complete:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .orange
        }
    }

    var shortLabel: String {
        switch self {
        case .idle:
            return "Ready"
        case .working:
            return "Running"
        case .complete:
            return "Done"
        case .failed:
            return "Issue"
        case .cancelled:
            return "Stopped"
        }
    }
}
