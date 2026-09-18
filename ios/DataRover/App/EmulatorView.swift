// EmulatorView.swift — Metal framebuffer view: 480x320 2bpp guest buffer
// rendered aspect-fit, paced by a CADisplayLink.
//
// Frame path: each tick reads the ABI pointer via coreFramebuffer(of:).
// NULL frames (pre-boot / non-RAM-backed mapping per the header contract)
// are skipped. Non-NULL frames are expanded 2bpp -> RGBA8 on the CPU into
// a persistent staging buffer, uploaded to one persistent MTLTexture, and
// drawn as an aspect-fit textured quad (letterboxed on black). No per-frame
// allocation: texture, pipeline, sampler, queue, and staging all persist.
//
// Guest word order: the 2bpp words are little-endian guest DRAM words.
// Byte i of the ABI buffer holds pixels 4i..4i+3 starting at the MSB
// pair, matching screen_update's BIT(pixels, 30 - 2*(x&15), 2) readout:
// within each byte, pixel (x&3)==0 is bits 7-6, (x&3)==3 is bits 1-0.
// Grayscale levels mirror the driver's LEVEL table { 0xff, 0xaa, 0x55, 0x00 }.
//
// The core free-runs its own emulation thread (datarover_create boots
// running_machine::run() on a worker); the display link only drives the
// blit, never frame advance.
import MetalKit
import SwiftUI

/// Observable emulation session: owns the core handle lifecycle.
final class EmulatorSession: ObservableObject {
    /// Opaque core handle, or nil before boot / after teardown.
    private(set) var handle: UnsafeMutableRawPointer?
    /// False once teardown begins; gates the blit path off the worker.
    private(set) var alive = true
    /// Non-nil when datarover_create returned NULL (missing ROM/NVRAM);
    /// the container renders this instead of a black framebuffer view.
    private(set) var bootError: String?

    init(nvramDir: String, cfgDir: String, romPath: String) {
        handle = coreCreate(nvram: nvramDir, cfg: cfgDir, rom: romPath)
        if handle == nil {
            alive = false
            bootError = "Boot failed: ROM not found at \(romPath). Re-import the MagicCap-USA image."
        }
    }

    func invalidate() { alive = false }

    deinit {
        invalidate()
        coreDestroy(handle)
    }
}

