import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct LoadedLocalImage: Sendable {
    let data: Data
    let contentType: UTType
}

enum LocalImageLoader {
    static let maximumBytes = 20 * 1024 * 1024
    static let maximumPixels = 50_000_000
    static let maximumDimension = 20_000
    static let maximumFrames = 64

    static func load(from url: URL, within authorizedRoot: URL) throws -> LoadedLocalImage {
        let data = try boundedDataWithoutFollowingSymlinks(from: url, within: authorizedRoot)

        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let typeIdentifier = CGImageSourceGetType(source) as String?,
              let contentType = UTType(typeIdentifier),
              contentType.conforms(to: .image),
              !contentType.conforms(to: .svg) else {
            throw LocalImageError.unsupportedType
        }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0, frameCount <= maximumFrames else { throw LocalImageError.tooLarge }

        var totalPixels = 0
        for index in 0..<frameCount {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = number(properties[kCGImagePropertyPixelWidth]),
                  let height = number(properties[kCGImagePropertyPixelHeight]),
                  width > 0,
                  height > 0 else {
                throw LocalImageError.unsupportedType
            }
            guard width <= maximumDimension,
                  height <= maximumDimension else {
                throw LocalImageError.tooLarge
            }
            let (pixels, multiplicationOverflow) = width.multipliedReportingOverflow(by: height)
            let (newTotal, additionOverflow) = totalPixels.addingReportingOverflow(pixels)
            guard !multiplicationOverflow, !additionOverflow, newTotal <= maximumPixels else {
                throw LocalImageError.tooLarge
            }
            totalPixels = newTotal
        }

        return LoadedLocalImage(data: data, contentType: contentType)
    }

    private static func boundedDataWithoutFollowingSymlinks(from url: URL, within authorizedRoot: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw LocalImageError.notAFile }
        defer { Darwin.close(descriptor) }

        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &pathBuffer) == 0 else {
            throw LocalImageError.notAFile
        }
        let openedURL = URL(fileURLWithPath: String(cString: pathBuffer))
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let root = authorizedRoot.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard openedURL.path == root.path || openedURL.path.hasPrefix(rootPath) else {
            throw LocalImageError.outsideAuthorizedRoot
        }

        var fileStatus = stat()
        guard fstat(descriptor, &fileStatus) == 0,
              (fileStatus.st_mode & S_IFMT) == S_IFREG,
              fileStatus.st_size >= 0,
              fileStatus.st_size <= maximumBytes else {
            throw LocalImageError.tooLarge
        }

        let expectedCount = Int(fileStatus.st_size)
        var data = Data(count: expectedCount)
        var totalRead = 0
        var readError: Int32?

        data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            while totalRead < expectedCount {
                let count = Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: totalRead),
                    expectedCount - totalRead
                )
                if count > 0 {
                    totalRead += count
                } else if count == 0 {
                    break
                } else if errno != EINTR {
                    readError = errno
                    break
                }
            }
        }

        if let readError {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(readError))
        }
        if totalRead < data.count {
            data.removeSubrange(totalRead..<data.count)
        }
        return data
    }

    private static func number(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }
}

enum LocalImageError: Error {
    case notAFile
    case outsideAuthorizedRoot
    case tooLarge
    case unsupportedType
}
