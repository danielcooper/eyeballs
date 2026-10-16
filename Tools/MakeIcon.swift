import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Draws the Eyeballs app icon in a 1024-point design space at any pixel size.

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [r, g, b, a])!
}

func draw(in ctx: CGContext, pixels: Int) {
    let scale = CGFloat(pixels) / 1024
    let small = pixels <= 32
    ctx.translateBy(x: 0, y: CGFloat(pixels))
    ctx.scaleBy(x: scale, y: -scale) // top-left origin, 1024 units

    // Background tile, following the macOS icon grid (824pt body inside 1024).
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: color(0, 0, 0, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0.06, 0.09, 0.15))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let background = CGGradient(colorsSpace: sRGB, colors: [
        color(0.16, 0.24, 0.36),
        color(0.09, 0.13, 0.22),
        color(0.04, 0.06, 0.11),
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 200, y: 100), end: CGPoint(x: 820, y: 924), options: [])

    // Diff lines the eyes are reading: added in green, removed in red, context in grey.
    if !small {
        let lines: [(width: CGFloat, tint: CGColor)] = [
            (420, color(0.55, 0.60, 0.70, 0.30)),
            (560, color(0.85, 0.32, 0.36, 0.55)),
            (500, color(0.30, 0.78, 0.48, 0.60)),
            (610, color(0.30, 0.78, 0.48, 0.60)),
            (360, color(0.55, 0.60, 0.70, 0.30)),
        ]
        for (index, line) in lines.enumerated() {
            let y = 640 + CGFloat(index) * 46
            ctx.setFillColor(line.tint)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 206, y: y, width: line.width, height: 24), cornerWidth: 12, cornerHeight: 12, transform: nil))
            ctx.fillPath()
        }
    }

    let eyeCenters = small
        ? [CGPoint(x: 352, y: 512), CGPoint(x: 672, y: 512)]
        : [CGPoint(x: 382, y: 420), CGPoint(x: 642, y: 420)]
    let eyeRadii = small ? CGSize(width: 142, height: 190) : CGSize(width: 112, height: 150)
    let gaze = CGPoint(x: 26, y: 52) // down and to the right, at the diff

    for center in eyeCenters {
        let eyeRect = CGRect(x: center.x - eyeRadii.width, y: center.y - eyeRadii.height,
                             width: eyeRadii.width * 2, height: eyeRadii.height * 2)

        // The white of the eye, shaded so it reads as a ball.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 30, color: color(0, 0, 0, 0.45))
        ctx.addEllipse(in: eyeRect)
        ctx.setFillColor(color(0.93, 0.94, 0.96))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addEllipse(in: eyeRect)
        ctx.clip()
        let white = CGGradient(colorsSpace: sRGB, colors: [
            color(1, 1, 1),
            color(0.90, 0.92, 0.95),
            color(0.70, 0.74, 0.80),
        ] as CFArray, locations: [0, 0.6, 1])!
        let lightPoint = CGPoint(x: center.x - 30, y: center.y - 50)
        ctx.drawRadialGradient(white, startCenter: lightPoint, startRadius: 0, endCenter: center, endRadius: eyeRadii.height, options: [.drawsAfterEndLocation])

        // Iris and pupil, looking at the diff.
        let irisCenter = CGPoint(x: center.x + gaze.x, y: center.y + gaze.y)
        let irisRadius: CGFloat = small ? 92 : 64
        let iris = CGGradient(colorsSpace: sRGB, colors: [
            color(0.40, 0.80, 0.86),
            color(0.13, 0.48, 0.66),
            color(0.06, 0.24, 0.40),
        ] as CFArray, locations: [0, 0.6, 1])!
        ctx.addEllipse(in: CGRect(x: irisCenter.x - irisRadius, y: irisCenter.y - irisRadius, width: irisRadius * 2, height: irisRadius * 2))
        ctx.clip()
        ctx.drawRadialGradient(iris, startCenter: irisCenter, startRadius: 0, endCenter: irisCenter, endRadius: irisRadius, options: [])
        ctx.restoreGState()

        let pupilRadius: CGFloat = small ? 46 : 30
        ctx.setFillColor(color(0.03, 0.04, 0.06))
        ctx.addEllipse(in: CGRect(x: irisCenter.x - pupilRadius, y: irisCenter.y - pupilRadius, width: pupilRadius * 2, height: pupilRadius * 2))
        ctx.fillPath()

        if !small {
            ctx.setFillColor(color(1, 1, 1, 0.85))
            ctx.addEllipse(in: CGRect(x: irisCenter.x - 30, y: irisCenter.y - 34, width: 22, height: 22))
            ctx.fillPath()
        }

        ctx.addEllipse(in: eyeRect)
        ctx.setStrokeColor(color(0.02, 0.03, 0.06, 0.55))
        ctx.setLineWidth(small ? 22 : 8)
        ctx.strokePath()
    }

    // Subtle top highlight on the tile.
    let sheen = CGGradient(colorsSpace: sRGB, colors: [color(1, 1, 1, 0.10), color(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 420), options: [])
    ctx.restoreGState()
}

func render(pixels: Int, to url: URL) {
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    draw(in: ctx, pixels: pixels)
    let image = ctx.makeImage()!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    render(pixels: pixels, to: output.appendingPathComponent("icon_\(pixels).png"))
}
print("done")
