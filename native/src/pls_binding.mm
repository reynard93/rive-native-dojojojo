#include "rive_native/external.hpp"
#include "rive_native/external_objc.h"
#include "rive_native/rive_binding.hpp"
#include "renderer_context.hpp"
#include "rive/renderer/metal/render_context_metal_impl.h"
#include "rive/renderer/rive_renderer.hpp"
#include "rive/renderer/rive_render_factory.hpp"
#include "rive/shapes/paint/color.hpp"
#include "rive/core/binary_reader.hpp"
#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
#include "rive/renderer/cmd/deferred_session.hpp"
#include "rive_native/deferred_consumer.hpp"
#include "rive_native/deferred_host.hpp"
#endif
#include <mutex>
#include <unordered_map>
#include <stdio.h>

// Compile-time diagnostics — will appear as warnings during build.
#ifdef RIVE_CANVAS
#pragma message("[rive diag] RIVE_CANVAS is defined")
#else
#pragma message("[rive diag] RIVE_CANVAS is NOT defined")
#endif
#ifdef WITH_RIVE_SCRIPTING
#pragma message("[rive diag] WITH_RIVE_SCRIPTING is defined")
#else
#pragma message("[rive diag] WITH_RIVE_SCRIPTING is NOT defined")
#endif

/// Calls from the Flutter plugin come in on a different thread so we use a
/// mutex to ensure we're destroying/creating rive renderers without
/// concurrently changing our shared state.
std::mutex g_mutex;

#ifdef RIVE_NATIVE_SHARED
// For shared/test builds we don't link the real preCommitCallback from the
// plugin.
void preCommitCallback(id<MTLCommandBuffer> /*commandBuffer*/,
                       void* /*nativeRenderTexture*/,
                       void* /*renderer*/,
                       void* /*textureRegistry*/)
{
    // Intentionally empty/no-op for shared builds as they're used for testing.
}
#endif

class MetalTextureRenderer
#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
    : public rive_native::DeferredTextureHost
#endif
{
public:
    MetalTextureRenderer(void* nativeRenderTextureRetainedCF,
                         void* textureRegistryRetainedCF,
                         RiveNativeRendererContext* rendererContext,
                         id<MTLCommandQueue> queueARC,
                         ReadWriteRing* ring,
                         id<MTLTexture> texture0ARC,
                         id<MTLTexture> texture1ARC,
                         id<MTLTexture> texture2ARC,
                         uint32_t width,
                         uint32_t height) :
        m_textureRegistryRetainedCF(textureRegistryRetainedCF),
        m_ring(ring),
        m_nativeRenderTextureRetainedCF(nativeRenderTextureRetainedCF),
        m_renderContext(rive::ref_rcp(rendererContext)),
        m_queue(queueARC),
        m_width(width),
        m_height(height)
    {
        auto renderCtxImpl =
            m_renderContext->actual
                ->static_impl_cast<rive::gpu::RenderContextMetalImpl>();
        // Provide the command queue so ScriptedCanvas can create its own
        // command buffers for canvas flush cycles.
        renderCtxImpl->setCommandQueue(queueARC);
        m_renderTarget[0] = renderCtxImpl->makeRenderTarget(
            MTLPixelFormatBGRA8Unorm, width, height);
        m_renderTarget[0]->setTargetTexture(texture0ARC);
        m_renderTarget[1] = renderCtxImpl->makeRenderTarget(
            MTLPixelFormatBGRA8Unorm, width, height);
        m_renderTarget[1]->setTargetTexture(texture1ARC);
        m_renderTarget[2] = renderCtxImpl->makeRenderTarget(
            MTLPixelFormatBGRA8Unorm, width, height);
        m_renderTarget[2]->setTargetTexture(texture2ARC);
        m_renderer =
            std::make_unique<rive::RiveRenderer>(m_renderContext->actual.get());
    }

    ~MetalTextureRenderer()
    {
        // Balance __bridge_retained for objects owned as CF pointers.
        if (m_nativeRenderTextureRetainedCF)
        {
            CFRelease(m_nativeRenderTextureRetainedCF);
            m_nativeRenderTextureRetainedCF = nullptr;
        }
        if (m_textureRegistryRetainedCF)
        {
            CFRelease(m_textureRegistryRetainedCF);
            m_textureRegistryRetainedCF = nullptr;
        }
        // m_queue is ARC-managed; no CFRelease here (we balance it when
        // constructing).
    }

    uint32_t m_currentWriteIndex = 0;

    void begin(bool clear, uint32_t color)
    {
        uint32_t writeIndex = m_ring->nextWrite();
        m_currentWriteIndex = writeIndex;
        m_renderContext->actual->beginFrame({
            .renderTargetWidth = m_width,
            .renderTargetHeight = m_height,
            .loadAction = clear ? rive::gpu::LoadAction::clear
                                : rive::gpu::LoadAction::preserveRenderTarget,
            .clearColor = color,
        });
    }

    id<MTLTexture> currentTargetTexture()
    {
        return m_renderTarget[m_currentWriteIndex]->targetTexture();
    }

    void end(float devicePixelRatio)
    {
        id<MTLCommandBuffer> flushCommandBuffer = [m_queue commandBuffer];
        m_renderContext->actual->flush(
            {.renderTarget = m_renderTarget[m_currentWriteIndex].get(),
             .externalCommandBuffer = (__bridge void*)flushCommandBuffer});

        preCommitCallback(flushCommandBuffer,
                          m_nativeRenderTextureRetainedCF,
                          (void*)this,
                          m_textureRegistryRetainedCF);
        [flushCommandBuffer commit];
    }

    rive::RiveRenderer* renderer() { return m_renderer.get(); }

#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
    bool deferredFlush(float devicePixelRatio);
    // Draining while still foreground keeps the queued Metal work legal, the
    // paused flag then blocks new frames until resume.
    void deferredPause()
    {
        m_deferredPaused = true;
        drainDeferred();
    }
    void deferredResume() { m_deferredPaused = false; }
#endif

    uint32_t width() { return m_width; }
    uint32_t height() { return m_height; }

    RiveNativeRendererContext* renderContext() const
    {
        return m_renderContext.get();
    }

    ReadWriteRing* ring() { return m_ring; }

private:
    // retained CF pointer to Obj-C registry
    void* m_textureRegistryRetainedCF = nullptr;
    ReadWriteRing* m_ring = nullptr;
    // retained CF pointer to Obj-C texture wrapper
    void* m_nativeRenderTextureRetainedCF = nullptr;
    id<MTLCommandQueue> m_queue = nil; // ARC-managed
    rive::rcp<RiveNativeRendererContext> m_renderContext;
    rive::rcp<rive::gpu::RenderTargetMetal> m_renderTarget[3];
    std::unique_ptr<rive::RiveRenderer> m_renderer;
    uint32_t m_width = 0;
    uint32_t m_height = 0;
#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
    // Native backstop while backgrounded, iOS forbids Metal work in the
    // background. UI thread only, so no synchronization.
    bool m_deferredPaused = false;
#endif
};

