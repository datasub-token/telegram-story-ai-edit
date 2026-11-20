import Foundation
import UIKit
import Display
import ComponentFlow
import SwiftSignalKit
import TelegramPresentationData
import AppBundle
import MediaEditor
import GlassBackgroundComponent
import MediaEditorBottomControls

/// Soft edge of the selection, points of the screen (the mask is blurred over this much).
private let mediaEditorAIEditFeather: CGFloat = 3.0
/// The hint capsule's side padding: the paint tabs' own (`mediaEditorStoryPaintTextInset`, MediaEditorScreen.swift).
private let mediaEditorAIEditHintInset: CGFloat = 23.0
/// A stroke smaller than this either way selects nothing.
private let mediaEditorAIEditMinimumSelection: CGFloat = 24.0

/// The story editor's AI edit: circle a place on the photo with a finger, say what should be there, and only that place
/// changes (`MediaEditorScreenImpl.Node.presentAIEdit`). While it is open this view covers the editor: the selection is
/// drawn on a layer lying exactly over the preview, and a bar takes the place of the editor's bottom row, whose controls
/// step aside. The edit itself comes from a `MediaEditorAIEditService`; the result is handed to `apply`, which makes it
/// the editor's photo.
final class MediaEditorAIEditView: UIView, UITextFieldDelegate {
    struct Layout: Equatable {
        /// The whole screen.
        var size: CGSize
        /// The preview, in this view's coordinates.
        var previewFrame: CGRect
        /// The editor's bottom row: 44 high, across the controls band.
        var rowFrame: CGRect
        /// The row's side inset (16, 9 on narrow screens).
        var sideInset: CGFloat
        var inputHeight: CGFloat
    }
    
    private enum Phase {
        /// The hint is out; a finger may draw.
        case selecting
        /// A finger is drawing.
        case drawing
        /// A selection is closed; the field takes the request.
        case prompting
        /// The service is editing the selection.
        case working
        /// The result is the editor's photo; this view is on its way out.
        case finishing
    }
    
    /// Makes the edited photo the editor's photo, then calls back once the new picture is on screen.
    var apply: ((UIImage, @escaping () -> Void) -> Void)?
    var failed: (() -> Void)?
    /// The editor gets its controls back (the view itself may stay a little longer, fading).
    var dismissed: (() -> Void)?
    
    private weak var mediaEditor: MediaEditor?
    private weak var previewView: UIView?
    private weak var mediaEntityView: UIView?
    private let controlsViews: [UIView]
    private let service: MediaEditorAIEditService
    
    private let canvasView = UIView()
    private let workingView = UIView()
    private let workingMaskLayer = SimpleShapeLayer()
    private var workingSnapshotView: UIView?
    private var workingVeilView: UIView?
    private var shimmerLayer: SimpleGradientLayer?
    private var sparklesLayer: CAEmitterLayer?
    private let dimLayer = SimpleShapeLayer()
    private let tailLayer = SimpleShapeLayer()
    private let lineLayer = SimpleShapeLayer()
    private let lightLayer = SimpleLayer()
    private let fingerLayer = SimpleLayer()
    
    private let closeButton: MediaEditorAIEditGlassButton
    private let sendButton: MediaEditorAIEditGlassButton
    private let fieldView = UIView()
    private let fieldGlassView = GlassBackgroundView()
    private let fieldClipView = UIView()
    private let hintLabel = UILabel()
    private let textField = UITextField()
    
    private var phase: Phase = .selecting
    private var isFieldShown = false
    private var isSendShown = false
    private var stroke: [CGPoint] = []
    private var touchStart: CGPoint?
    private var selection: (points: [CGPoint], path: CGPath)?
    private var currentLayout: Layout?
    private var isDismissing = false
    
    private let hapticFeedback = HapticFeedback()
    private let editDisposable = MetaDisposable()
    
