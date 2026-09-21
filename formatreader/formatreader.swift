//
//  formatreader.swift
//  QLVideo
//

import Foundation
import MediaExtension

let kSettingsSnapshotTime = "SnapshotPercentage"  // Seek offset for thumbnails and single Previews [s].
let kDefaultSnapshotTime = 0.25

class FormatReader: NSObject, MEFormatReader {

    // From metadata tags - see avformat.h
    // https://wiki.multimedia.cx/index.php/FFmpeg_Metadata
    // https://nonstrict.eu/blog/2023/working-with-custom-metadata-in-mp4-files/
    // https://exiftool.org/TagNames/QuickTime.html
    // https://id3.org/id3v2.4.0-frames
    static let identifiers: [String: (AVMetadataKeySpace, AVMetadataIdentifier)] = [
        "album": (.common, .commonIdentifierAlbumName),
        "artist": (.common, .commonIdentifierArtist),
        "author": (.common, .commonIdentifierAuthor),
        "comment": (.common, .quickTimeMetadataComment),
        "composer": (.common, .quickTimeMetadataComposer),
        "copyright": (.common, .commonIdentifierCopyrights),
        "creation_time": (.common, .commonIdentifierCreationDate),
        "date": (.common, .commonIdentifierCreationDate),
        "description": (.common, .commonIdentifierDescription),
        "encoded_by": (.common, .commonIdentifierSoftware),
        "encoder": (.common, .commonIdentifierSoftware),
        "genre": (.quickTimeMetadata, .quickTimeMetadataGenre),
        "grouping": (.iTunes, .iTunesMetadataGrouping),
        "keywords": (.quickTimeMetadata, .quickTimeMetadataKeywords),
        "language": (.common, .commonIdentifierLanguage),
        "location": (.common, .commonIdentifierLocation),
        "performer": (.quickTimeMetadata, .quickTimeMetadataPerformer),
        "publisher": (.common, .commonIdentifierPublisher),
        "service_name": (.common, .commonIdentifierSource),  // e.g. TV channel
        "service_provider": (.common, .commonIdentifierSource),  // e.g. TV station
        //"show":                // e.g. TV show
        "synopsis": (.quickTimeMetadata, .quickTimeMetadataInformation),
        "title": (.common, .commonIdentifierTitle),
        "track": (.iTunes, .iTunesMetadataTrackNumber),
    ]

    @objc let byteSource: MEByteSource
    @objc var avio_filepos: Int64 = 0
    var trackReaders = NSHashTable<TrackReader>.weakObjects()  // for dumpState()
    var avio_ctx: UnsafeMutablePointer<AVIOContext>? = nil
    var defaults: UserDefaults?
    var fmt_ctx: UnsafeMutablePointer<AVFormatContext>? = nil
    var fmt_ctxLock = NSLock()
    var demuxer: PacketDemuxer? = nil
    var snapshotTime = kDefaultSnapshotTime
    var loadUneditedDurationCalled = false  // workaround for macOS 26.4 snaphsot time
    var metadata: [AVMetadataItem]?  // cached since AVFoundation typically requests it multiple times
    var bestAudio = AVERROR_STREAM_NOT_FOUND
    var bestVideo = AVERROR_STREAM_NOT_FOUND

    init(primaryByteSource: MEByteSource) {
        byteSource = primaryByteSource
        let myBundle = Bundle.main
        let suiteName: String = myBundle.infoDictionary!["ApplicationGroup"] as! String
        defaults = UserDefaults(suiteName: suiteName)
        if let defaults, defaults.object(forKey: kSettingsSnapshotTime) != nil {
            // Note that since this extension is running under app sandbox this should only succeed once notarized. But in practice on macOS 26 not even then.
            // https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox#Share-files-between-related-apps-with-app-group-containers
            snapshotTime = defaults.double(forKey: kSettingsSnapshotTime)
            logger.log("Using snapshot percentage of \(Int(self.snapshotTime * 100))%")
        } else {
            logger.log("Using default snapshot time ")
        }
        super.init()
    }

