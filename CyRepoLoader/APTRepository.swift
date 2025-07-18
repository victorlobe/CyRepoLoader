import Foundation
import Compression

// MARK: - Model
struct APTPackage {
    let name: String
    let version: String
    let depends: [String]
    let description: String
}

// MARK: - Repository Reader
class APTRepository {
    /// URL to Packages.gz file in the repo
    private let packagesURL: URL

    init(packagesURL: URL) {
        self.packagesURL = packagesURL
    }

    /// Loads and parses all packages
    func fetchPackages(completion: @escaping (Result<[APTPackage], Error>) -> Void) {
        let task = URLSession.shared.dataTask(with: packagesURL) { data, _, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard
                let compressed = data,
                let decompressed = self.decompressGzip(data: compressed),
                let text = String(data: decompressed, encoding: .utf8)
            else {
                completion(.failure(ParseError.decompressionFailed))
                return
            }

            let packages = self.parsePackages(from: text)
            completion(.success(packages))
        }
        task.resume()
    }

    /// Decompresses GZIP data using the Compression framework
    private func decompressGzip(data: Data) -> Data? {
        var dstBuffer = Data(count: 10 * data.count)
        let dstBufferCount = dstBuffer.count
        let decompressedSize = dstBuffer.withUnsafeMutableBytes { dstPtr in
            data.withUnsafeBytes { srcPtr in
                compression_decode_buffer(
                    dstPtr.bindMemory(to: UInt8.self).baseAddress!,
                    dstBufferCount,
                    srcPtr.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard decompressedSize > 0 else { return nil }
        return dstBuffer.prefix(decompressedSize)
    }

    /// Parses text into APTPackage models
    private func parsePackages(from text: String) -> [APTPackage] {
        let entries = text.components(separatedBy: "\n\n")
        return entries.compactMap { entry in
            var dict = [String:String]()
            entry.split(separator: "\n").forEach { line in
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return }
                dict[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
            }
            guard
                let name = dict["Package"],
                let version = dict["Version"],
                let desc = dict["Description"]
            else { return nil }

            let deps = dict["Depends"]?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? []

            return APTPackage(name: name, version: version, depends: deps, description: desc)
        }
    }

    enum ParseError: Error {
        case decompressionFailed
    }
}
