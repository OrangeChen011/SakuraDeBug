//
//  IPAImportService.swift
//  SakuraDeBug
//

import Foundation

enum IPAImportError: LocalizedError {
    case invalidFile
    case copyFailed

    var errorDescription: String? {
        switch self {
        case .invalidFile:
            return "请选择有效的 .ipa 文件。"
        case .copyFailed:
            return "无法读取所选 IPA 文件。"
        }
    }
}

enum IPAImportService {
    static func importIPA(from url: URL) throws -> URL {
        guard url.pathExtension.lowercased() == "ipa" else {
            throw IPAImportError.invalidFile
        }

        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { url.stopAccessingSecurityScopedResource() }
        }

        guard let handle = try? FileHandle(forReadingFrom: url),
              handle.readData(ofLength: 2) == Data([0x50, 0x4B]) else {
            throw IPAImportError.invalidFile
        }
        try? handle.close()

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("SakuraDeBug-\(UUID().uuidString).ipa")
        do {
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            throw IPAImportError.copyFailed
        }
    }
}