    init(strings: PresentationStrings, mediaEditor: MediaEditor, previewView: UIView, mediaEntityView: UIView, controlsViews: [UIView], service: MediaEditorAIEditService) {
        self.mediaEditor = mediaEditor
        self.previewView = previewView
        self.mediaEntityView = mediaEntityView
        self.controlsViews = controlsViews
        self.service = service
        
        // The editor's bottom row pieces: a panel-glass circle with the cross, the row's left piece in Draw and Tools
        // (`updateBottomControls`, MediaEditorScreen.swift), and where NEXT is a glass circle in the editor's accent
        // #0088FF (`mediaEditorStoryAccentColor`) with the send arrow.
        self.closeButton = MediaEditorAIEditGlassButton(
            icon: generateTintedImage(image: UIImage(bundleImageName: "Navigation/Close"), color: .white),
            glassTintColor: GlassBackgroundView.TintColor(kind: .panel),
            accessibilityLabel: strings.Common_Close
        )
        self.sendButton = MediaEditorAIEditGlassButton(
            icon: generateTintedImage(image: UIImage(bundleImageName: "Chat/Input/Text/SendIcon"), color: .white),
            glassTintColor: GlassBackgroundView.TintColor(kind: .custom(style: .default, color: UIColor(rgb: 0x0088ff))),
            accessibilityLabel: strings.MediaPicker_Send
        )
        
        super.init(frame: CGRect())
        
        // Over the preview, with its rounding (the editor's `previewContainerView`: 30, continuous).
        self.canvasView.isUserInteractionEnabled = false
        self.canvasView.clipsToBounds = true
        self.canvasView.layer.cornerRadius = 30.0
        self.canvasView.layer.cornerCurve = .continuous
        self.addSubview(self.canvasView)
        
        self.workingView.isUserInteractionEnabled = false
        self.workingView.isHidden = true
        self.workingMaskLayer.fillRule = .evenOdd
        self.workingView.layer.mask = self.workingMaskLayer
        self.canvasView.addSubview(self.workingView)
        
        self.dimLayer.fillColor = UIColor(white: 0.0, alpha: 0.5).cgColor
        self.dimLayer.fillRule = .evenOdd
        self.dimLayer.opacity = 0.0
        self.canvasView.layer.addSublayer(self.dimLayer)
        
        // A crisp white line with a soft white glow, the cut-out outline's look (StickerCutoutOutlineView.swift:18-22: a
        // white shadow of radius 4).
        for layer in [self.tailLayer, self.lineLayer] {
            layer.fillColor = nil
            layer.strokeColor = UIColor.white.cgColor
            layer.lineWidth = 2.6
            layer.lineCap = .round
            layer.lineJoin = .round
            layer.shadowColor = UIColor.white.cgColor
            layer.shadowOpacity = 0.5
            layer.shadowRadius = 4.0
            layer.shadowOffset = CGSize()
            self.canvasView.layer.addSublayer(layer)
        }
        self.canvasView.layer.addSublayer(self.lightLayer)
        
        self.fingerLayer.bounds = CGRect(origin: CGPoint(), size: CGSize(width: 8.0, height: 8.0))
        self.fingerLayer.cornerRadius = 4.0
        self.fingerLayer.backgroundColor = UIColor.white.cgColor
        self.fingerLayer.shadowColor = UIColor.white.cgColor
        self.fingerLayer.shadowOpacity = 1.0
        self.fingerLayer.shadowRadius = 6.0
        self.fingerLayer.shadowOffset = CGSize()
        self.fingerLayer.opacity = 0.0
        self.canvasView.layer.addSublayer(self.fingerLayer)
        
        self.closeButton.action = { [weak self] in
            self?.dismiss()
        }
        self.addSubview(self.closeButton)
        
        self.fieldClipView.clipsToBounds = true
        self.fieldGlassView.contentView.addSubview(self.fieldClipView)
        self.fieldView.addSubview(self.fieldGlassView)
        self.addSubview(self.fieldView)
        
        // As the capsule's own text tabs in Draw (`middleItem`, MediaEditorScreen.swift).
        self.hintLabel.font = Font.with(size: 15.0, design: .regular, weight: .medium)
        self.hintLabel.textColor = .white
        self.hintLabel.textAlignment = .center
        self.hintLabel.lineBreakMode = .byTruncatingTail
        self.hintLabel.text = strings.MediaEditor_AIEditInfo
        self.fieldClipView.addSubview(self.hintLabel)
        
        // As the caption field: SF 17, white text and caret, the placeholder white at 0.35
        // (MessageInputPanelComponent.swift:1323-1327, 1371, 1386).
        self.textField.font = Font.regular(17.0)
        self.textField.textColor = .white
        self.textField.tintColor = .white
        self.textField.keyboardAppearance = .dark
        self.textField.returnKeyType = .send
        self.textField.enablesReturnKeyAutomatically = true
        self.textField.attributedPlaceholder = NSAttributedString(string: strings.Agent_InputPlaceholder, font: Font.regular(17.0), textColor: UIColor(white: 1.0, alpha: 0.35))
        self.textField.delegate = self
        self.textField.addTarget(self, action: #selector(self.textFieldChanged), for: .editingChanged)
        self.textField.alpha = 0.0
        self.textField.isUserInteractionEnabled = false
        self.fieldClipView.addSubview(self.textField)
        
        self.sendButton.action = { [weak self] in
            self?.send()
        }
        self.sendButton.alpha = 0.0
        self.sendButton.isUserInteractionEnabled = false
        self.sendButton.layer.transform = CATransform3DMakeScale(0.12, 0.12, 1.0)
        self.addSubview(self.sendButton)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        self.editDisposable.dispose()
    }
    
    // MARK: Layout
    
    func update(layout: Layout, transition: ComponentTransition) {
        self.currentLayout = layout
        
        transition.setFrame(view: self, frame: CGRect(origin: CGPoint(), size: layout.size))
        transition.setFrame(view: self.canvasView, frame: layout.previewFrame)
        let bounds = CGRect(origin: CGPoint(), size: layout.previewFrame.size)
        self.workingView.frame = bounds
        for layer in [self.workingMaskLayer, self.dimLayer, self.tailLayer, self.lineLayer, self.lightLayer] as [CALayer] {
            layer.frame = bounds
        }
        if let selection = self.selection {
            self.dimLayer.path = self.dimPath(selection.path)
        }
        
        self.updateBar(transition: transition)
    }
    
    private func updateBar(transition: ComponentTransition) {
        guard let layout = self.currentLayout else {
            return
        }
        let side = mediaEditorBottomControlsButtonSide
        var rowY = layout.rowFrame.minY
        if layout.inputHeight > 0.0 {
            // Over the keyboard, by the gap the row keeps under the preview (`buttonBottomInset`,
            // MediaEditorStoryBottomControls.swift:34).
            rowY = min(rowY, layout.size.height - layout.inputHeight - side - 8.0)
        }
        let closeFrame = CGRect(x: layout.rowFrame.minX + layout.sideInset, y: rowY, width: side, height: side)
        let sendFrame = CGRect(x: layout.rowFrame.maxX - layout.sideInset - side, y: rowY, width: side, height: side)
        
        let hintSize = self.hintLabel.sizeThatFits(CGSize(width: layout.size.width, height: side))
        let fieldFrame: CGRect
        if self.isFieldShown {
            // From the cross to the send button, 8 pt from each.
            let minX = closeFrame.maxX + 8.0
            fieldFrame = CGRect(x: minX, y: rowY, width: max(side, sendFrame.minX - 8.0 - minX), height: side)
        } else {
            // The hint: centred between the two side pieces, as the tools capsule is (`.betweenSideButtons`,
            // MediaEditorBottomControls.swift:45-67).
            let width = min(ceil(hintSize.width) + mediaEditorAIEditHintInset * 2.0, max(side, sendFrame.minX - closeFrame.maxX - 16.0))
            fieldFrame = CGRect(x: closeFrame.maxX + floorToScreenPixels((sendFrame.minX - closeFrame.maxX - width) / 2.0), y: rowY, width: width, height: side)
        }
        
        transition.setFrame(view: self.closeButton, frame: closeFrame)
        self.closeButton.update(size: closeFrame.size, transition: transition)
        
        transition.setPosition(view: self.sendButton, position: sendFrame.center)
        transition.setBounds(view: self.sendButton, bounds: CGRect(origin: CGPoint(), size: sendFrame.size))
        self.sendButton.update(size: sendFrame.size, transition: transition)
        
        let fieldBounds = CGRect(origin: CGPoint(), size: fieldFrame.size)
        transition.setFrame(view: self.fieldView, frame: fieldFrame)
        transition.setFrame(view: self.fieldGlassView, frame: fieldBounds)
        self.fieldGlassView.update(size: fieldFrame.size, cornerRadius: side * 0.5, isDark: true, tintColor: GlassBackgroundView.TintColor(kind: .panel), isInteractive: false, transition: transition)
        transition.setFrame(view: self.fieldClipView, frame: fieldBounds)
        transition.setCornerRadius(layer: self.fieldClipView.layer, cornerRadius: side * 0.5)
        
        self.hintLabel.bounds = CGRect(origin: CGPoint(), size: CGSize(width: min(ceil(hintSize.width), max(1.0, fieldFrame.width - 24.0)), height: ceil(hintSize.height)))
        transition.setPosition(view: self.hintLabel, position: CGPoint(x: fieldBounds.midX, y: fieldBounds.midY))
        transition.setFrame(view: self.textField, frame: CGRect(x: 16.0, y: 0.0, width: max(1.0, fieldFrame.width - 16.0 - 12.0), height: side))
    }
    
    // MARK: Showing and hiding
    
    func animateIn() {
        // The editor's controls step aside the way the bottom row fades as a whole (0.2 s with an 8 px blur,
        // MediaEditorBottomControlsComponent.swift:565-568).
        for view in self.controlsViews {
            mediaEditorFadeWithBlur(view: view, isIn: false)
        }
        for view in [self.closeButton, self.fieldView] as [UIView] {
            mediaEditorFadeWithBlur(view: view, isIn: true, alpha: 1.0)
        }
    }
    
    /// Closes without changing the photo (the cross, or a failed edit).
    func dismiss() {
        guard !self.isDismissing else {
            return
        }
        self.isDismissing = true
        self.editDisposable.dispose()
        self.textField.resignFirstResponder()
        self.isUserInteractionEnabled = false
        
        for view in self.controlsViews {
            mediaEditorFadeWithBlur(view: view, isIn: true, alpha: 1.0)
        }
        // Still laid out with the preview while it fades (the preview comes down with the keyboard).
        ComponentTransition.easeInOut(duration: 0.2).setAlpha(view: self, alpha: 0.0, completion: { [weak self] _ in
            self?.dismissed?()
            self?.removeFromSuperview()
        })
    }
    
    private func setFieldShown(_ isShown: Bool) {
        guard self.isFieldShown != isShown else {
            return
        }
        self.isFieldShown = isShown
        // The capsule stretches from the hint into the field (the editor's capsule morphs spring over 0.4 s).
        self.updateBar(transition: .spring(duration: 0.4))
        mediaEditorFadeWithBlur(view: self.hintLabel, isIn: !isShown, alpha: 1.0)
        mediaEditorFadeWithBlur(view: self.textField, isIn: isShown, alpha: 1.0)
        self.textField.isUserInteractionEnabled = isShown
        if !isShown {
            self.textField.resignFirstResponder()
        }
        self.updateSendButton()
    }
    
    private func updateSendButton() {
        let hasText = !(self.textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let isShown = self.isFieldShown && hasText && self.phase == .prompting
        guard self.isSendShown != isShown else {
            return
        }
        self.isSendShown = isShown
        self.sendButton.isUserInteractionEnabled = isShown
        // Grows where the editor's NEXT is and folds back, as a capsule that empties folds into a dot
        // (`mediaEditorBottomControlsCollapsedSide`, MediaEditorBottomControlsComponent.swift:374-380).
        ComponentTransition.spring(duration: 0.4).setScale(view: self.sendButton, scale: isShown ? 1.0 : 0.12)
        ComponentTransition.easeInOut(duration: isShown ? 0.15 : 0.2).setAlpha(view: self.sendButton, alpha: isShown ? 1.0 : 0.0)
    }
    
    // MARK: Drawing the selection
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Only touches on this view itself: the bar's pieces pass on what they do not use.
        guard let touch = touches.first, touch.view === self else {
            return
        }
        guard self.phase == .selecting || self.phase == .prompting else {
            return
        }
        let point = touch.location(in: self.canvasView)
        if self.canvasView.bounds.contains(point) {
            self.touchStart = point
        }
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let touchStart = self.touchStart else {
            return
        }
        let bounds = self.canvasView.bounds
        for touch in event?.coalescedTouches(for: touch) ?? [touch] {
            let location = touch.location(in: self.canvasView)
            let point = CGPoint(x: max(bounds.minX, min(bounds.maxX, location.x)), y: max(bounds.minY, min(bounds.maxY, location.y)))
            if self.phase != .drawing {
                guard hypot(point.x - touchStart.x, point.y - touchStart.y) > 4.0 else {
                    continue
                }
                self.beginDrawing(at: touchStart)
            }
            if let last = self.stroke.last, hypot(point.x - last.x, point.y - last.y) < 1.5 {
                continue
            }
            self.stroke.append(point)
        }
        if self.phase == .drawing {
            let path = mediaEditorAIEditPath(self.stroke, isClosed: false)
            self.setLinePath(path, layer: self.lineLayer)
            if let last = self.stroke.last {
                self.fingerLayer.position = last
            }
        }
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        self.touchStart = nil
        if self.phase == .drawing {
            self.endDrawing()
        } else if let touch = touches.first, touch.view === self, self.textField.isFirstResponder {
            // A tap beside the field puts the keyboard away (a drag draws a new selection instead).
            self.textField.resignFirstResponder()
        }
    }
    
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        self.touchesEnded(touches, with: event)
    }
    
