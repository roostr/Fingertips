//  Copyright 2011-2023 Mapbox, Inc. All rights reserved.

import Foundation
import UIKit

@objc(MBXFingerTipView)
class FingerTipView: UIImageView {
    var timestamp: TimeInterval?
    var shouldAutomaticallyRemoveAfterTimeout: Bool?
    var fadingOut: Bool = false
}

@objc (MBXFingerTipOverlayWindow)
class FingerTipOverlayWindow: UIWindow {
    override var rootViewController: UIViewController? {
        set {
            super.rootViewController = newValue
        }

        get {
            return FingerTipWindow.fingerTipWindow?.rootViewController ?? super.rootViewController
        }
    }
}

@objc (MBXFingerTipWindow)
public class FingerTipWindow: UIWindow {

    @objc public static var fingerTipWindow: FingerTipWindow? {
        return UIApplication.shared.windows.compactMap({ $0 as? FingerTipWindow }).first
    }

    @objc public var touchAlpha: CGFloat         = 0.5
    @objc public var fadeDuration: TimeInterval  = 0.3
    @objc public var strokeColor: UIColor        = .black
    @objc public var fillColor: UIColor          = .white

    private var active: Bool = false

    // if set to 'true' the touches are shown even when no external screen is connected
    @objc public var alwaysShowTouches: Bool = false {
        didSet {
            if oldValue != alwaysShowTouches {
                updateFingertipsAreActive()
            }
        }
    }

    private var _touchImage: UIImage? = nil
    var touchImage: UIImage {
        if _touchImage == nil {
            let clipPath = UIBezierPath(rect: CGRect(x: 0, y: 0, width: 50, height: 50))

            UIGraphicsBeginImageContextWithOptions(clipPath.bounds.size, false, 0)

            let drawPath = UIBezierPath(arcCenter: CGPoint(x: 25, y: 25), radius: 22, startAngle: 0, endAngle: 2 * CGFloat.pi, clockwise: true)
            drawPath.lineWidth = 2

            strokeColor.setStroke()
            fillColor.setFill()

            drawPath.stroke()
            drawPath.fill()

            clipPath.addClip()

            _touchImage = UIGraphicsGetImageFromCurrentImageContext()

            UIGraphicsEndImageContext()
        }

        return _touchImage!
    }

