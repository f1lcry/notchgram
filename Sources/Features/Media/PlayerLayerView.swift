import AVFoundation
import AppKit
import SwiftUI

/// A bare `AVPlayerLayer` host.
///
/// **Never use SwiftUI's `VideoPlayer` in this app.** On macOS 26.6 the
/// _AVKit_SwiftUI shim aborts the whole process while instantiating its view
/// metadata ("failed to demangle superclass of VideoPlayerView from mangled
/// name 'So12AVPlayerViewC'") — reproduced deterministically by the
/// fast-scroll stress the moment a GIF bubble materialises in the LazyVStack.
/// That abort was the founder's fast-scroll crash. A plain layer host has no
/// metadata edge to fall off, draws no controls chrome (which the inline
/// bubbles do not want), and serves the GIF loop, the round video note and
/// the media viewer alike.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    final class HostView: NSView {
        override func makeBackingLayer() -> CALayer { AVPlayerLayer() }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        init() {
            super.init(frame: .zero)
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("unused") }
    }

    func makeNSView(context: Context) -> HostView {
        let view = HostView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        return view
    }

    func updateNSView(_ view: HostView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
        view.playerLayer.videoGravity = gravity
    }
}