    private func beginDrawing(at point: CGPoint) {
        self.phase = .drawing
        // Drawing again replaces the selection.
        if self.selection != nil {
            self.selection = nil
            self.removeLight()
            ComponentTransition.easeInOut(duration: 0.2).setAlpha(layer: self.dimLayer, alpha: 0.0)
        }
        self.stroke = [point]
        self.tailLayer.removeAllAnimations()
        self.tailLayer.path = nil
        self.tailLayer.shadowPath = nil
        self.lineLayer.removeAllAnimations()
        self.lineLayer.opacity = 1.0
        self.setLinePath(mediaEditorAIEditPath(self.stroke, isClosed: false), layer: self.lineLayer)
        self.fingerLayer.removeAllAnimations()
        self.fingerLayer.position = point
        self.fingerLayer.opacity = 1.0
    }
    
    private func endDrawing() {
        ComponentTransition.easeInOut(duration: 0.2).setAlpha(layer: self.fingerLayer, alpha: 0.0)
        
        guard let loop = mediaEditorAIEditLoop(self.stroke) else {
            // Too small to select anything: the line goes, the hint comes back.
            self.phase = .selecting
            ComponentTransition.easeInOut(duration: 0.2).setAlpha(layer: self.lineLayer, alpha: 0.0)
            self.setFieldShown(false)
            return
        }
        let path = mediaEditorAIEditPath(loop.points, isClosed: true)
        self.selection = (loop.points, path)
        self.setLinePath(path, layer: self.lineLayer)
        
        // The bit drawn past the start fades out.
        if loop.closeIndex < self.stroke.count - 1 {
            self.setLinePath(mediaEditorAIEditPath(Array(self.stroke[loop.closeIndex...]), isClosed: false), layer: self.tailLayer)
            self.tailLayer.opacity = 1.0
            ComponentTransition.easeInOut(duration: 0.32).setAlpha(layer: self.tailLayer, alpha: 0.0)
        }
        // The rest of the photo dims (black at 0.5 outside the loop).
        self.dimLayer.path = self.dimPath(path)
        ComponentTransition.easeInOut(duration: 0.4).setAlpha(layer: self.dimLayer, alpha: 1.0)
        self.startLight(path: path, length: loop.length)
        
        self.phase = .prompting
        self.setFieldShown(true)
        self.textField.becomeFirstResponder()
    }
    