void* createRiveRendererContext(void* gpuRetainedCF)
{
    // gpuRetainedCF was passed as __bridge_retained id<MTLDevice> from Obj-C.
    // Convert to ARC object for MakeContext, but keep the retained CF pointer
    // to release later in the context destructor.
    id<MTLDevice> deviceARC = (__bridge id<MTLDevice>)gpuRetainedCF;

    auto ctx = rive::gpu::RenderContextMetalImpl::MakeContext(deviceARC);
    return (void*)new RiveNativeRendererContext(std::move(ctx), gpuRetainedCF);
}

void destroyRiveRendererContext(void* contextPtr)
{
    RiveNativeRendererContext* context = (RiveNativeRendererContext*)contextPtr;
    if (context == nullptr)
    {
        return;
    }
    // RefCnt-managed; this will run the destructor which CFReleases the device.
    context->unref();
}

PLUGIN_API void* factoryFromRiveRendererContext(void* context)
{
    if (context == nullptr)
    {
        return nullptr;
    }
    return ((RiveNativeRendererContext*)context)->actual.get();
}

PLUGIN_API void* createRiveRenderer(void* textureRegistryRetainedCF,
                                    void* riveRenderContext,
                                    void* nativeRenderTextureRetainedCF,
                                    void* queueBridged,
                                    ReadWriteRing* ring,
                                    void* texture0Bridged,
                                    void* texture1Bridged,
                                    void* texture2Bridged,
                                    uint32_t width,
                                    uint32_t height)
{
    std::unique_lock<std::mutex> lock(g_mutex);

    // Convert bridged CF pointers into ARC objects
    id<MTLCommandQueue> queueARC = (__bridge id<MTLCommandQueue>)queueBridged;
    id<MTLTexture> tex0ARC = (__bridge id<MTLTexture>)texture0Bridged;
    id<MTLTexture> tex1ARC = (__bridge id<MTLTexture>)texture1Bridged;
    id<MTLTexture> tex2ARC = (__bridge id<MTLTexture>)texture2Bridged;

    MetalTextureRenderer* context =
        new MetalTextureRenderer(nativeRenderTextureRetainedCF,
                                 textureRegistryRetainedCF,
                                 (RiveNativeRendererContext*)riveRenderContext,
                                 queueARC,
                                 ring,
                                 tex0ARC,
                                 tex1ARC,
                                 tex2ARC,
                                 width,
                                 height);

    // NOTE: Do NOT CFRelease textureRegistryRetainedCF or
    // nativeRenderTextureRetainedCF here, because MetalTextureRenderer owns
    // them as retained CF pointers and will CFRelease in its destructor.

    return context;
}

