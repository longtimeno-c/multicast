import AudioToolbox
import AVFoundation
import Foundation

/// Tags read from an audio file.
public struct AudioMetadata: Sendable, Codable, Equatable {
    public var title: String?
    public var artist: String?
    public var album: String?
    /// Encoded image bytes (JPEG/PNG) of the embedded cover art, if any.
    public var artworkData: Data?

    public init(title: String? = nil, artist: String? = nil, album: String? = nil, artworkData: Data? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkData = artworkData
    }

    /// MIME type sniffed from `artworkData`'s magic bytes.
    public var artworkMIMEType: String? {
        guard let d = artworkData else { return nil }
        return ArtworkSniffer.mimeType(of: d)
    }

    /// Fills fields that are nil in `self` from `other`.
    public func filling(from other: AudioMetadata) -> AudioMetadata {
        AudioMetadata(
            title: title ?? other.title,
            artist: artist ?? other.artist,
            album: album ?? other.album,
            artworkData: artworkData ?? other.artworkData
        )
    }

    var isComplete: Bool { title != nil && artist != nil && album != nil && artworkData != nil }
}

public enum ArtworkSniffer {
    public static func mimeType(of data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "image/jpeg" }
        if b.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "image/png" }
        if b.count >= 6, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "image/gif" }
        if b.count >= 2, b[0] == 0x42, b[1] == 0x4D { return "image/bmp" }
        if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { return "image/webp" }
        if b.count >= 12, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 { return "image/heic" }
        return nil
    }
}

enum MetadataReader {
    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// Synchronous, via AudioToolbox's info dictionary (works for mp3/m4a/aiff/wav/flac…).
    static func audioFileMetadata(url: URL) -> AudioMetadata {
        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let fileID else {
            return AudioMetadata()
        }
        defer { AudioFileClose(fileID) }
        var meta = AudioMetadata()

        var dict: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        if AudioFileGetProperty(fileID, kAudioFilePropertyInfoDictionary, &size, &dict) == noErr,
           let info = dict?.takeRetainedValue() as? [String: Any] {
            meta.title = clean(info[kAFInfoDictionary_Title] as? String)
            meta.artist = clean(info[kAFInfoDictionary_Artist] as? String)
            meta.album = clean(info[kAFInfoDictionary_Album] as? String)
        }

        var art: Unmanaged<CFData>?
        var artSize = UInt32(MemoryLayout<Unmanaged<CFData>?>.size)
        if AudioFileGetProperty(fileID, kAudioFilePropertyAlbumArtwork, &artSize, &art) == noErr,
           let data = art?.takeRetainedValue() as Data?, !data.isEmpty {
            meta.artworkData = data
        }
        return meta
    }

    /// Asynchronous, via AVFoundation common metadata (ID3, iTunes, QuickTime, Vorbis comments).
    static func assetMetadata(url: URL) async -> AudioMetadata {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return AudioMetadata() }
        var meta = AudioMetadata()
        for item in items {
            guard let key = item.commonKey else { continue }
            switch key {
            case .commonKeyTitle:
                if meta.title == nil { meta.title = clean(try? await item.load(.stringValue)) }
            case .commonKeyArtist:
                if meta.artist == nil { meta.artist = clean(try? await item.load(.stringValue)) }
            case .commonKeyAlbumName:
                if meta.album == nil { meta.album = clean(try? await item.load(.stringValue)) }
            case .commonKeyArtwork:
                if meta.artworkData == nil {
                    if let d = try? await item.load(.dataValue), !d.isEmpty {
                        meta.artworkData = d
                    }
                }
            default:
                break
            }
        }
        return meta
    }
}