    private func setLinePath(_ path: CGPath, layer: CAShapeLayer) {
        layer.path = path
        layer.shadowPath = path.copy(strokingWithWidth: layer.lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 0.0)
    }
    
    private func dimPath(_ selectionPath: CGPath) -> CGPath {
        let path = CGMutablePath()
        path.addRect(self.canvasView.bounds.insetBy(dx: -1.0, dy: -1.0))
        path.addPath(selectionPath)
        return path
    }
    
    // MARK: The light running round the selection
    
    private func startLight(path: CGPath, length: CGFloat) {
        self.removeLight()
        guard length > 0.0 else {
            return
        }
        // One lap at the pace of the cut-out outline's light (StickerCutoutOutlineView.swift:63).
        let lap = min(8.0, max(3.0, Double(length) / 135.0))
        // The path twice over: a window sliding along the first copy ends on the same place in the second, so each lap
        // comes round with no seam.
        let lightFrame = path.boundingBoxOfPath.insetBy(dx: -16.0, dy: -16.0)
        let toLightFrame = CGAffineTransform(translationX: -lightFrame.minX, y: -lightFrame.minY)
        let doubledPath = CGMutablePath()
        doubledPath.addPath(path, transform: toLightFrame)
        doubledPath.addPath(path, transform: toLightFrame)
        // A short comet: a faint tail, a brighter body and a bright glowing head, all ending at the head.
        let pieces: [(length: CGFloat, width: CGFloat, opacity: Float, glows: Bool)] = [
            (64.0, 2.6, 0.35, false),
            (30.0, 3.0, 0.6, false),
            (12.0, 3.6, 1.0, true)
        ]
        for piece in pieces {
            let span = min(0.45, piece.length / length) * 0.5
            let layer = SimpleShapeLayer()
            layer.frame = lightFrame
            layer.path = doubledPath
            layer.fillColor = nil
            layer.strokeColor = UIColor.white.cgColor
            layer.lineWidth = piece.width
            layer.lineCap = .round
            layer.lineJoin = .round
            layer.opacity = piece.opacity
            if piece.glows {
                layer.shadowColor = UIColor.white.cgColor
                layer.shadowOpacity = 0.9
                layer.shadowRadius = 5.0
                layer.shadowOffset = CGSize()
            }
            layer.strokeStart = 0.0
            layer.strokeEnd = span
            
            let start = CABasicAnimation(keyPath: "strokeStart")
            start.fromValue = 0.0 as NSNumber
            start.toValue = 0.5 as NSNumber
            let end = CABasicAnimation(keyPath: "strokeEnd")
            end.fromValue = span as NSNumber
            end.toValue = (0.5 + span) as NSNumber
            let lapAnimation = CAAnimationGroup()
            lapAnimation.animations = [start, end]
            lapAnimation.duration = lap
            lapAnimation.repeatCount = .infinity
            lapAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
            layer.add(lapAnimation, forKey: "lap")
            
            self.lightLayer.addSublayer(layer)
        }
        self.lightLayer.opacity = 0.0
        ComponentTransition.easeInOut(duration: 0.25).setAlpha(layer: self.lightLayer, alpha: 1.0)
    }
    