void destroyRiveRenderer(void* renderer)
{
    if (renderer == nullptr)
    {
        return;
    }
    MetalTextureRenderer* pls = static_cast<MetalTextureRenderer*>(renderer);
#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
    // Finish any in flight replay before the renderer dies.
    pls->drainDeferred();
#endif
    delete pls;
}

EXPORT void* nativeTexture(MetalTextureRenderer* renderer)
{
    return (__bridge void*)renderer->currentTargetTexture();
}

// Deferred only: a texture with no session attached has nothing to draw with.
EXPORT rive::Renderer* makeRenderer(MetalTextureRenderer* renderer)
{
#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
    if (renderer != nullptr)
    {
        return renderer->deferredScreenRenderer();
    }
#endif
    return nullptr;
}

void riveLock() { g_mutex.lock(); }
void riveUnlock() { g_mutex.unlock(); }

EXPORT bool clear(MetalTextureRenderer* renderer, bool clear, uint32_t color)
{
#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
    if (renderer != nullptr && renderer->deferredSession() != nullptr)
    {
        // No GPU work in deferred mode, stash the clear for replay.
        renderer->deferredClear(clear, color);
        return true;
    }
    rive_native::warnNoDeferredSession();
#endif
    return false;
}

EXPORT bool flush(MetalTextureRenderer* renderer, float devicePixelRatio)
{
#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
    if (renderer != nullptr && renderer->deferredSession() != nullptr)
    {
        return renderer->deferredFlush(devicePixelRatio);
    }
#endif
    return false;
}

#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
// Replays recorded frames into the Flutter texture ring. Runs on whichever
// thread calls the replay.
class MetalTextureFrameSink : public rive_native::HostFrameSink
{
public:
    MetalTextureFrameSink(MetalTextureRenderer* renderer,
                          bool clear,
                          uint32_t color) :
        HostFrameSink(clear, color, renderer->screenTarget()),
        m_renderer(renderer)
    {}

    rive::gpu::RenderContext* renderContext() override
    {
        return m_renderer->renderContext()->actual.get();
    }

    rive::Renderer* beginScreen(uint64_t target,
                                bool clear,
                                uint32_t color) override
    {
        // One texture renderer is one Flutter texture, and the base sink has
        // already refused every target but this renderer's.
        (void)target;
        m_renderer->begin(clear, color);
        return m_renderer->renderer();
    }

private:
    MetalTextureRenderer* m_renderer;
};

// Runs at most once per recorded frame, so an idle producer means an idle
// consumer.
bool MetalTextureRenderer::deferredFlush(float devicePixelRatio)
{
    // Backgrounded, enqueue nothing so no Metal work submits.
    if (m_deferredPaused)
    {
        return true;
    }
    rive_native::DeferredFrameJob job;
    if (!snapshotDeferredFrame(job))
    {
        return true;
    }
    // Replay and present on the session's worker; a producer outrunning
    // replay blocks in enqueue.
    job.consumer->enqueue([this, job, devicePixelRatio] {
        MetalTextureFrameSink sink(this, job.doClear, job.color);
        rive_native::replayDeferredFrame(
            job, sink, [&] { end(devicePixelRatio); });
    });
    return true;
}

// Pass null to detach the session.
EXPORT void riveTextureUseDeferredSession(MetalTextureRenderer* renderer,
                                          void* sessionPtr)
{
    if (renderer == nullptr)
    {
        return;
    }
    renderer->useDeferredSession(
        static_cast<rive::cmd::DeferredSession*>(sessionPtr));
}

// iOS lifecycle gate: pause before the app backgrounds, resume on foreground.
EXPORT void riveTextureDeferredPause(MetalTextureRenderer* renderer)
{
    if (renderer != nullptr && renderer->deferredSession() != nullptr)
    {
        renderer->deferredPause();
    }
}
EXPORT void riveTextureDeferredResume(MetalTextureRenderer* renderer)
{
    if (renderer != nullptr && renderer->deferredSession() != nullptr)
    {
        renderer->deferredResume();
    }
}
#endif

static id<MTLDevice> _metalDevice = nil;
static id<MTLCommandQueue> _metalCommandQueue = nil;

void setGPU(void* gpu, void* queue)
{
    // Borrowed pointers here (we did not __bridge_retained in the caller for
    // setGPU).
    _metalDevice = (__bridge id<MTLDevice>)gpu;
    _metalCommandQueue = (__bridge id<MTLCommandQueue>)queue;
}

EXPORT void* getGPU() { return (__bridge void*)_metalDevice; }

EXPORT void* getQueue() { return (__bridge void*)_metalCommandQueue; }
