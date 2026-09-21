//
//  contactsheetview.swift
//  QLVideo
//

import OSLog
import SwiftUI

struct ContactSheetView: View {

    @State private var viewModel: ContactSheetViewModel
    @State private var columnVisibility = NavigationSplitViewVisibility.detailOnly

    init(snapshotter: SnapShotter) {
        _viewModel = State(initialValue: ContactSheetViewModel(snapshotter: snapshotter))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(Array(viewModel.images.enumerated()), id: \.offset, selection: $viewModel.selectedIndex) { index, image in
                HDRImageView(image: image ?? NSImage())
                    .allowedDynamicRange(.constrainedHigh)
                    .aspectRatio(contentMode: .fit)
                    .listRowBackground(
                        index == viewModel.selectedIndex ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : Color.clear
                    ).frame(width: kThumbnailWidth).tag(index)
            }.frame(minWidth: kSidebarFrameWidth, idealWidth: kSidebarFrameWidth, maxWidth: kSidebarFrameWidth)
        } detail: {
            if viewModel.selectedIndex < viewModel.images.count,
                let image = viewModel.images[viewModel.selectedIndex]
            {
                HDRImageView(image: image).allowedDynamicRange(.high).aspectRatio(contentMode: .fit)
            }
        }
        .onChange(of: viewModel.images.count) { _, count in
            columnVisibility = count > 1 ? .all : .detailOnly
        }
        .task {
            await viewModel.load()
        }
    }
}

// Image doesn't seem to respond to .allowedDynamicRange on macOS 26, so wrap an NSImageView instead
struct HDRImageView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.image = image
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Self.NSViewType, context: Self.Context) -> CGSize? {
        #if DEBUG
            logger.debug(
                "sizeThatFits \(Int(image.size.width))x\(Int(image.size.height)) -> \(String(describing: proposal), privacy:. public)"
            )
        #endif
        if let width = proposal.width {
            return CGSize(width: width.rounded(), height: (width * image.size.height / image.size.width).rounded())
        } else {
            return nil
        }
    }
}

@Observable
class ContactSheetViewModel {
    let snapshotter: SnapShotter
    var images: [NSImage?] = []
    var selectedIndex: Int = 0

    init(snapshotter: SnapShotter) {
        self.snapshotter = snapshotter
        #if DEBUG
            logger.debug("ContactSheetViewModel init")
        #endif
    }

    deinit {
        #if DEBUG
            logger.debug("ContactSheetViewModel deinit")
        #endif
        avformat_close_input(&snapshotter.fmt_ctx)
    }

    func load() async {
        #if DEBUG
            logger.debug("ContactSheetViewModel load")
        #endif

        guard let fmt_ctx = snapshotter.fmt_ctx else { return }  // shouldn't happen

        // Find the best cover art stream.
        var artStream = -1
        var artPriority = 0
        for i in 0..<Int(fmt_ctx.pointee.nb_streams) {
            guard let stream = fmt_ctx.pointee.streams[i], let params = stream.pointee.codecpar else { continue }
            if (params.pointee.codec_id == AV_CODEC_ID_PNG || params.pointee.codec_id == AV_CODEC_ID_MJPEG)
                // Depending on codec and ffmpeg version cover art may be represented as attachment or as additional video stream(s)
                && (params.pointee.codec_type == AVMEDIA_TYPE_ATTACHMENT
                    || (params.pointee.codec_type == AVMEDIA_TYPE_VIDEO
                        && ((stream.pointee.disposition & (AV_DISPOSITION_ATTACHED_PIC | AV_DISPOSITION_TIMED_THUMBNAILS))
                            == AV_DISPOSITION_ATTACHED_PIC)))
            {
                // MKVs can contain multiple cover art - see https://www.matroska.org/technical/attachments.html
                // Prefer landscape
                var priority = 1
                if let nameDict = av_dict_get(stream.pointee.metadata, "filename", nil, 0) {
                    let filename = String(cString: nameDict.pointee.value)
                    if filename.lowercased().hasPrefix("cover.") {
                        priority = 3
                    } else if filename.lowercased().hasPrefix("cover_land.") {
                        priority = 4
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

        // Add cover art as first image
        if artStream >= 0 {
            let stream = fmt_ctx.pointee.streams[artStream]!
            let params = stream.pointee.codecpar!
            if let image = await Task.detached(
                priority: .userInitiated,
                operation: {
                    if let provider = CGDataProvider(
                        data: stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC != 0
                            ? NSData(bytes: stream.pointee.attached_pic.data, length: Int(stream.pointee.attached_pic.size))
                            : NSData(bytes: params.pointee.extradata, length: Int(params.pointee.extradata_size))  // attachment stream
                    ),
                        let image = params.pointee.codec_id == AV_CODEC_ID_PNG
                            ? CGImage(
                                pngDataProviderSource: provider,
                                decode: nil,
                                shouldInterpolate: false,
                                intent: .defaultIntent
                            )
                            : CGImage(
                                jpegDataProviderSource: provider,
                                decode: nil,
                                shouldInterpolate: false,
                                intent: .defaultIntent
                            )
                    {
                        return image
                    } else {
                        return nil
                    }
                }
            ).value {
                images.append(NSImage(cgImage: image, size: .zero))
            }
        }

        let snapshotter = snapshotter  // use a local reference so Tasks below can run off the main thread

        // Is best stream just timed thumbnails? We see this with .m4v files with DRM
        if snapshotter.stream.pointee.disposition == (AV_DISPOSITION_ATTACHED_PIC | AV_DISPOSITION_TIMED_THUMBNAILS) {
            for i in 0..<snapshotter.stream.pointee.nb_frames {
                if let image = await Task.detached(
                    priority: .userInitiated,
                    operation: {
                        return snapshotter.generateSnapshot(snapshotTime: -1)
                    }
                ).value {
                    if i > 0 {  // First image seems to be repeated
                        images.append(NSImage(cgImage: image, size: .zero))
                    }
                }
            }
        } else if snapshotter.duration < kMinimumDuration {
            if let image = await Task.detached(
                priority: .userInitiated,
                operation: {
                    return snapshotter.generateSnapshot(snapshotTime: -1)
                }
            ).value {
                images.append(NSImage(cgImage: image, size: .zero))
            }
        } else {
            let imageCount = max(
                1,
                min(kDefaultSnapshotCount, Int((snapshotter.duration / kMinimumPeriod).rounded(.down)) - 1)
            )
            #if DEBUG
                logger.debug("generating \(imageCount) snapshots")
            #endif

            for i in 1...imageCount {
                let snapshotTime = Double(i) / Double(imageCount + 1)  // fenceposts!
                if let image = await Task.detached(
                    priority: .userInitiated,
                    operation: {
                        return snapshotter.generateSnapshot(snapshotTime: snapshotTime)
                    }
                ).value {
                    images.append(NSImage(cgImage: image, size: .zero))
                }

            }
        }
    }
}