    private func removeLight() {
        self.lightLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        self.lightLayer.removeAllAnimations()
        self.lightLayer.speed = 1.0
        self.lightLayer.timeOffset = 0.0
        self.lightLayer.beginTime = 0.0
    }
    
    /// Changes the pace of the light without a jump: the layer's own clock is carried over.
    private func setLightSpeed(_ speed: Float) {
        let layer = self.lightLayer
        let now = CACurrentMediaTime()
        let localTime = layer.convertTime(now, from: nil)
        layer.speed = speed
        layer.timeOffset = localTime
        layer.beginTime = layer.superlayer?.convertTime(now, from: nil) ?? now
    }
    
    // MARK: The request
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        self.send()
        return false
    }
    
    @objc private func textFieldChanged() {
        self.updateSendButton()
    }
    
    private func send() {
        guard self.phase == .prompting, let selection = self.selection else {
            return
        }
        let prompt = (self.textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            return
        }
        self.hapticFeedback.impact(.light)
        self.phase = .working
        self.textField.resignFirstResponder()
        self.textField.isUserInteractionEnabled = false
        ComponentTransition.easeInOut(duration: 0.25).setAlpha(view: self.textField, alpha: 0.55)
        self.updateSendButton()
        
        self.startWorkingEffects(path: selection.path)
        self.requestEdit(points: selection.points, prompt: prompt)
    }
    
    /// While the service works the selection goes soft and a little lighter, Telegram's loading shimmer crosses it, star
    /// sparkles twinkle in it and the light runs round it three times as fast.
    private func startWorkingEffects(path: CGPath) {
        let bounds = self.canvasView.bounds
        let box = path.boundingBoxOfPath
        
        self.workingMaskLayer.path = path
        self.workingView.isHidden = false
        
        // A copy of the preview as it is now, blurred: the new photo comes out sharp from under it.
        if let snapshotView = self.previewView?.snapshotView(afterScreenUpdates: false) {
            snapshotView.frame = bounds
            self.workingView.addSubview(snapshotView)
            ComponentTransition.easeInOut(duration: 0.45).setBlur(layer: snapshotView.layer, radius: 5.0)
            self.workingSnapshotView = snapshotView
        }
        let veilView = UIView(frame: bounds)
        veilView.backgroundColor = .white
        veilView.alpha = 0.0
        self.workingView.addSubview(veilView)
        ComponentTransition.easeInOut(duration: 0.45).setAlpha(view: veilView, alpha: 0.06)
        self.workingVeilView = veilView
        
        // The shimmer: clear, white, clear (ShimmerEffect.swift:74-90) moving across on easeOut (ShimmerEffect.swift:156-158),
        // here a pass of 0.7 s every 0.75 s, tilted.
        let bandWidth = max(40.0, box.width * 0.55)
        let bandHeight = box.height * 1.6
        let bandAngle: CGFloat = 18.0 * CGFloat.pi / 180.0
        // half the tilted band's width across the screen: at rest it is wholly outside the selection
        let bandReach = bandWidth * 0.5 * cos(bandAngle) + bandHeight * 0.5 * sin(bandAngle)
        let shimmerLayer = SimpleGradientLayer()
        shimmerLayer.colors = [UIColor(white: 1.0, alpha: 0.0).cgColor, UIColor(white: 1.0, alpha: 0.5).cgColor, UIColor(white: 1.0, alpha: 0.0).cgColor]
        shimmerLayer.locations = [0.0, 0.5, 1.0]
        shimmerLayer.startPoint = CGPoint(x: 0.0, y: 0.5)
        shimmerLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
        shimmerLayer.bounds = CGRect(origin: CGPoint(), size: CGSize(width: bandWidth, height: bandHeight))
        shimmerLayer.position = CGPoint(x: box.minX - bandReach, y: box.midY)
        shimmerLayer.transform = CATransform3DMakeRotation(bandAngle, 0.0, 0.0, 1.0)
        let pass = CABasicAnimation(keyPath: "position.x")
        pass.fromValue = (box.minX - bandReach) as NSNumber
        pass.toValue = (box.maxX + bandReach) as NSNumber
        pass.duration = 0.7
        pass.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let passes = CAAnimationGroup()
        passes.animations = [pass]
        passes.duration = 0.75
        passes.repeatCount = .infinity
        passes.beginTime = shimmerLayer.convertTime(CACurrentMediaTime(), from: nil) + 0.25
        shimmerLayer.add(passes, forKey: "shimmer")
        self.workingView.layer.addSublayer(shimmerLayer)
        self.shimmerLayer = shimmerLayer
        
        let sparklesLayer = mediaEditorAIEditSparkles(frame: bounds, box: box)
        self.workingView.layer.addSublayer(sparklesLayer)
        self.sparklesLayer = sparklesLayer
        
        self.setLightSpeed(3.0)
    }
    
    private func requestEdit(points: [CGPoint], prompt: String) {
        guard let mediaEditor = self.mediaEditor, let mediaEntityView = self.mediaEntityView, mediaEntityView.bounds.width > 0.0, mediaEntityView.bounds.height > 0.0 else {
            self.fail()
            return
        }
        // The selection in the photo's own space (0...1 of its width and height): the media entity lies over the canvas
        // as the photo is drawn on it (its crop offset, scale and rotation, VideoFinishPass.swift:396-404); a mirrored
        // photo is flipped inside it.
        let entitySize = mediaEntityView.bounds.size
        let isMirrored = mediaEditor.values.cropMirroring
        let normalizedPoints = points.map { point -> CGPoint in
            let local = mediaEntityView.convert(point, from: self.canvasView)
            let x = local.x / entitySize.width
            return CGPoint(x: isMirrored ? 1.0 - x : x, y: local.y / entitySize.height)
        }
        let unitStart = mediaEntityView.convert(CGPoint(), from: self.canvasView)
        let unitEnd = mediaEntityView.convert(CGPoint(x: 1.0, y: 0.0), from: self.canvasView)
        let feather = mediaEditorAIEditFeather * hypot(unitEnd.x - unitStart.x, unitEnd.y - unitStart.y) / entitySize.width
        
        let service = self.service
        let signal = mediaEditorAIEditSourceImage(mediaEditor)
        |> mapToSignal { image -> Signal<UIImage, MediaEditorAIEditError> in
            let pixelSize = CGSize(width: floor(image.size.width * image.scale), height: floor(image.size.height * image.scale))
            let path = CGMutablePath()
            path.addLines(between: normalizedPoints.map { CGPoint(x: $0.x * pixelSize.width, y: $0.y * pixelSize.height) })
            path.closeSubpath()
            guard let mask = mediaEditorAIEditMask(size: pixelSize, path: path, feather: feather * pixelSize.width) else {
                return .fail(.generic)
            }
            return service.edit(image: image, mask: mask, prompt: prompt)
            |> mapToSignal { edited -> Signal<UIImage, MediaEditorAIEditError> in
                guard let result = mediaEditorAIEditComposite(original: image, edited: edited, mask: mask) else {
                    return .fail(.generic)
                }
                return .single(result)
            }
        }
        |> deliverOnMainQueue
        
        self.editDisposable.set(signal.start(next: { [weak self] image in
            self?.received(image)
        }, error: { [weak self] _ in
            self?.fail()
        }))
    }
    
    private func received(_ image: UIImage) {
        guard self.phase == .working, !self.isDismissing else {
            return
        }
        var isRevealed = false
        let reveal: () -> Void = { [weak self] in
            if !isRevealed {
                isRevealed = true
                self?.reveal()
            }
        }
        // The photo is replaced under the soft copy, which goes once the new picture is drawn (or soon anyway).
        self.apply?(image, reveal)
        Queue.mainQueue().after(0.6, reveal)
    }
    
    private func fail() {
        guard self.phase == .working, !self.isDismissing else {
            return
        }
        self.failed?()
        self.dismiss()
    }
    
    // MARK: The result
    
    private func reveal() {
        guard self.phase == .working, !self.isDismissing else {
            return
        }
        self.phase = .finishing
        self.isUserInteractionEnabled = false
        // The light is back at its own pace as the result lands.
        self.setLightSpeed(1.0)
        
        // The soft copy of the old picture fades off the new one, which is sharp: the result comes out of a blur.
        if let snapshotView = self.workingSnapshotView {
            ComponentTransition.easeInOut(duration: 0.42).setAlpha(view: snapshotView, alpha: 0.0)
        }
        if let veilView = self.workingVeilView {
            ComponentTransition.easeInOut(duration: 0.4).setAlpha(view: veilView, alpha: 0.0)
        }
        if let shimmerLayer = self.shimmerLayer {
            ComponentTransition.easeInOut(duration: 0.25).setAlpha(layer: shimmerLayer, alpha: 0.0)
        }
        // A few more sparkles as the result lands, then none.
        if let sparklesLayer = self.sparklesLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sparklesLayer.birthRate = 3.0
            CATransaction.commit()
            Queue.mainQueue().after(0.25) {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                sparklesLayer.birthRate = 0.0
                CATransaction.commit()
            }
        }
        // The outline goes, then the dim lifts.
        ComponentTransition.easeInOut(duration: 0.35).setAlpha(layer: self.lineLayer, alpha: 0.0, delay: 0.05)
        ComponentTransition.easeInOut(duration: 0.35).setAlpha(layer: self.lightLayer, alpha: 0.0, delay: 0.05)
        ComponentTransition.easeInOut(duration: 0.45).setAlpha(layer: self.dimLayer, alpha: 0.0, delay: 0.15)
        ComponentTransition.easeInOut(duration: 0.25).setAlpha(view: self.textField, alpha: 1.0)
        
        Queue.mainQueue().after(0.6) { [weak self] in
            self?.finish()
        }
    }
    
    /// The bar goes and the editor's controls come back; the sparkles live out their time before the view leaves.
    private func finish() {
        guard !self.isDismissing else {
            return
        }
        self.isDismissing = true
        for view in self.controlsViews {
            mediaEditorFadeWithBlur(view: view, isIn: true, alpha: 1.0)
        }
        for view in [self.closeButton, self.fieldView] as [UIView] {
            mediaEditorFadeWithBlur(view: view, isIn: false)
        }
        self.dismissed?()
        Queue.mainQueue().after(1.2) { [weak self] in
            self?.removeFromSuperview()
        }
    }
}

