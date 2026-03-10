import CoreGraphics
import Foundation

struct MoveEverythingRetileLayout {
    struct GridCandidate: Equatable {
        let rows: Int
        let columns: Int
        let tileWidth: CGFloat
        let tileHeight: CGFloat
        let aspectDelta: CGFloat
        let usedArea: CGFloat
    }

    static func availableFrame(
        within available: CGRect,
        excluding occupied: CGRect?,
        edgeTolerance: CGFloat = 24,
        minimumRemainingWidth: CGFloat = 240
    ) -> CGRect {
        let normalizedAvailable = available.integral
        guard let occupied else {
            return normalizedAvailable
        }

        let intersection = occupied.intersection(normalizedAvailable)
        guard !intersection.isNull, !intersection.isEmpty else {
            return normalizedAvailable
        }

        if intersection.minX <= normalizedAvailable.minX + edgeTolerance {
            let minX = min(max(intersection.maxX, normalizedAvailable.minX), normalizedAvailable.maxX)
            let width = normalizedAvailable.maxX - minX
            if width >= minimumRemainingWidth {
                return CGRect(
                    x: minX,
                    y: normalizedAvailable.minY,
                    width: width,
                    height: normalizedAvailable.height
                ).integral
            }
        }

        if intersection.maxX >= normalizedAvailable.maxX - edgeTolerance {
            let maxX = max(min(intersection.minX, normalizedAvailable.maxX), normalizedAvailable.minX)
            let width = maxX - normalizedAvailable.minX
            if width >= minimumRemainingWidth {
                return CGRect(
                    x: normalizedAvailable.minX,
                    y: normalizedAvailable.minY,
                    width: width,
                    height: normalizedAvailable.height
                ).integral
            }
        }

        return normalizedAvailable
    }

    static func bestGrid(
        count: Int,
        availableFrame: CGRect,
        aspectRatio: CGFloat,
        gap: CGFloat
    ) -> GridCandidate? {
        guard count > 0,
              availableFrame.width > 0,
              availableFrame.height > 0,
              aspectRatio > 0 else {
            return nil
        }

        let normalizedGap = max(gap, 0)
        var best: GridCandidate?
        for rows in 1...count {
            let columns = Int(ceil(Double(count) / Double(rows)))
            let usableWidth = availableFrame.width - normalizedGap * CGFloat(max(columns - 1, 0))
            let usableHeight = availableFrame.height - normalizedGap * CGFloat(max(rows - 1, 0))
            guard usableWidth > 0, usableHeight > 0 else {
                continue
            }

            let tileWidth = usableWidth / CGFloat(columns)
            let tileHeight = usableHeight / CGFloat(rows)
            guard tileWidth >= 80, tileHeight >= 60 else {
                continue
            }

            let actualAspect = tileWidth / tileHeight
            let aspectDelta = abs(log(actualAspect / aspectRatio))
            let usedArea = tileWidth * tileHeight * CGFloat(count)
            let candidate = GridCandidate(
                rows: rows,
                columns: columns,
                tileWidth: tileWidth,
                tileHeight: tileHeight,
                aspectDelta: aspectDelta,
                usedArea: usedArea
            )

            guard let existingBest = best else {
                best = candidate
                continue
            }

            let isBetterAspect = candidate.aspectDelta < existingBest.aspectDelta - 0.001
            let isSimilarAspect = abs(candidate.aspectDelta - existingBest.aspectDelta) <= 0.001
            if isBetterAspect || (isSimilarAspect && candidate.usedArea > existingBest.usedArea) {
                best = candidate
            }
        }

        return best
    }

    static func tiledFrames(
        count: Int,
        availableFrame: CGRect,
        aspectRatio: CGFloat,
        gap: CGFloat
    ) -> [CGRect] {
        guard let best = bestGrid(
            count: count,
            availableFrame: availableFrame,
            aspectRatio: aspectRatio,
            gap: gap
        ) else {
            return []
        }

        let normalizedGap = max(gap, 0)
        var frames: [CGRect] = []
        frames.reserveCapacity(count)

        for index in 0..<count {
            let row = index / best.columns
            let column = index % best.columns
            let x = availableFrame.minX + CGFloat(column) * (best.tileWidth + normalizedGap)
            let y = availableFrame.maxY - best.tileHeight - CGFloat(row) * (best.tileHeight + normalizedGap)
            frames.append(CGRect(x: x, y: y, width: best.tileWidth, height: best.tileHeight).integral)
        }

        return frames
    }

    static func leadingHorizontalSlice(
        of availableFrame: CGRect,
        widthFraction: CGFloat
    ) -> CGRect {
        let normalizedAvailable = availableFrame.integral
        let normalizedFraction = min(max(widthFraction, 0.05), 1)
        let width = max((normalizedAvailable.width * normalizedFraction).rounded(.down), 1)
        return CGRect(
            x: normalizedAvailable.minX,
            y: normalizedAvailable.minY,
            width: min(width, normalizedAvailable.width),
            height: normalizedAvailable.height
        ).integral
    }

    static func trailingHorizontalSlice(
        of availableFrame: CGRect,
        widthFraction: CGFloat
    ) -> CGRect {
        let normalizedAvailable = availableFrame.integral
        let normalizedFraction = min(max(widthFraction, 0.05), 1)
        let width = max((normalizedAvailable.width * normalizedFraction).rounded(.down), 1)
        let clampedWidth = min(width, normalizedAvailable.width)
        return CGRect(
            x: normalizedAvailable.maxX - clampedWidth,
            y: normalizedAvailable.minY,
            width: clampedWidth,
            height: normalizedAvailable.height
        ).integral
    }
}
