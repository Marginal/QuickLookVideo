//
//  cmtime.swift
//  QLVideo
//
//  Created by Jonathan Harris on 24/01/2026.
//

import CoreMedia

// Selected FFmpeg constants that we need but that Swift bridging can't figure out
nonisolated let AV_NOPTS_VALUE: Int64 = Int64.min

extension CMTime: @retroactive CustomStringConvertible {

    // Convert AVPacket timestamps into CMTime
    init(value: Int64, timeBase: AVRational) {
        self.init()
        if value == AV_NOPTS_VALUE || timeBase.den == 0 {
            self = CMTime.invalid
            self.timescale = timeBase.den
        } else {
            self = CMTime(value: value * Int64(timeBase.num), timescale: timeBase.den)
        }
    }

    // For logging
    public var description: String {
        if !self.isValid {
            return "invalid"
        } else if self.isNegativeInfinity {
            return "-inf"
        } else if self.isPositiveInfinity {
            return "+inf"
        } else if self.isIndefinite {
            return "indefinite"
        } else {
            return "\(self.value)/\(self.timescale)"
        }
    }
}