/// A glass circle of the editor's bottom row with an icon in it.
private final class MediaEditorAIEditGlassButton: UIView {
    private let glassView = GlassBackgroundView()
    private let button = HighlightTrackingButton()
    private let iconView = UIImageView()
    private let glassTintColor: GlassBackgroundView.TintColor
    
    var action: (() -> Void)?
    
    init(icon: UIImage?, glassTintColor: GlassBackgroundView.TintColor, accessibilityLabel: String) {
        self.glassTintColor = glassTintColor
        
        super.init(frame: CGRect())
        
        self.iconView.image = icon
        self.iconView.isUserInteractionEnabled = false
        self.button.accessibilityLabel = accessibilityLabel
        self.button.addSubview(self.iconView)
        self.button.addTarget(self, action: #selector(self.pressed), for: .touchUpInside)
        self.glassView.contentView.addSubview(self.button)
        self.addSubview(self.glassView)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @objc private func pressed() {
        self.action?()
    }
    
    func update(size: CGSize, transition: ComponentTransition) {
        let bounds = CGRect(origin: CGPoint(), size: size)
        transition.setFrame(view: self.glassView, frame: bounds)
        self.glassView.update(size: size, cornerRadius: size.height * 0.5, isDark: true, tintColor: self.glassTintColor, isInteractive: true, transition: transition)
        transition.setFrame(view: self.button, frame: bounds)
        let iconSize = self.iconView.image?.size ?? CGSize()
        transition.setFrame(view: self.iconView, frame: CGRect(origin: CGPoint(x: floorToScreenPixels((size.width - iconSize.width) / 2.0), y: floorToScreenPixels((size.height - iconSize.height) / 2.0)), size: iconSize))
    }
}

/// A polyline through `points`, round-joined by the layer that strokes it.
private func mediaEditorAIEditPath(_ points: [CGPoint], isClosed: Bool) -> CGPath {
    let path = CGMutablePath()
    guard let first = points.first else {
        return path
    }
    if points.count == 1 {
        path.move(to: first)
        path.addLine(to: first)
    } else {
        path.addLines(between: points)
    }
    if isClosed {
        path.closeSubpath()
    }
    return path
}

/// The loop a lasso closes: the stroke up to the point of its second half that comes back nearest to the start, so a
/// stroke that runs on past the start keeps one turn. Nil for a stroke too small to select anything.
private func mediaEditorAIEditLoop(_ stroke: [CGPoint]) -> (points: [CGPoint], closeIndex: Int, length: CGFloat)? {
    guard stroke.count >= 8, let start = stroke.first else {
        return nil
    }
    var closeIndex = stroke.count - 1
    var nearest = CGFloat.greatestFiniteMagnitude
    for i in (stroke.count / 2) ..< stroke.count {
        let distance = hypot(stroke[i].x - start.x, stroke[i].y - start.y)
        if distance < nearest {
            nearest = distance
            closeIndex = i
        }
    }
    let points = Array(stroke[0 ... closeIndex])
    let box = mediaEditorAIEditPath(points, isClosed: true).boundingBoxOfPath
    guard box.width >= mediaEditorAIEditMinimumSelection, box.height >= mediaEditorAIEditMinimumSelection else {
        return nil
    }
    var length: CGFloat = 0.0
    for i in 0 ..< points.count {
        let a = points[i]
        let b = points[(i + 1) % points.count]
        length += hypot(b.x - a.x, b.y - a.y)
    }
    return (points, closeIndex, length)
}

/// Telegram's star sparkles (`Premium/Stars/Particle`) twinkling over `box`, with the cut-out outline's emitter technique
/// (StickerCutoutOutlineView.swift:74-90: a white cell, its alpha over life set by a `valueOverLife` behaviour).
private func mediaEditorAIEditSparkles(frame: CGRect, box: CGRect) -> CAEmitterLayer {
    let layer = CAEmitterLayer()
    layer.frame = frame
    layer.emitterShape = .rectangle
    layer.emitterMode = .surface
    layer.emitterPosition = CGPoint(x: box.midX, y: box.midY)
    layer.emitterSize = CGSize(width: box.width * 0.85, height: box.height * 0.85)
    layer.beginTime = CACurrentMediaTime()
    
    let cell = CAEmitterCell()
    cell.contents = generateTintedImage(image: UIImage(bundleImageName: "Premium/Stars/Particle"), color: .white)?.cgImage
    cell.color = UIColor.white.cgColor
    cell.birthRate = 9.0
    cell.lifetime = 1.3
    cell.velocity = 0.0
    cell.scale = 0.3
    cell.scaleRange = 0.1
    cell.spinRange = 1.5
    let alphaBehavior = CAEmitterCell.createEmitterBehavior(type: "valueOverLife")
    alphaBehavior.setValue("color.alpha", forKey: "keyPath")
    alphaBehavior.setValue([0.0, 0.9, 0.9, 0.0], forKey: "values")
    cell.setValue([alphaBehavior], forKey: "emitterBehaviors")
    layer.emitterCells = [cell]
    return layer
}

/// The photo the editor works on, before its tools and entities, handed over off the main queue (`MediaEditor.processImage`).
private func mediaEditorAIEditSourceImage(_ mediaEditor: MediaEditor) -> Signal<UIImage, MediaEditorAIEditError> {
    return Signal { subscriber in
        mediaEditor.processImage { image, _ in
            subscriber.putNext(image)
            subscriber.putCompletion()
        }
        return EmptyDisposable
    }
    |> timeout(5.0, queue: Queue.concurrentDefaultQueue(), alternate: .fail(.generic))
}