    deinit {
        logger.debug("FormatReader deinit")
        if let demuxer {
            demuxer.stop()
            demuxer.join()  // ensure demuxer threads have exited before destroying fmt_ctx
        }
        if fmt_ctx != nil { avformat_close_input(&fmt_ctx) }
        if let avio_ctx {
            avio_ctx.pointee.opaque = nil  // otherwise avio_close() tries to free it
            avio_close(avio_ctx)  // also frees the underlying buffer
        }
    }

    func loadFileInfo(completionHandler: @escaping @Sendable (MEFileInfo?, (any Error)?) -> Void) {
        // We can't read using MEByteSource.fileName, so set up an AVIOContext which uses MEByteSource.read
        // See "Opening a media file" https://ffmpeg.org/doxygen/8.0/group__lavf__decoding.html
        var buf: UnsafeMutableRawPointer? = nil
        posix_memalign(&buf, 16384, 16384)  // 1 ARM page. Will be freed by avio_close()
        avio_ctx = avio_alloc_context(
            buf,
            16384,
            0,  // not writable
            Unmanaged.passUnretained(self).toOpaque(),
            MEByteSource_read_packet,
            nil,
            MEByteSource_seek
        )
        fmt_ctx = avformat_alloc_context()
        fmt_ctx!.pointee.pb = avio_ctx
        fmt_ctx!.pointee.flags |= AVFMT_FLAG_GENPTS  // AVFoundation requires PTS values. Some formats e.g. AVI don't contain them
        var ret = avformat_open_input(&fmt_ctx, byteSource.fileName, nil, nil)
        guard ret == 0 else {
            let err = AVERROR(errorCode: ret, context: "avformat_open_input", file: byteSource.fileName)
            #if DEBUG
                logger.error(
                    "FormatReader can't open \(self.byteSource.fileName, privacy:.public): \(err.errorDescription, privacy:.public)"
                )
            #else
                logger.error(
                    "FormatReader can't open \(self.byteSource.fileName, privacy:.private(mask:.hash)): \(err.errorDescription, privacy:.public)"
                )
            #endif
            return completionHandler(nil, err)
        }

        // Read ahead if necessary to populate info like codec parameters that otherwise might not be available
        fmt_ctx!.pointee.max_analyze_duration = Int64(5 * AV_TIME_BASE)  // 5s
        fmt_ctx!.pointee.probesize = 10 * 1024 * 1024  // 10MB
        ret = avformat_find_stream_info(fmt_ctx, nil)
        guard ret == 0 else {
            let err = AVERROR(errorCode: ret, context: "avformat_find_stream_info", file: byteSource.fileName)
            #if DEBUG
                logger.error(
                    "FormatReader can't read stream info from \(self.byteSource.fileName, privacy:.public): \(err.errorDescription, privacy:.public)"
                )
            #else
                logger.error(
                    "FormatReader can't read stream info from \(self.byteSource.fileName, privacy:.private(mask:.hash)): \(err.errorDescription, privacy:.public)"
                )
            #endif
            if fmt_ctx != nil { avformat_close_input(&fmt_ctx) }
            return completionHandler(nil, err)
        }

        // Determine best streams and disable others
        var decoder: UnsafePointer<AVCodec>?
        bestVideo = av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_VIDEO, -1, -1, &decoder, 0)
        bestAudio = av_find_best_stream(fmt_ctx, AVMEDIA_TYPE_AUDIO, -1, -1, &decoder, 0)
        if bestVideo < 0
            || fmt_ctx!.pointee.streams[Int(bestVideo)]!.pointee.disposition
                & (AV_DISPOSITION_ATTACHED_PIC | AV_DISPOSITION_TIMED_THUMBNAILS) != 0
        {
            bestVideo = AVERROR_STREAM_NOT_FOUND  // If the best video stream is pictures then we don't have a viable video stream
        }
        for i in 0..<Int(fmt_ctx!.pointee.nb_streams) {
            if i != bestVideo && i != bestAudio {
                // Packets won't be consumed from non-enabled streams so discard all packets so demux doesn't stall
                // TODO: Revisit PacketDemuxer eviction policy if we get multiple audio tracks working
                fmt_ctx!.pointee.streams[i]!.pointee.discard = AVDISCARD_ALL
            }
        }