/// UIViewRepresentable MTKView rendering the guest framebuffer aspect-fit.
struct EmulatorView: UIViewRepresentable {
    var session: EmulatorSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = true
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = true
        mtkView.delegate = context.coordinator
        context.coordinator.attach(view: mtkView)
        return mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.detach()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MTKViewDelegate {
        private let session: EmulatorSession
        private weak var view: MTKView?
        private var displayLink: CADisplayLink?
        private var queue: MTLCommandQueue?
        private var texture: MTLTexture?
        private var pipeline: MTLRenderPipelineState?
        private var sampler: MTLSamplerState?
        // Persistent RGBA8 staging: 480*320*4 bytes, reused every frame.
        private var staging = [UInt8](repeating: 0, count: 480 * 320 * 4)

        // Grayscale levels mirroring the driver's LEVEL table.
        private static let levels: [UInt8] = [0xff, 0xaa, 0x55, 0x00]

        // Runtime-compiled blit shader: fullscreen triangle textured quad.
        // uv (0,0) is the first uploaded texel (guest top-left); the CPU
        // side passes the aspect-fit NDC scale so the drawable letterboxes.
        private static let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        struct VSOut { float4 pos [[position]]; float2 uv; };
        vertex VSOut blitVertex(uint vid [[vertex_id]], constant float2 *scale [[buffer(0)]]) {
            float2 pos[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
            float2 uv[3] = { float2(0.0, 1.0), float2(2.0, 1.0), float2(0.0, -1.0) };
            VSOut out;
            out.pos = float4(pos[vid] * (*scale), 0.0, 1.0);
            out.uv = uv[vid];
            return out;
        }
        fragment float4 blitFragment(VSOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]]) {
            return tex.sample(smp, in.uv);
        }
        """

        init(session: EmulatorSession) {
            self.session = session
        }

        func attach(view: MTKView) {
            self.view = view
            guard let device = view.device else { return }
            queue = device.makeCommandQueue()
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: 480, height: 320,
                mipmapped: false)
            desc.usage = [.shaderRead]
            desc.storageMode = .shared
            texture = device.makeTexture(descriptor: desc)
            do {
                let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
                let pipeDesc = MTLRenderPipelineDescriptor()
                pipeDesc.vertexFunction = library.makeFunction(name: "blitVertex")
                pipeDesc.fragmentFunction = library.makeFunction(name: "blitFragment")
                pipeDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
                pipeline = try device.makeRenderPipelineState(descriptor: pipeDesc)
            } catch {
                pipeline = nil
            }
            let samplerDesc = MTLSamplerDescriptor()
            samplerDesc.minFilter = .linear
            samplerDesc.magFilter = .linear
            samplerDesc.sAddressMode = .clampToEdge
            samplerDesc.tAddressMode = .clampToEdge
            sampler = device.makeSamplerState(descriptor: samplerDesc)
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func detach() {
            session.invalidate()
            displayLink?.invalidate()
            displayLink = nil
            view = nil
            queue = nil
            texture = nil
            pipeline = nil
            sampler = nil
        }

        @objc private func tick() {
            view?.draw()
        }

        // MARK: MTKViewDelegate

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            // Snapshot coordinator state at entry: detach() nils these on
            // teardown while the display link may still fire once, and
            // KERN_INVALID_ADDRESS at 0x40 is an ivar read off a freed
            // Coordinator (texture/pipeline/sampler/queue ivars).
            guard let sessionHandle = session.handle,
                  let texture = texture,
                  let pipeline = pipeline,
                  let sampler = sampler,
                  let queue = queue else { return }
            // The core clears its live-machine pointer on exit while the
            // handle stays non-nil until destroy: re-resolve liveness via
            // a zero-size probe is impossible, so gate on session.alive.
            guard session.alive else { return }
            let (bytes, size) = coreFramebuffer(of: sessionHandle)
            guard let bytes, size == 480 * 320 / 4,
                  let drawable = view.currentDrawable else { return }
            expand2bpp(src: bytes, count: size)
            let region = MTLRegionMake2D(0, 0, 480, 320)
            staging.withUnsafeBytes { buf in
                texture.replace(region: region, mipmapLevel: 0,
                                withBytes: buf.baseAddress!, bytesPerRow: 480 * 4)
            }
            // Aspect-fit NDC scale: min-fit of 480x320 into the drawable.
            let dw = Float(drawable.texture.width)
            let dh = Float(drawable.texture.height)
            let fit = min(dw / 480, dh / 320)
            var scale = SIMD2<Float>(480 * fit / dw, 320 * fit / dh)
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            pass.colorAttachments[0].storeAction = .store
            guard let buffer = queue.makeCommandBuffer(),
                  let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            buffer.present(drawable)
            buffer.commit()
        }

        /// Expand `count` 2bpp bytes into the persistent RGBA8 staging buffer.
        /// Pixel (x&3)==0 reads bits 7-6 down to (x&3)==3 at bits 1-0.
        private func expand2bpp(src: UnsafePointer<UInt8>, count: Int) {
            let levels = Self.levels
            staging.withUnsafeMutableBytes { raw in
                let dst = raw.bindMemory(to: UInt8.self).baseAddress!
                for i in 0 ..< count {
                    let byte = src[i]
                    let base = i * 16 // 4 pixels * 4 bytes
                    // Unrolled: 4 pixels per source byte, MSB pair first.
                    dst[base + 0] = levels[Int((byte >> 6) & 0x3)]
                    dst[base + 1] = dst[base + 0]
                    dst[base + 2] = dst[base + 0]
                    dst[base + 3] = 0xff
                    dst[base + 4] = levels[Int((byte >> 4) & 0x3)]
                    dst[base + 5] = dst[base + 4]
                    dst[base + 6] = dst[base + 4]
                    dst[base + 7] = 0xff
                    dst[base + 8] = levels[Int((byte >> 2) & 0x3)]
                    dst[base + 9] = dst[base + 8]
                    dst[base + 10] = dst[base + 8]
                    dst[base + 11] = 0xff
                    dst[base + 12] = levels[Int(byte & 0x3)]
                    dst[base + 13] = dst[base + 12]
                    dst[base + 14] = dst[base + 12]
                    dst[base + 15] = 0xff
                }
            }
        }
    }
}