    private var _overlayWindow: UIWindow?
    var overlayWindow: UIWindow {
        get {
            if _overlayWindow == nil {
                _overlayWindow = FingerTipOverlayWindow(frame: frame)
                _overlayWindow?.isUserInteractionEnabled = false
                _overlayWindow?.windowLevel = UIWindow.Level.statusBar
                _overlayWindow?.backgroundColor = .clear
                _overlayWindow?.isHidden = false
            }

            return _overlayWindow!
        }

        set {
            _overlayWindow = newValue
        }
    }
    var action: Bool?
    var fingerTipRemovalScheduled: Bool = false

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)

        commonInit()
    }

    override public init(frame: CGRect) {
        super.init(frame: frame)

        commonInit()
    }

    func commonInit() {
        NotificationCenter.default.addObserver(self, selector: #selector(updateFingertipsAreActive), name: UIScreen.didConnectNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateFingertipsAreActive), name: UIScreen.didDisconnectNotification, object: nil)
        if #available(iOS 11.0, *) {
            NotificationCenter.default.addObserver(self, selector: #selector(updateFingertipsAreActive), name: UIScreen.capturedDidChangeNotification, object: nil)
        }

        updateFingertipsAreActive()
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: UIScreen.didConnectNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIScreen.didDisconnectNotification, object: nil)
        if #available(iOS 11.0, *) {
            NotificationCenter.default.removeObserver(self, name: UIScreen.capturedDidChangeNotification, object: nil)
        }
    }

    func anyScreenIsCaptured() -> Bool {
        let capturedScreen: UIScreen?
        if #available(iOS 11.0, *) {
            capturedScreen = UIScreen.screens.first(where: \.isCaptured)
        } else {
            capturedScreen = UIScreen.screens.first(where: { $0.mirrored != nil })
        }
        return capturedScreen != nil
    }

    @objc func updateFingertipsAreActive() {
        let envDebug = (ProcessInfo.processInfo.environment["DEBUG_FINGERTIP_WINDOW"] as? NSString)?.boolValue

        if alwaysShowTouches || envDebug == true {
            active = true
        } else {
            active = anyScreenIsCaptured()
        }
    }

    public override func sendEvent(_ event: UIEvent) {
        if active {
            guard let allTouches: Set<UITouch> = event.allTouches else { return }

            for touch in allTouches {
                switch touch.phase {
                case .began, .moved, .stationary:
                    var touchView = overlayWindow.viewWithTag(touch.hashValue) as? FingerTipView

                    if touch.phase != .stationary && touchView != nil && touchView?.fadingOut == true {
                        touchView?.removeFromSuperview()
                        touchView = nil
                    }

                    if touchView == nil && touch.phase != .stationary {
                        touchView = FingerTipView(image: touchImage)
                        overlayWindow.addSubview(touchView!)
                    }

                    if touchView?.fadingOut == false {
                        touchView?.alpha = touchAlpha
                        touchView?.center = touch.location(in: overlayWindow)
                        touchView?.tag = touch.hashValue
                        touchView?.timestamp = touch.timestamp
                        touchView?.shouldAutomaticallyRemoveAfterTimeout = shouldAutomaticallyRemoveFingerTip(for: touch)
                    }
                    break
                case .ended, .cancelled:
                    removeFingerTip(with: touch.hashValue, animated: true)
                    break
                case .regionEntered, .regionMoved, .regionExited:
                    fallthrough
                @unknown default:
                    break
                }
            }
        }

        super.sendEvent(event)
        scheduleFingerTipRemoval()
    }

    func scheduleFingerTipRemoval() {
        if fingerTipRemovalScheduled {
            return
        }

        fingerTipRemovalScheduled = true
        perform(#selector(removeInactiveFingerTips), with: nil, afterDelay: 0.1)
    }

    func cancelScheduledFingerTipRemoval() {
        fingerTipRemovalScheduled = true
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(removeInactiveFingerTips), object: nil)
    }

    @objc func removeInactiveFingerTips() {
        fingerTipRemovalScheduled = false

        let now = ProcessInfo.processInfo.systemUptime
        let REMOVAL_DELAY = 0.2

        for touchView in overlayWindow.subviews {
            if let touchView = touchView as? FingerTipView {
                if touchView.shouldAutomaticallyRemoveAfterTimeout == true && now > touchView.timestamp ?? 0 + REMOVAL_DELAY {
                    removeFingerTip(with: touchView.tag, animated: true)
                }
            }
        }

        if overlayWindow.subviews.count > 0 {
            scheduleFingerTipRemoval()
        }
    }

    func removeFingerTip(with hash: Int, animated: Bool) {
        guard let touchView = overlayWindow.viewWithTag(hash) as? FingerTipView else { return }

        if touchView.fadingOut == true {
            return
        }

        UIView.animate(withDuration: fadeDuration) {
            touchView.alpha = 0
            touchView.frame = CGRect(x: touchView.center.x - touchView.frame.size.width / 1.5,
                                     y: touchView.center.y - touchView.frame.size.height / 1.5,
                                     width: touchView.frame.size.width * 1.5,
                                     height: touchView.frame.size.height * 1.5)
        }

        touchView.fadingOut = true
        touchView.perform(#selector(removeFromSuperview), with: nil, afterDelay: fadeDuration)
    }

    func shouldAutomaticallyRemoveFingerTip(for touch: UITouch) -> Bool {

        var view = touch.view
        view = view?.hitTest(touch.location(in: view), with: nil)

        while view != nil {
            if view is UITableViewCell {
                for recognizer in touch.gestureRecognizers ?? [] {
                    if recognizer is UISwipeGestureRecognizer {
                        return true
                    }
                }
            } else if view is UITableView {
                if touch.gestureRecognizers?.count == 0 {
                    return true
                }
            }

            view = view?.superview
        }

        return false
    }
}