        let fileInfo = MEFileInfo()
        fileInfo.duration = CMTime(value: fmt_ctx!.pointee.duration, timescale: AV_TIME_BASE)
        fileInfo.fragmentsStatus = .couldNotContainFragments
        completionHandler(fileInfo, nil)
    }

    func loadMetadata(completionHandler: @escaping @Sendable ([AVMetadataItem]?, (any Error)?) -> Void) {
        guard fmt_ctx != nil else { return completionHandler(nil, MEError(.parsingFailure)) }  // we can be called even if we couldn't open the file
        if let metadata { return completionHandler(metadata, nil) }  // early return
        metadata = []
        var prev: UnsafeMutablePointer<AVDictionaryEntry>? = nil
        while let entry = av_dict_get(fmt_ctx!.pointee.metadata, "", prev, AV_DICT_IGNORE_SUFFIX) {
            prev = entry
            if let (keySpace, identifier) = FormatReader.identifiers[String(cString: entry.pointee.key).lowercased()],
                var lvalue = String(validatingUTF8: entry.pointee.value),
                lvalue != "" && lvalue.lowercased() != "und", lvalue.lowercased() != "unk"
            {
                if identifier == .commonIdentifierLanguage { lvalue = Locale.canonicalLanguageIdentifier(from: lvalue) }
                let item = AVMutableMetadataItem()
                item.keySpace = keySpace
                item.identifier = identifier
                item.dataType = String(kCMMetadataBaseDataType_UTF8)
                item.value = lvalue as NSString
                metadata!.append(item)
            } else {
                logger.debug(
                    "Unrecognised metadata key:\(String(cString:entry.pointee.key), privacy:.public) = \"\(String(validatingUTF8: entry.pointee.value) ?? "", privacy:.public)\""
                )
            }
        }

        // Find the best cover art stream.
        var artStream = -1
        var artPriority = 0
        for i in 0..<Int(fmt_ctx!.pointee.nb_streams) {
            guard let stream = fmt_ctx!.pointee.streams[i], let params = stream.pointee.codecpar else { continue }
            if (params.pointee.codec_id == AV_CODEC_ID_PNG || params.pointee.codec_id == AV_CODEC_ID_MJPEG)
                // Depending on codec and ffmpeg version cover art may be represented as attachment or as additional video stream(s)
                && (params.pointee.codec_type == AVMEDIA_TYPE_ATTACHMENT
                    || (params.pointee.codec_type == AVMEDIA_TYPE_VIDEO
                        && ((stream.pointee.disposition & (AV_DISPOSITION_ATTACHED_PIC | AV_DISPOSITION_TIMED_THUMBNAILS))
                            == AV_DISPOSITION_ATTACHED_PIC)))
            {
                // MKVs can contain multiple cover art - see https://www.matroska.org/technical/attachments.html
                // Prefer portrait
                var priority = 1
                if let nameDict = av_dict_get(stream.pointee.metadata, "filename", nil, 0) {
                    let filename = String(cString: nameDict.pointee.value)
                    if filename.lowercased().hasPrefix("cover.") {
                        priority = 4
                    } else if filename.lowercased().hasPrefix("cover_land.") {
                        priority = 3
                    } else if filename.lowercased().hasPrefix("small_cover.") {
                        priority = 2
                    }
                }
                if priority > artPriority  // Prefer first if multiple with same priority
                {
                    artPriority = priority
                    artStream = i
                }
            }
        }
        if artStream >= 0,
            // Found at least one cover art
            let stream = fmt_ctx!.pointee.streams[artStream],
            let params = stream.pointee.codecpar,
            let provider = CGDataProvider(
                data: stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC != 0
                    ? NSData(bytes: stream.pointee.attached_pic.data, length: Int(stream.pointee.attached_pic.size))
                    : NSData(bytes: params.pointee.extradata, length: Int(params.pointee.extradata_size))  // attachment stream
            ),
            (params.pointee.codec_id == AV_CODEC_ID_PNG
                ? CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
                : CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
                != nil  // supplying cover art suppresses a psuedo artwork thumbnail, so better validate it
        {
            let item = AVMutableMetadataItem()
            item.keySpace = .common
            item.identifier = .commonIdentifierArtwork
            item.dataType =
                (params.pointee.codec_id == AV_CODEC_ID_PNG ? kCMMetadataBaseDataType_PNG : kCMMetadataBaseDataType_JPEG)
                as String
            item.value = provider.data! as NSData
            metadata!.append(item)
            logger.debug(
                "Found \(params.pointee.width)x\(params.pointee.height) cover art in stream \(artStream): \(String(describing: item), privacy: .public)"
            )
        } else {
            // Generate pseudo artwork for the thumbnail.
            // If demuxing has started we're too late, but we probably don't need this anyway
            fmt_ctxLock.lock()
            if demuxer == nil, bestVideo != AVERROR_STREAM_NOT_FOUND,
                let snapshotter = SnapShotter(fmt_ctx: fmt_ctx!, stream: fmt_ctx!.pointee.streams[Int(bestVideo)]!),
                let image = snapshotter.generateSnapshot(snapshotTime: snapshotTime),
                let data = CFDataCreateMutable(kCFAllocatorDefault, 0),
                let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)  // Can't encode as HEIC since that requires HEVC codec which isn't available
            {
                CGImageDestinationAddImage(destination, image, nil)
                if CGImageDestinationFinalize(destination) {
                    let item = AVMutableMetadataItem()
                    item.keySpace = .common
                    item.identifier = .commonIdentifierArtwork
                    item.dataType = kCMMetadataBaseDataType_PNG as String
                    item.value = data as NSData
                    metadata!.append(item)
                    logger.debug("Added snapshot as cover art")
                } else {
                    logger.debug("Failed to encode snapshot as cover art")
                }
            }
            fmt_ctxLock.unlock()
        }

        let summary = metadata!.reduce(
            "Metadata:",
            { a, b in
                "\(a)\n\(b.identifier!.rawValue): \([kCMMetadataBaseDataType_PNG as String, kCMMetadataBaseDataType_JPEG as String].contains(b.dataType!) ? "\(b.dataType!) length=\((b.value as! NSData).length)" : String(describing: b.value!))"
            }
        )
        logger.info("\(summary, privacy: .public)")
        return completionHandler(metadata, nil)
    }

    func loadTrackReaders(completionHandler: @escaping @Sendable ([any METrackReader]?, (any Error)?) -> Void) {
        guard fmt_ctx != nil else { return completionHandler(nil, MEError(.parsingFailure)) }  // we can be called even if we couldn't open the file
        var readers: [METrackReader] = []

        for i in 0..<Int(fmt_ctx!.pointee.nb_streams) {
            let stream = fmt_ctx!.pointee.streams[i]!
            let params = stream.pointee.codecpar!

            // Only add supported stream types
            switch params.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO:
                if i == bestVideo {  // We only support one video stream
                    readers.append(VideoTrackReader(format: self, stream: stream, index: i, enabled: true))
                }

            case AVMEDIA_TYPE_AUDIO:
                if i == bestAudio {  // AVFoundation will try to seek the first audio stream, even if enabled==false and so we've discarded it
                    readers.append(AudioTrackReader(format: self, stream: stream, index: i, enabled: true))
                }

            //case AVMEDIA_TYPE_SUBTITLE:
            //    readers.append(SubtitleTrackReader(format: self, stream: stream, index: i, enabled: besties.contains(i)))

            //case AVMEDIA_TYPE_ATTACHMENT:
            //    let codec_id = stream.pointee.codecpar.pointee.codec_id
            //    if [AV_CODEC_ID_PNG, AV_CODEC_ID_MJPEG].contains(codec_id) {
            //        readers.append(ArtTrackReader(format: self, stream: stream, index: i, enabled: false))
            //    } else {
            //        let cd = avcodec_descriptor_get(codec_id)
            //        logger.warning(
            //            "Unhandled attachment of type \"\(String(cString:cd.codec_long_name ?? cd.codec_name!))\""
            //        )
            //    }

            default:
                logger.info(
                    "Unhandled \(String(cString:av_get_media_type_string(params.pointee.codec_type)), privacy:.public) stream: \(String(cString:avcodec_get_name(params.pointee.codec_id)), privacy:.public)"
                )
            }
        }

        for reader in readers { trackReaders.add(reader as? TrackReader) }
        completionHandler(readers, nil)
    }
}
