import Foundation
import ImageIO

enum RecoveredFileValidator {
    static func validate(_ files: [RecoveredFile]) -> [RecoveredFile] {
        files.map(validate)
    }

    static func validate(_ file: RecoveredFile) -> RecoveredFile {
        switch file.kind {
        case .jpeg:
            validateJPEG(file)
        case .rawOrTIFF:
            validateRawOrTIFF(file)
        case .other:
            file
        }
    }

    private static func validateJPEG(_ file: RecoveredFile) -> RecoveredFile {
        var validated = file
        guard containsJPEGEndMarker(at: file.url),
              let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCache: true] as CFDictionary
              ) != nil,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            validated.validationStatus = .possiblyPartial
            return validated
        }

        validated.validationStatus = .readable
        return validated
    }

    private static func validateRawOrTIFF(_ file: RecoveredFile) -> RecoveredFile {
        // ImageIO support varies by macOS version and camera model. A format that
        // this Mac cannot open remains explicitly unchecked rather than being
        // mislabeled as damaged.
        guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil) else {
            return file
        }

        var validated = file
        guard CGImageSourceGetCount(source) > 0 else {
            validated.validationStatus = .possiblyPartial
            return validated
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_024,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            validated.validationStatus = .possiblyPartial
            return validated
        }

        validated.validationStatus = .previewReadable
        return validated
    }

    private static func containsJPEGEndMarker(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 4 else {
            return false
        }
        return data.range(of: Data([0xFF, 0xD9]), options: .backwards) != nil
    }
}

enum RecoveryExporter {
    enum ExportError: LocalizedError {
        case noFilesSelected
        case destinationIsNotWritable
        case sourceIsMissing(String)

        var errorDescription: String? {
            switch self {
            case .noFilesSelected:
                "Select at least one recovered file to export."
            case .destinationIsNotWritable:
                "Choose a writable export folder."
            case .sourceIsMissing(let name):
                "The recovered file “\(name)” is no longer available in the session folder."
            }
        }
    }

    static func export(
        _ files: [RecoveredFile],
        to destinationDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        guard !files.isEmpty else { throw ExportError.noFilesSelected }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destinationDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isWritableFile(atPath: destinationDirectory.path) else {
            throw ExportError.destinationIsNotWritable
        }

        var exportedURLs: [URL] = []
        for file in files {
            guard fileManager.isReadableFile(atPath: file.path) else {
                throw ExportError.sourceIsMissing(file.name)
            }

            let destination = availableDestination(
                for: file.name,
                in: destinationDirectory,
                fileManager: fileManager
            )
            try fileManager.copyItem(at: file.url, to: destination)
            exportedURLs.append(destination)
        }
        return exportedURLs
    }

    private static func availableDestination(
        for filename: String,
        in directory: URL,
        fileManager: FileManager
    ) -> URL {
        let requested = directory.appendingPathComponent(filename, isDirectory: false)
        guard fileManager.fileExists(atPath: requested.path) else { return requested }

        let sourceURL = URL(fileURLWithPath: filename)
        let fileExtension = sourceURL.pathExtension
        let basename = sourceURL.deletingPathExtension().lastPathComponent
        var suffix = 2

        while true {
            let candidateName = fileExtension.isEmpty
                ? "\(basename) \(suffix)"
                : "\(basename) \(suffix).\(fileExtension)"
            let candidate = directory.appendingPathComponent(candidateName, isDirectory: false)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            suffix += 1
        }
    }
}
