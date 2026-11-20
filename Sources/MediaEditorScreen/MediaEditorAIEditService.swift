import Foundation
import UIKit
import CoreImage
import SwiftSignalKit

enum MediaEditorAIEditError {
    case generic
}

/// The edit behind the story editor's AI edit (`MediaEditorAIEditView`).
///
/// `image` is the photo the editor works on, upright, before its tools and entities. `mask` has the image's size in
/// pixels and marks where the change goes: white inside the selection, black outside, a few points of soft edge between
/// (`mediaEditorAIEditMask`). `prompt` is what the user asked for. The picture that comes back may have another size (it
/// is scaled to the photo's) and may redraw more than the selection: the editor keeps the photo's own pixels outside the
/// mask (`mediaEditorAIEditComposite`). The signal does its work off the main queue.
protocol MediaEditorAIEditService: AnyObject {
    func edit(image: UIImage, mask: UIImage, prompt: String) -> Signal<UIImage, MediaEditorAIEditError>
}

/// Stands in for Telegram's Agent until it can edit pictures. The Agent keeps the AI provider keys on Telegram's servers
/// (`TelegramEngine.agent`, TelegramEngineAgent.swift) and its API is parked in this build (`agentApiIsAvailable`,
/// `TELEGRAM_AGENT_API`). A service backed by it plugs in here: it sends the photo (scaled down to what the provider
/// takes, about 1.5k px on the long side), the mask and the prompt as an agent request and hands back the provider's
/// picture; nothing else in the editor changes. Until then this one waits about as long as a generation takes and gives
/// the selection a gentle local change, so the whole flow can be tried.
final class MediaEditorAIEditStubService: MediaEditorAIEditService {
    private let generationTime: Double
    
    init(generationTime: Double = 2.0) {
        self.generationTime = generationTime
    }
    
    func edit(image: UIImage, mask: UIImage, prompt: String) -> Signal<UIImage, MediaEditorAIEditError> {
        return Signal { subscriber in
            // A brighter, fuller-coloured copy of the photo: only the selection is taken from it.
            if let source = mediaEditorAIEditUprightImage(image) {
                let input = CIImage(cgImage: source)
                let output = input
                    .applyingFilter("CIColorControls", parameters: [
                        kCIInputSaturationKey: 1.3,
                        kCIInputBrightnessKey: 0.04,
                        kCIInputContrastKey: 1.05
                    ])
                    .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.4])
                if let result = mediaEditorAIEditRender(output, extent: input.extent, like: source) {
                    subscriber.putNext(UIImage(cgImage: result))
                    subscriber.putCompletion()
                    return EmptyDisposable
                }
            }
            subscriber.putError(.generic)
            return EmptyDisposable
        }
        |> runOn(Queue.concurrentDefaultQueue())
        |> delay(self.generationTime, queue: Queue.concurrentDefaultQueue())
    }
}

/// The selection as `MediaEditorAIEditService` takes it: a grey image of `size` pixels, white inside `path` (in those
/// pixels, origin at the top left, even-odd as the dim drawn over the preview) and black outside, the edge blurred over
/// about `feather` pixels.
func mediaEditorAIEditMask(size: CGSize, path: CGPath, feather: CGFloat) -> UIImage? {
    let width = Int(size.width)
    let height = Int(size.height)
    guard width > 0, height > 0, let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
        return nil
    }
    context.setFillColor(gray: 0.0, alpha: 1.0)
    context.fill(CGRect(x: 0.0, y: 0.0, width: CGFloat(width), height: CGFloat(height)))
    context.translateBy(x: 0.0, y: CGFloat(height))
    context.scaleBy(x: 1.0, y: -1.0)
    context.addPath(path)
    context.setFillColor(gray: 1.0, alpha: 1.0)
    context.fillPath(using: .evenOdd)
    guard let sharp = context.makeImage() else {
        return nil
    }
    guard feather > 0.5 else {
        return UIImage(cgImage: sharp)
    }
    let input = CIImage(cgImage: sharp)
    let soft = input.clampedToExtent().applyingGaussianBlur(sigma: Double(feather) / 2.0).cropped(to: input.extent)
    guard let result = mediaEditorAIEditContext.createCGImage(soft, from: input.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()) else {
        return UIImage(cgImage: sharp)
    }
    return UIImage(cgImage: result)
}

/// `edited` laid into `original` through `mask`: the edit inside the selection, the photo's own pixels outside it, so
/// nothing a service redraws elsewhere reaches the story. `edited` and `mask` are scaled to the photo's size first; the
/// result has the photo's size and colour space.
func mediaEditorAIEditComposite(original: UIImage, edited: UIImage, mask: UIImage) -> UIImage? {
    guard let originalImage = mediaEditorAIEditUprightImage(original), let editedImage = mediaEditorAIEditUprightImage(edited), let maskImage = mask.cgImage else {
        return nil
    }
    let background = CIImage(cgImage: originalImage)
    let extent = background.extent
    func fitted(_ image: CIImage) -> CIImage {
        guard image.extent.size != extent.size, image.extent.width > 0.0, image.extent.height > 0.0 else {
            return image
        }
        return image.transformed(by: CGAffineTransform(scaleX: extent.width / image.extent.width, y: extent.height / image.extent.height))
    }
    let output = fitted(CIImage(cgImage: editedImage)).applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: background,
        kCIInputMaskImageKey: fitted(CIImage(cgImage: maskImage))
    ]).cropped(to: extent)
    guard let result = mediaEditorAIEditRender(output, extent: extent, like: originalImage) else {
        return nil
    }
    return UIImage(cgImage: result, scale: 1.0, orientation: .up)
}

/// `image`'s pixels the right way up (the editor's own photos already are).
func mediaEditorAIEditUprightImage(_ image: UIImage) -> CGImage? {
    if image.imageOrientation == .up, let cgImage = image.cgImage {
        return cgImage
    }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1.0
    format.preferredRange = .standard
    let size = CGSize(width: floor(image.size.width * image.scale), height: floor(image.size.height * image.scale))
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
        image.draw(in: CGRect(origin: CGPoint(), size: size))
    }.cgImage
}

private let mediaEditorAIEditContext = CIContext(options: nil)

/// Renders 8 bits a channel in `source`'s colour space, so a Display P3 photo stays P3.
private func mediaEditorAIEditRender(_ image: CIImage, extent: CGRect, like source: CGImage) -> CGImage? {
    var colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    if let sourceColorSpace = source.colorSpace, sourceColorSpace.model == .rgb {
        colorSpace = sourceColorSpace
    }
    return mediaEditorAIEditContext.createCGImage(image, from: extent, format: .RGBA8, colorSpace: colorSpace)
}
