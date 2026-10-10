#include "rive/rive_types.hpp"

#include "rive/renderer/rive_render_image.hpp"
#include "rive/renderer/gl/render_context_gl_impl.hpp"
#include "rive/renderer/rive_renderer.hpp"
#include "rive/renderer/gl/render_target_gl.hpp"
#include "rive/renderer/ore/ore_context.hpp"

#include <emscripten.h>
#include <emscripten/bind.h>
#include <emscripten/val.h>
#include <emscripten/html5.h>
using namespace emscripten;

#include <stdint.h>
#include <stdio.h>
#include <string>
#include <map>
#include <set>
#include <vector>

using namespace rive;
using namespace rive::gpu;

class WebGL2Renderer;
class WebGL2RenderImage;
class WebGL2RenderBuffer;

using PLSResourceID = uint64_t;
using WasmPtr = uint32_t;

static std::atomic<PLSResourceID> s_nextWebGL2BufferID;
static std::atomic<int> s_nextRendererID{0};

#define EXPORT extern "C" EMSCRIPTEN_KEEPALIVE

#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
#include "rive/renderer/cmd/deferred_session.hpp"
#include "rive_native/deferred_consumer.hpp"
#include "rive_native/deferred_host.hpp"
#endif

// Singleton RiveRenderFactory implementation for WebGL 2.
// All objects are context free and keyed to actual resources the the specific
// GL contexts.
class WebGL2Factory : public RiveRenderFactory
{
public:
    static WebGL2Factory* Instance()
    {
        static WebGL2Factory s_webGLFactory;
        return &s_webGLFactory;
    }

    // Register GL contexts for resource deletion notifications.
    void registerContext(WebGL2Renderer* renderer)
    {
        m_renderers.insert(renderer);
    }
    void unregisterContext(WebGL2Renderer* renderer)
    {
        m_renderers.erase(renderer);
    }

    // Hooks for WebGL 2 objects to notify all contexts when they get deleted.
    void onWebGL2BufferDeleted(WebGL2RenderBuffer*);

    rcp<RenderImage> decodeImage(Span<const uint8_t> encodedBytes) override;
    rcp<RenderBuffer> makeRenderBuffer(RenderBufferType,
                                       RenderBufferFlags,
                                       size_t sizeInBytes) override;

private:
    WebGL2Factory() = default;

    std::set<WebGL2Renderer*> m_renderers;
};

EM_JS(
    void,
    decode_image,
    (uintptr_t renderImage, uintptr_t imgDataPtr, int imgDataLength),
    {
        // clang-format off
          var images = Module["images"];
          if (!images)
          {
              images = new Map();
              Module["images"] = images;
          }

          // Copy out of the heap since a SharedArrayBuffer cannot back a Blob.
          // Use the live wasmMemory.buffer, a cached HEAP8 can detach on grow.
          var heap = new Uint8Array(wasmMemory.buffer);
          var sourceView = heap.subarray(imgDataPtr, imgDataPtr + imgDataLength);
          var buffer = new Uint8Array(imgDataLength);
          buffer.set(sourceView);
          var blob = new Blob([buffer]);
          if (typeof Image === "undefined" && typeof createImageBitmap !== "undefined") {
              // Workers have no Image, decode with createImageBitmap premultiplied
              // since browsers ignore UNPACK_PREMULTIPLY_ALPHA_WEBGL for ImageBitmap.
              createImageBitmap(blob, {premultiplyAlpha: "premultiply", colorSpaceConversion: "none"}).then(function(bitmap) {
                  images.set(renderImage, bitmap);
                  Module["_setWebImage"](renderImage, bitmap.width, bitmap.height);
              }).catch(function(err) {
                  // Surface decode failures instead of an unhandled rejection.
                  console.error("rive deferred worker: createImageBitmap failed (len=" + imgDataLength + ")", err);
              });
          } else {
              var image = new Image();
              images.set(renderImage, image);
              image.src = URL.createObjectURL(blob);
              image.onload = function() {
                  Module["_setWebImage"](renderImage, image.width, image.height);
              };
          }
        // clang-format on
    });

// RAII utility to set and restore the current GL context.
class ScopedGLContextMakeCurrent
{
public:
    ScopedGLContextMakeCurrent(EMSCRIPTEN_WEBGL_CONTEXT_HANDLE contextGL) :
        m_contextGL(contextGL),
        m_previousContext(emscripten_webgl_get_current_context())
    {
        if (m_contextGL == m_previousContext)
        {
            m_ok = m_contextGL != 0;
        }
        else
        {
            // Handle 0 reports success while binding nothing, and a handle
            // from another thread resolves to nothing at all. Either way GL
            // calls would land on an undefined GLctx and throw out of wasm.
            m_ok = m_contextGL != 0 &&
                   emscripten_webgl_make_context_current(m_contextGL) ==
                       EMSCRIPTEN_RESULT_SUCCESS;
        }
        if (!m_ok)
        {
            static int warnings = 0;
            if (warnings < 8)
            {
                warnings++;
                fprintf(stderr,
                        "rive_native: no GL context for handle %d on this "
                        "thread, skipping GL work\n",
                        (int)m_contextGL);
            }
        }
    }

    ~ScopedGLContextMakeCurrent()
    {
        // Restoring 0 would unbind the context and leave the next unguarded GL
        // call with nothing current, so leave ours bound instead.
        if (m_ok && m_previousContext != 0 && m_contextGL != m_previousContext)
        {
            emscripten_webgl_make_context_current(m_previousContext);
        }
    }

    // False when nothing is bound, callers must not issue GL.
    bool ok() const { return m_ok; }

private:
    const EMSCRIPTEN_WEBGL_CONTEXT_HANDLE m_contextGL;
    const EMSCRIPTEN_WEBGL_CONTEXT_HANDLE m_previousContext;
    bool m_ok;
};

EM_JS(void,
      upload_image,
      (EMSCRIPTEN_WEBGL_CONTEXT_HANDLE gl, uintptr_t renderImage),
      {
          var images = Module["images"];
          if (!images)
          {
              return;
          }

          var image = images.get(renderImage);
          if (!image)
          {
              return;
          }
          gl = GL.getContext(gl).GLctx;
          gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, true);
          gl.texImage2D(gl.TEXTURE_2D,
                        0,
                        gl.RGBA,
                        gl.RGBA,
                        gl.UNSIGNED_BYTE,
                        image);
          gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
      });

EM_JS(void, delete_image, (uintptr_t renderImage), {
    var images = Module["images"];
    if (!images)
    {
        return;
    }

    var image = images.get(renderImage);
    if (!image)
    {
        return;
    }
    // ImageBitmap (worker decode) must be closed explicitly.
    if (image.close)
    {
        image.close();
    }
    images.delete(renderImage);
});

// High-level, context agnostic RenderImage for the WebGL2 system. Wraps a blob
// of encoded image data, which is then decoded and uploaded to a texture on
// each separate context.
class WebGL2RenderImage
    : public LITE_RTTI_OVERRIDE(RenderImage, WebGL2RenderImage)
{
public:
    WebGL2RenderImage(Span<const uint8_t> encodedBytes)
    {
        m_Width = 0;
        m_Height = 0;

        ref();
        decode_image(reinterpret_cast<uintptr_t>(this),
                     // decode_image copies these so we don't need to allocate
                     // storage for them
                     reinterpret_cast<uintptr_t>(encodedBytes.data()),
                     encodedBytes.size());
    }

    ~WebGL2RenderImage()
    {
        ScopedGLContextMakeCurrent makeCurrent(m_contextGL);
        delete_image(reinterpret_cast<uintptr_t>(this));
        m_renderImage.reset();
    }

    void setWebImage(int width, int height)
    {
        m_Width = width;
        m_Height = height;
        m_readyToUpload = true;
        decodedAsync();
    }

private:
    bool m_readyToUpload = false;
    EMSCRIPTEN_WEBGL_CONTEXT_HANDLE m_contextGL = 0;
    rcp<RiveRenderImage> m_renderImage;

public:
    RenderImage* prep(WebGL2Renderer* webglRenderer,
                      const EMSCRIPTEN_WEBGL_CONTEXT_HANDLE context);
};

EXPORT void setWebImage(WebGL2RenderImage* renderImage, int width, int height)
{
    renderImage->setWebImage(width, height);
    renderImage->unref();
}

// Shared object that holds the contents of a WebGL2Buffer. PLS buffers are
// synchronized to these contents on every draw.
class WebGL2BufferData : public RefCnt<WebGL2BufferData>
{
public:
    WebGL2BufferData(size_t sizeInBytes) : m_data(new uint8_t[sizeInBytes]) {}

    const uint8_t* contents() const { return m_data.get(); }

    uint8_t* writableAddress()
    {
        ++m_mutationID;
        return m_data.get();
    }

    // Used to know when a PLS buffer is out of sync.
    PLSResourceID mutationID() const { return m_mutationID; }

private:
    std::unique_ptr<uint8_t[]> m_data;
    PLSResourceID m_mutationID =
        1; // So a 0-initialized PLS buffer will be out of sync.
};

// High-level, context agnostic RenderBuffer for the WebGL2 system. Wraps the
// buffer contents in a shared CPU-side WebGL2BufferData object, against which
// low-level PLS buffers are synchronized.
class WebGL2RenderBuffer
    : public LITE_RTTI_OVERRIDE(RenderBuffer, WebGL2RenderBuffer)
{
public:
    WebGL2RenderBuffer(RenderBufferType type,
                       RenderBufferFlags flags,
                       size_t sizeInBytes) :
        lite_rtti_override(type, flags, sizeInBytes),
        m_bufferData(make_rcp<WebGL2BufferData>(sizeInBytes))
    {}

    ~WebGL2RenderBuffer()
    {
        WebGL2Factory::Instance()->onWebGL2BufferDeleted(this);
    }

    PLSResourceID uniqueID() const { return m_uniqueID; }
    rcp<WebGL2BufferData> bufferData() { return m_bufferData; }

    void* onMap() override { return m_bufferData->writableAddress(); }
    void onUnmap() override {}

private:
    const PLSResourceID m_uniqueID = ++s_nextWebGL2BufferID;
    rcp<WebGL2BufferData> m_bufferData;
};

// Wraps a PLS renderBuffer and keeps its contents synchronized to the given
// WebGL2BufferData.
class PLSSynchronizedBuffer
{
public:
    PLSSynchronizedBuffer(WebGL2Renderer*, WebGL2RenderBuffer*);

    ~PLSSynchronizedBuffer()
    {
        ScopedGLContextMakeCurrent makeCurrent(m_contextGL);
        m_renderBuffer.reset();
    }

    rcp<RenderBuffer> get()
    {
        if (m_mutationID != m_webglBufferData->mutationID())
        {
            ScopedGLContextMakeCurrent makeCurrent(m_contextGL);
            void* contents = m_renderBuffer->map();
            memcpy(contents,
                   m_webglBufferData->contents(),
                   m_renderBuffer->sizeInBytes());
            m_mutationID = m_webglBufferData->mutationID();
            m_renderBuffer->unmap();
        }
        return m_renderBuffer;
    }

private:
    const EMSCRIPTEN_WEBGL_CONTEXT_HANDLE m_contextGL;
    const rcp<WebGL2BufferData> m_webglBufferData;
    rcp<RenderBuffer> m_renderBuffer;
    PLSResourceID m_mutationID =
        0; // Tells when we are out of sync with the WebGL2BufferData.
};

// Wraps a tightly coupled RiveRenderer, RenderContext, and ore::Context, all
// bound to a single WebGL2 context. This is the single owner of both the PLS
// rendering context and the Ore GPU scripting context for a given canvas.
#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
class WebGL2Renderer : public RiveRenderer,
                       public rive_native::DeferredTextureHost
#else
class WebGL2Renderer : public RiveRenderer
#endif
{
public:
    WebGL2Renderer(std::unique_ptr<RenderContext> renderContext,
                   int width,
                   int height) :
        RiveRenderer(renderContext.get()),
        m_renderContext(std::move(renderContext)),
        m_rendererID(++s_nextRendererID)
    {
#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
        // Match the immediate path's opaque default before any recorded clear.
        m_deferredColor = 0xff000000;
#endif
        // Same GL context as the PLS RenderContext.
        m_oreContext = m_renderContext->impl()->makeOreContext();
        resize(width, height);
    }

    ~WebGL2Renderer()
    {
        // Destroy GL-owning members here, while our context is current: the
        // guard's scope ends before implicit member destruction would run.
        ScopedGLContextMakeCurrent makeCurrent(m_contextGL);
        m_oreContext.reset();
        m_plsSynchronizedBuffers.clear();
        m_renderTarget.reset();
        m_renderContext.reset();
    }

    EMSCRIPTEN_WEBGL_CONTEXT_HANDLE contextGL() const { return m_contextGL; }

    PLSResourceID currentFrameID() const { return m_currentFrameID; }

    RenderContext* gpuRenderContext() const { return m_renderContext.get(); }
    ore::Context* oreContext() const { return m_oreContext.get(); }

    RenderContextGLImpl* renderContextGL() const
    {
        return m_renderContext->static_impl_cast<RenderContextGLImpl>();
    }

    void resize(int width, int height)
    {
        GLint sampleCount = 0;
        ScopedGLContextMakeCurrent makeCurrent(m_contextGL);
        if (makeCurrent.ok())
        {
            glBindFramebuffer(GL_FRAMEBUFFER, 0);
            glGetIntegerv(GL_SAMPLES, &sampleCount);
        }
        m_renderTarget =
            make_rcp<FramebufferRenderTargetGL>(width, height, 0, sampleCount);
    }

    RenderContext::FrameDescriptor makeFrameDescriptor(
        gpu::LoadAction loadAction,
        ColorInt color)
    {
        RenderContext::FrameDescriptor frameDescriptor = {
            .renderTargetWidth = m_renderTarget->width(),
            .renderTargetHeight = m_renderTarget->height(),
            .loadAction = loadAction,
            .clearColor = color,
        };
        if (m_renderTarget->sampleCount() > 1)
        {
            // Use MSAA if we were given a canvas with 'antialias: true'.
            frameDescriptor.msaaSampleCount = m_renderTarget->sampleCount();
        }
        else if (!m_renderContext->platformFeatures()
                      .supportsRasterOrderingMode &&
                 !m_renderContext->platformFeatures().supportsAtomicMode)
        {
            // Always use MSAA if we don't have
            // WEBGL_shader_pixel_local_storage.
            frameDescriptor.msaaSampleCount = 4;
        }
        return frameDescriptor;
    }

    // "clear()" is our hook for the beginning of a frame.
    // TODO: Give this a better name!!
    void clear(ColorInt color)
    {
        m_renderContext->beginFrame(
            makeFrameDescriptor(gpu::LoadAction::clear, color));
        ++m_currentFrameID;
    }

#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
    // Hides the draining base method: the worker teardown orders drains; the
    // real ore context late binds here (no renderer at session creation). No
    // consumer bookkeeping: g_sessionConsumers is main-thread only.
    void useDeferredSession(rive::cmd::DeferredSession* session)
    {
        if (m_deferredSession == session)
        {
            return;
        }
        unbindDeferredSession();
        if (session != nullptr)
        {
            joinDeferredSession(session);
            session->bindReplayCaps(rive::ore::ReplayCaps::from(*m_oreContext));
            // Scripts ran at import with no device at all. This is the first
            // one to exist, so hand it over too: a size-less gpuCanvas() needs
            // it when layout finally calls resize().
            session->bindRenderContext(gpuRenderContext());
        }
    }
    void unbindDeferredSession()
    {
        if (m_deferredSession != nullptr)
        {
            leaveDeferredSession();
        }
    }
    // This renderer's GL lives on the replay worker, so flush replays there.
    // The selector names the transferred OffscreenCanvas for resizing.
    void markWorkerMode(std::string canvasSelector)
    {
        m_workerMode = true;
        m_workerCanvasSelector = std::move(canvasSelector);
    }
    bool workerMode() const { return m_workerMode; }
    const std::string& workerCanvasSelector() const
    {
        return m_workerCanvasSelector;
    }
    bool deferredFlush();
#endif

    void saveClipRect(float l, float t, float r, float b)
    {
        save();
        rcp<RenderPath> rect(WebGL2Factory::Instance()->makeEmptyRenderPath());
        rect->moveTo(l, t);
        rect->lineTo(r, t);
        rect->lineTo(r, b);
        rect->lineTo(l, b);
        rect->close();
        clipPath(rect.get());
    }

    void restoreClipRect() { restore(); }

    void drawImage(const RenderImage* renderImage,
                   const ImageSampler imageSampler,
                   BlendMode blendMode,
                   float opacity,
                   float additiveness) override
    {
        // Canvas textures are already RiveRenderImages — draw directly.
        if (lite_rtti_cast<const RiveRenderImage*>(renderImage) != nullptr)
        {
            RiveRenderer::drawImage(renderImage,
                                    ImageSampler::LinearClamp(),
                                    blendMode,
                                    opacity,
                                    additiveness);
            return;
        }
        LITE_RTTI_CAST_OR_RETURN(webglRenderImage,
                                 const WebGL2RenderImage*,
                                 renderImage);
        renderImage =
            ((WebGL2RenderImage*)webglRenderImage)->prep(this, m_contextGL);
        if (renderImage != nullptr)
        {
            // The renderImage is done decoding.
            RiveRenderer::drawImage(renderImage,
                                    ImageSampler::LinearClamp(),
                                    blendMode,
                                    opacity,
                                    additiveness);
        }
    }

    void drawImageMesh(const RenderImage* renderImage,
                       const ImageSampler imageSampler,
                       rcp<RenderBuffer> vertices_f32,
                       rcp<RenderBuffer> uvCoords_f32,
                       rcp<RenderBuffer> indices_u16,
                       uint32_t vertexCount,
                       uint32_t indexCount,
                       BlendMode blendMode,
                       float opacity,
                       float additiveness) override
    {
        // Canvas textures are already RiveRenderImages — draw directly.
        if (lite_rtti_cast<const RiveRenderImage*>(renderImage) != nullptr)
        {
            int currentGL = emscripten_webgl_get_current_context();
            if (currentGL != (int)m_contextGL)
            {
                fprintf(stderr,
                        "[drawImageMesh] CONTEXT MISMATCH! RiveRenderImage "
                        "img=%p rendererGL=%d currentGL=%d\n",
                        renderImage,
                        (int)m_contextGL,
                        currentGL);
            }
            RiveRenderer::drawImageMesh(renderImage,
                                        ImageSampler::LinearClamp(),
                                        std::move(vertices_f32),
                                        std::move(uvCoords_f32),
                                        std::move(indices_u16),
                                        vertexCount,
                                        indexCount,
                                        blendMode,
                                        opacity,
                                        additiveness);
            return;
        }
        LITE_RTTI_CAST_OR_RETURN(webglRenderImage,
                                 const WebGL2RenderImage*,
                                 renderImage);
        renderImage =
            ((WebGL2RenderImage*)webglRenderImage)->prep(this, m_contextGL);
        if (renderImage != nullptr)
        {
            // The renderImage is done decoding.
            LITE_RTTI_CAST_OR_RETURN(vertexBuffer,
                                     WebGL2RenderBuffer*,
                                     vertices_f32.get());
            LITE_RTTI_CAST_OR_RETURN(uvBuffer,
                                     WebGL2RenderBuffer*,
                                     uvCoords_f32.get());
            LITE_RTTI_CAST_OR_RETURN(indexBuffer,
                                     WebGL2RenderBuffer*,
                                     indices_u16.get());
            RiveRenderer::drawImageMesh(renderImage,
                                        ImageSampler::LinearClamp(),
                                        refPLSBuffer(vertexBuffer),
                                        refPLSBuffer(uvBuffer),
                                        refPLSBuffer(indexBuffer),
                                        vertexCount,
                                        indexCount,
                                        blendMode,
                                        opacity,
                                        additiveness);
        }
    }

    void drawImageMeshInstanced(const RenderImage* renderImage,
                                const ImageSampler imageSampler,
                                rcp<RenderBuffer> vertices_f32,
                                rcp<RenderBuffer> uvCoords_f32,
                                rcp<RenderBuffer> indices_u16,
                                uint32_t vertexCount,
                                uint32_t indexCount,
                                rcp<ImageMeshInstances> instances) override
    {
        // Canvas textures are already RiveRenderImages — draw directly.
        if (lite_rtti_cast<const RiveRenderImage*>(renderImage) != nullptr)
        {
            RiveRenderer::drawImageMeshInstanced(renderImage,
                                                 ImageSampler::LinearClamp(),
                                                 std::move(vertices_f32),
                                                 std::move(uvCoords_f32),
                                                 std::move(indices_u16),
                                                 vertexCount,
                                                 indexCount,
                                                 std::move(instances));
            return;
        }
        LITE_RTTI_CAST_OR_RETURN(webglRenderImage,
                                 const WebGL2RenderImage*,
                                 renderImage);
        renderImage =
            ((WebGL2RenderImage*)webglRenderImage)->prep(this, m_contextGL);
        if (renderImage != nullptr)
        {
            // The renderImage is done decoding.
            LITE_RTTI_CAST_OR_RETURN(vertexBuffer,
                                     WebGL2RenderBuffer*,
                                     vertices_f32.get());
            LITE_RTTI_CAST_OR_RETURN(uvBuffer,
                                     WebGL2RenderBuffer*,
                                     uvCoords_f32.get());
            LITE_RTTI_CAST_OR_RETURN(indexBuffer,
                                     WebGL2RenderBuffer*,
                                     indices_u16.get());
            RiveRenderer::drawImageMeshInstanced(renderImage,
                                                 ImageSampler::LinearClamp(),
                                                 refPLSBuffer(vertexBuffer),
                                                 refPLSBuffer(uvBuffer),
                                                 refPLSBuffer(indexBuffer),
                                                 vertexCount,
                                                 indexCount,
                                                 std::move(instances));
        }
    }

    void flush()
    {
        ScopedGLContextMakeCurrent makeCurrent(m_contextGL);
        if (!makeCurrent.ok())
        {
            return;
        }
        m_renderContext->flush({.renderTarget = m_renderTarget.get()});
    }

    // Delete our corresponding PLS buffer when a WebGL2RenderBuffer is deleted.
    void onWebGL2BufferDeleted(PLSResourceID webglBufferID)
    {
        m_plsSynchronizedBuffers.erase(webglBufferID);
    }

private:
    rcp<RenderBuffer> refPLSBuffer(WebGL2RenderBuffer* wglBuff)
    {
        PLSSynchronizedBuffer& synchronizedBuffer =
            m_plsSynchronizedBuffers
                .try_emplace(wglBuff->uniqueID(), this, wglBuff)
                .first->second;
        return synchronizedBuffer.get();
    }

    const EMSCRIPTEN_WEBGL_CONTEXT_HANDLE m_contextGL =
        emscripten_webgl_get_current_context();

    std::unique_ptr<RenderContext> m_renderContext;
    std::unique_ptr<ore::Context> m_oreContext;
    rcp<FramebufferRenderTargetGL> m_renderTarget;

    std::map<PLSResourceID, PLSSynchronizedBuffer> m_plsSynchronizedBuffers;

    PLSResourceID m_currentFrameID = 0;
    const int m_rendererID;
#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
    bool m_workerMode = false;
    std::string m_workerCanvasSelector;
#endif
};

#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
// Replays recorded frames into this renderer's canvas.
class WebGLTextureFrameSink : public rive_native::HostFrameSink
{
public:
    WebGLTextureFrameSink(WebGL2Renderer* renderer,
                          bool clear,
                          ColorInt color) :
        HostFrameSink(clear, color, renderer->screenTarget()),
        m_renderer(renderer)
    {
        // One renderer is one canvas and its session's only display, so a
        // stale target id from before a repoint still presents here.
        m_acceptAnyScreenTarget = true;
    }

    rive::gpu::RenderContext* renderContext() override
    {
        return m_renderer->gpuRenderContext();
    }

    rive::Factory* factory() override
    {
        // The wasm build has no CPU image codecs, so replay decode must use
        // the browser async path, same as the immediate pipeline.
        return WebGL2Factory::Instance();
    }

    // The renderer owns the ore context, not the render context.
    rive::ore::Context* oreContext() override
    {
        return m_renderer->oreContext();
    }

    rive::Renderer* beginScreen(uint64_t target,
                                bool clear,
                                uint32_t color) override
    {
        // One WebGL2Renderer is one canvas, transferred to the replay worker
        // or not, and the base sink has already refused every target but this
        // canvas's.
        (void)target;
        m_renderer->gpuRenderContext()->beginFrame(
            m_renderer->makeFrameDescriptor(
                clear ? gpu::LoadAction::clear
                      : gpu::LoadAction::preserveRenderTarget,
                color));
        return m_renderer;
    }

    rive::Renderer* beginCanvasContent(rive::gpu::RenderCanvas* canvas,
                                       uint32_t clearColor) override
    {
        m_activeCanvas = canvas;
        // This override does not chain to the base, so it owes the canvas the
        // same backing the base would have given it.
        m_renderer->renderContextGL()->ensureCanvasBacking(canvas);
        auto* rc = m_renderer->gpuRenderContext();
        RenderContext::FrameDescriptor d{};
        d.renderTargetWidth = canvas->width();
        d.renderTargetHeight = canvas->height();
        d.loadAction = gpu::LoadAction::clear;
        d.clearColor = clearColor;
        rc->beginFrame(d);
        // Draws go through the renderer so async decoded images get prepped.
        // save isolates the canvas content renderer state.
        m_renderer->save();
        return m_renderer;
    }
    void endCanvasContent() override
    {
        if (m_activeCanvas == nullptr)
        {
            return;
        }
        m_renderer->restore();
        HostFrameSink::endCanvasContent();
    }

private:
    WebGL2Renderer* m_renderer;
};

bool WebGL2Renderer::deferredFlush()
{
    if (!m_deferredSession->endTargetFrame(screenTarget()))
    {
        // Another target on this session is still recording and owns the
        // window; this canvas keeps the last frame.
        return true;
    }
    if (!m_deferredSession->recordedThisFrame())
    {
        // Nothing recorded, the canvas keeps the last frame.
        return true;
    }
#if defined(__EMSCRIPTEN_PTHREADS__)
    // Set only for a canvas transferred to the replay worker, which owns this
    // renderer's GL context; the banner below marks the inline route instead.
    if (m_workerMode)
    {
        // The Dart render gate paces the producer so the queue never backlogs.
        rive_native::DeferredFrameJob job;
        if (!snapshotDeferredFrame(job))
        {
            return true;
        }
        job.consumer->enqueue([this, job] {
            // Runs on the worker that owns this renderer's GL context.
            ScopedGLContextMakeCurrent makeCurrent(m_contextGL);
            if (!makeCurrent.ok())
            {
                return;
            }
            WebGLTextureFrameSink sink(this, job.doClear, job.color);
            rive_native::replayDeferredFrame(job, sink, [&] {
                // Implicit swap presents the OffscreenCanvas when the worker
                // returns to the event loop.
                m_renderContext->flush({.renderTarget = m_renderTarget.get()});
            });
        });
        return true;
    }
#endif
    static bool bannered = false;
    if (!bannered)
    {
        bannered = true;
        fprintf(stderr,
                "rive_native: deferred replay active (web W1 inline)\n");
    }
    ScopedGLContextMakeCurrent makeCurrent(m_contextGL);
    if (!makeCurrent.ok())
    {
        // No context to replay into, drop the frame so the stream cannot grow.
        m_deferredSession->resetFrame();
        return true;
    }
    auto replayStart = std::chrono::steady_clock::now();
    auto* consumer = rive_native::deferredConsumerFor(m_deferredSession);
    consumer->addRecordUs(static_cast<uint64_t>(
        std::chrono::duration<double, std::micro>(replayStart - m_recordStart)
            .count()));
    auto noteReplayed = [&] {
        consumer->addReplayUs(static_cast<uint64_t>(
            std::chrono::duration<double, std::micro>(
                std::chrono::steady_clock::now() - replayStart)
                .count()));
        consumer->addFrame();
    };
    auto* replayer = &consumer->replayer();
    WebGLTextureFrameSink sink(this, m_deferredDoClear, m_deferredColor);
    replayer->replayFrame(*m_deferredSession, sink);
    if (!sink.began())
    {
        // Replay never opened the screen, reset so the stream cannot
        // accumulate.
        static int skips = 0;
        if (skips < 16)
        {
            skips++;
            fprintf(stderr,
                    "rive deferred: replay did not reach screen (2D stream "
                    "%zu bytes), resetting frame\n",
                    m_deferredSession->commandBuffer().commandBytes().size());
        }
        m_deferredSession->resetFrame();
        noteReplayed();
        return true;
    }
    m_renderContext->flush({.renderTarget = m_renderTarget.get()});
    m_deferredSession->resetFrame();
    if (replayer->droppedDraws() != 0)
    {
        fprintf(stderr,
                "rive deferred: %u draws DROPPED this frame (mixed factories "
                "or replay bug)\n",
                replayer->droppedDraws());
    }
    noteReplayed();
    ++m_currentFrameID;
    return true;
}
#endif

RenderImage* WebGL2RenderImage::prep(
    WebGL2Renderer* webglRenderer,
    const EMSCRIPTEN_WEBGL_CONTEXT_HANDLE context)
{
    // Only return the existing render image if its from the same context,
    // otherwise we need to re-upload.
    if (context == m_contextGL && m_renderImage)
    {
        return m_renderImage.get();
    }
    if (m_readyToUpload)
    {
        if (m_contextGL && m_renderImage)
        {
            // Make sure to reset image on old context.
            ScopedGLContextMakeCurrent makeCurrent(m_contextGL);
            m_renderImage = nullptr;
        }
        ScopedGLContextMakeCurrent makeCurrent(m_contextGL = context);
        if (!makeCurrent.ok())
        {
            // Uploading here would hit an unbound context, retry next draw.
            return nullptr;
        }
        GLuint textureId = 0;
        glGenTextures(1, &textureId);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, textureId);
        webglRenderer->renderContextGL()->state()->bindBuffer(
            GL_PIXEL_UNPACK_BUFFER,
            0);
        upload_image(emscripten_webgl_get_current_context(),
                     reinterpret_cast<uintptr_t>(this));
        glGenerateMipmap(GL_TEXTURE_2D);
        glTexParameteri(GL_TEXTURE_2D,
                        GL_TEXTURE_MIN_FILTER,
                        GL_LINEAR_MIPMAP_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        m_renderImage = make_rcp<RiveRenderImage>(
            webglRenderer->renderContextGL()->adoptImageTexture(m_Width,
                                                                m_Height,
                                                                textureId));
    }
    return m_renderImage.get();
}

PLSSynchronizedBuffer::PLSSynchronizedBuffer(WebGL2Renderer* webglRenderer,
                                             WebGL2RenderBuffer* webglBuffer) :
    m_contextGL(webglRenderer->contextGL()),
    m_webglBufferData(webglBuffer->bufferData())

{
    ScopedGLContextMakeCurrent makeCurrent(m_contextGL);
    m_renderBuffer = webglRenderer->renderContextGL()->makeRenderBuffer(
        webglBuffer->type(),
        webglBuffer->flags(),
        webglBuffer->sizeInBytes());
}

rcp<RenderImage> WebGL2Factory::decodeImage(Span<const uint8_t> encodedBytes)
{
    return make_rcp<WebGL2RenderImage>(encodedBytes);
}

rcp<RenderBuffer> WebGL2Factory::makeRenderBuffer(RenderBufferType type,
                                                  RenderBufferFlags flags,
                                                  size_t sizeInBytes)
{
    return make_rcp<WebGL2RenderBuffer>(type, flags, sizeInBytes);
}

void WebGL2Factory::onWebGL2BufferDeleted(WebGL2RenderBuffer* webglRenderBuffer)
{
    for (WebGL2Renderer* renderer : m_renderers)
    {
        renderer->onWebGL2BufferDeleted(webglRenderBuffer->uniqueID());
    }
}

// JS Hooks.
Factory* riveFactory() { return WebGL2Factory::Instance(); }

WasmPtr decodeImage(WasmPtr factoryPtr, emscripten::val byteArray)
{
    std::vector<unsigned char> vector;

    const auto l = byteArray["byteLength"].as<unsigned>();
    vector.resize(l);

    emscripten::val memoryView{emscripten::typed_memory_view(l, vector.data())};
    memoryView.call<void>("set", byteArray);

    auto actualFactory = factoryPtr == 0 ? riveFactory() : (Factory*)factoryPtr;
    rcp rcpImage = actualFactory->decodeImage(vector);
    // NOTE: ref so the image does not get disposed after the scope of this
    // function.
    rcpImage->ref();
    return (WasmPtr)rcpImage.get();
}

WasmPtr makeRenderer(int width, int height)
{
    if (auto renderContext = RenderContextGLImpl::MakeContext())
    {
        auto ptr = new WebGL2Renderer(std::move(renderContext), width, height);
        return (WasmPtr)ptr;
    }
    return 0;
}

#if defined(RIVE_CANVAS) && defined(RIVE_ORE) &&                               \
    defined(__EMSCRIPTEN_PTHREADS__)
// Session to GL context, so teardown can make the owning context current.
// Touched only on the worker.
static std::map<void*, EMSCRIPTEN_WEBGL_CONTEXT_HANDLE> s_workerSessionGL;

// Renderer to bound session; teardown unbinds every renderer still bound.
static std::map<WebGL2Renderer*, void*> s_workerRendererSession;

static void workerBindSessionRenderer(rive::cmd::DeferredSession* session,
                                      WebGL2Renderer* renderer)
{
    if (session != nullptr)
    {
        s_workerRendererSession[renderer] = (void*)session;
    }
    else
    {
        s_workerRendererSession.erase(renderer);
    }
}

// Detached renderers park in the reuse pool holding their last frame
// (preserveDrawingBuffer); wipe it, ungated by replay-left scissor/mask.
static void workerWipeDetachedRenderer(WebGL2Renderer* renderer)
{
    ScopedGLContextMakeCurrent makeCurrent(renderer->contextGL());
    if (makeCurrent.ok())
    {
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glDisable(GL_SCISSOR_TEST);
        glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
        glClearColor(0, 0, 0, 0);
        glClear(GL_COLOR_BUFFER_BIT);
        renderer->renderContextGL()->invalidateGLState();
    }
}

// Runs on the replay worker. Resident resources are GL objects, so their
// context must be current for the deletes.
void rive_native::deferredWorkerSessionTeardown(
    void* sessionPtr,
    rive_native::DeferredConsumer* consumer)
{
    // Renderer retirement erases the session's GL entry, so sweep first.
    for (auto bound = s_workerRendererSession.begin();
         bound != s_workerRendererSession.end();)
    {
        if (bound->second == sessionPtr)
        {
            auto* renderer = bound->first;
            renderer->unbindDeferredSession();
            workerWipeDetachedRenderer(renderer);
            bound = s_workerRendererSession.erase(bound);
        }
        else
        {
            ++bound;
        }
    }
    auto it = s_workerSessionGL.find(sessionPtr);
    if (it != s_workerSessionGL.end())
    {
        ScopedGLContextMakeCurrent makeCurrent(it->second);
        delete consumer;
        delete static_cast<rive::cmd::DeferredSession*>(sessionPtr);
        s_workerSessionGL.erase(it);
        return;
    }
    delete consumer;
    delete static_cast<rive::cmd::DeferredSession*>(sessionPtr);
}

// Runs on the replay worker in the same task that registered the canvas.
// Fills slot with the renderer pointer, or the failure sentinel so the
// producer can tell a dead renderer from one still being created.
EXPORT void riveDeferredWorkerCreateRenderer(WasmPtr sessionPtr,
                                             const char* canvasSelector,
                                             int width,
                                             int height,
                                             WasmPtr slotPtr)
{
    auto* session = (rive::cmd::DeferredSession*)sessionPtr;
    auto* slot = (std::atomic<uint32_t>*)slotPtr;
    WebGL2Renderer* renderer = nullptr;
    EmscriptenWebGLContextAttributes attrs;
    emscripten_webgl_init_context_attributes(&attrs);
    attrs.majorVersion = 2;
    attrs.minorVersion = 0;
    attrs.alpha = true;
    attrs.depth = false;
    attrs.stencil = false;
    attrs.antialias = false;
    attrs.premultipliedAlpha = true;
    attrs.preserveDrawingBuffer = true;
    // emscripten_webgl_commit_frame no longer presents in modern browsers, so
    // rely on implicit swap.
    attrs.explicitSwapControl = false;
    auto ctx = emscripten_webgl_create_context(canvasSelector, &attrs);
    if (ctx > 0)
    {
        emscripten_webgl_make_context_current(ctx);
        if (auto rc = RenderContextGLImpl::MakeContext())
        {
            renderer = new WebGL2Renderer(std::move(rc), width, height);
            renderer->markWorkerMode(canvasSelector);
            renderer->useDeferredSession(session);
            s_workerSessionGL[(void*)session] = ctx;
            workerBindSessionRenderer(session, renderer);
        }
    }
    if (renderer == nullptr)
    {
        fprintf(stderr,
                "rive_native: worker renderer creation FAILED for %s\n",
                canvasSelector);
    }
    // This release store is the publication point for everything the binds
    // above wrote (real ore, render context): the producer only records after
    // it acquires a non zero pointer from this slot, so those raw pointer
    // fields never need their own synchronization.
    slot->store(renderer != nullptr ? (uint32_t)(uintptr_t)renderer
                                    : 0xffffffffu,
                std::memory_order_release);
}

// A transferred canvas can never transfer again, so a re-attach reuses the
// renderer and its GL context.
EXPORT void riveDeferredWorkerRendererUseSession(WasmPtr rendererPtr,
                                                 WasmPtr sessionPtr)
{
    auto* renderer = (WebGL2Renderer*)rendererPtr;
    auto* session = (rive::cmd::DeferredSession*)sessionPtr;
    rive_native::DeferredWebWorker::instance().post([renderer, session] {
        renderer->useDeferredSession(session);
        workerBindSessionRenderer(session, renderer);
        if (session != nullptr)
        {
            s_workerSessionGL[(void*)session] = renderer->contextGL();
        }
        else
        {
            workerWipeDetachedRenderer(renderer);
        }
    });
}

// Retires a worker renderer for good, which is the only place its GL context
// can be given back: the renderer outlives any one session, so session
// teardown must not destroy it, and the main thread cannot destroy a context
// that lives here.
//
// Posted, never awaited. Both the per session replay jobs and the session
// teardown go through the same serial DeferredWebWorker queue, so this lands
// after everything already recorded against the renderer, and the main thread
// never waits on a worker job that could proxy back to it.
EXPORT void riveDeleteDeferredWorkerRenderer(WasmPtr rendererPtr)
{
    auto* renderer = (WebGL2Renderer*)rendererPtr;
    if (renderer == nullptr)
    {
        return;
    }
    rive_native::DeferredWebWorker::instance().post([renderer] {
        auto ctx = renderer->contextGL();
        // The session outlives the renderer; its own teardown must not find
        // resident resources pointing at a dead context.
        renderer->useDeferredSession(nullptr);
        workerBindSessionRenderer(nullptr, renderer);
        // ~WebGL2Renderer makes ctx current for its own GL deletes and
        // restores the previous context on the way out.
        delete renderer;
        for (auto it = s_workerSessionGL.begin();
             it != s_workerSessionGL.end();)
        {
            if (it->second == ctx)
            {
                it = s_workerSessionGL.erase(it);
            }
            else
            {
                ++it;
            }
        }
        emscripten_webgl_destroy_context(ctx);
    });
}

// The screen recorder is valid before the worker renderer is ready.
EXPORT WasmPtr riveDeferredSessionScreenRenderer(WasmPtr sessionPtr)
{
    auto* session = (rive::cmd::DeferredSession*)sessionPtr;
    return (WasmPtr)(rive::Renderer*)session->screenRenderer();
}

// Enqueued as a worker job because the canvas and render target are GL affine.
EXPORT void resizeDeferredRendererOnWorker(WasmPtr rendererPtr,
                                           int width,
                                           int height)
{
    auto* renderer = (WebGL2Renderer*)rendererPtr;
    rive_native::deferredConsumerFor(renderer->deferredSession())
        ->enqueue([renderer, width, height] {
            ScopedGLContextMakeCurrent makeCurrent(renderer->contextGL());
            emscripten_set_canvas_element_size(
                renderer->workerCanvasSelector().c_str(),
                width,
                height);
            renderer->resize(width, height);
        });
}
#endif

EXPORT WasmPtr rendererContext() { return (WasmPtr)WebGL2Factory::Instance(); }

// Extract the gpu::RenderContext* from a WebGL2Renderer*.
EXPORT WasmPtr rendererGetGPURenderContext(WasmPtr rendererPtr)
{
    auto* renderer = (WebGL2Renderer*)rendererPtr;
    if (!renderer)
        return 0;
    return (WasmPtr)renderer->gpuRenderContext();
}

// Extract the ore::Context* from a WebGL2Renderer*.
// The renderer owns the ore::Context — created in the same GL context.
EXPORT WasmPtr rendererGetOreContext(WasmPtr rendererPtr)
{
    auto* renderer = (WebGL2Renderer*)rendererPtr;
    if (!renderer)
        return 0;
    return (WasmPtr)renderer->oreContext();
}

// Tell PLS that external code (ore) may have modified GL state.
// Must be called after any ore GL operations so PLS re-binds its
// internal textures, buffers, and VAOs on the next flush.
EXPORT void riveInvalidateGLState(WasmPtr renderContextPtr)
{
    auto* ctx = (gpu::RenderContext*)renderContextPtr;
    if (ctx)
    {
        ctx->static_impl_cast<gpu::RenderContextGLImpl>()->invalidateGLState();
    }
}

void deleteRenderer(WasmPtr rendererPtr)
{
    delete (WebGL2Renderer*)rendererPtr;
}

void clearRenderer(WasmPtr rendererPtr, uint32_t color)
{
    auto renderer = (WebGL2Renderer*)rendererPtr;
    if (renderer == nullptr)
    {
        return;
    }
#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
    if (renderer->deferredSession() != nullptr)
    {
        // No GPU work in deferred mode, stash the clear for replay.
        renderer->deferredClear(true, (ColorInt)color);
        return;
    }
    if (renderer->workerMode())
    {
        // Its GL context belongs to the replay worker, so a detached session
        // must not fall back to rendering here.
        return;
    }
#endif
    renderer->clear((ColorInt)color);
}

void flushRenderer(WasmPtr rendererPtr)
{
    auto renderer = (WebGL2Renderer*)rendererPtr;
    if (renderer == nullptr)
    {
        return;
    }
#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
    if (renderer->deferredSession() != nullptr)
    {
        renderer->deferredFlush();
        return;
    }
    if (renderer->workerMode())
    {
        static bool warned = false;
        if (!warned)
        {
            warned = true;
            fprintf(stderr,
                    "rive_native: flush of a worker renderer with no deferred "
                    "session, dropping the frame\n");
        }
        return;
    }
#endif
    renderer->flush();
}

// Returns the session recorder when deferred, else this renderer. The result
// is a rive::Renderer* and must only go to the generic renderer ops.
WasmPtr rendererDrawRenderer(WasmPtr rendererPtr)
{
    auto renderer = (WebGL2Renderer*)rendererPtr;
    if (renderer == nullptr)
    {
        return 0;
    }
#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
    if (auto* screen = renderer->deferredScreenRenderer())
    {
        return (WasmPtr)screen;
    }
#endif
    return (WasmPtr)(rive::Renderer*)renderer;
}

void rendererUseDeferredSession(WasmPtr rendererPtr, WasmPtr sessionPtr)
{
#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
    auto renderer = (WebGL2Renderer*)rendererPtr;
    if (renderer == nullptr)
    {
        return;
    }
    renderer->useDeferredSession((rive::cmd::DeferredSession*)sessionPtr);
#endif
}

void resizeRenderer(WasmPtr rendererPtr, int width, int height)
{
    auto renderer = (WebGL2Renderer*)rendererPtr;
    if (renderer == nullptr)
    {
        return;
    }
#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
    if (renderer->workerMode())
    {
        // Only the worker may touch its render target,
        // resizeDeferredRendererOnWorker is the way in.
        return;
    }
#endif
    renderer->resize(width, height);
}

void saveRenderer(WasmPtr rendererPtr)
{
    // The pointer may be the WebGL2Renderer or a deferred screen recorder.
    auto renderer = (rive::Renderer*)rendererPtr;
    if (renderer == nullptr)
    {
        return;
    }
    renderer->save();
}

void restoreRenderer(WasmPtr rendererPtr)
{
    auto renderer = (rive::Renderer*)rendererPtr;
    if (renderer == nullptr)
    {
        return;
    }
    renderer->restore();
}

void transformRenderer(WasmPtr rendererPtr,
                       float xx,
                       float xy,
                       float yx,
                       float yy,
                       float tx,
                       float ty)
{
    auto renderer = (rive::Renderer*)rendererPtr;
    if (renderer == nullptr)
    {
        return;
    }
    rive::Mat2D matrix(xx, xy, yx, yy, tx, ty);
    renderer->transform(matrix);
}

void modulateOpacityRenderer(WasmPtr rendererPtr, float opacity)
{
    auto renderer = (rive::Renderer*)rendererPtr;
    if (renderer == nullptr)
    {
        return;
    }
    renderer->modulateOpacity(opacity);
}

EMSCRIPTEN_BINDINGS(Rive)
{
    function("decodeImage", &decodeImage);
    function("makeRenderer", &makeRenderer);
    function("deleteRenderer", &deleteRenderer);
    function("clearRenderer", &clearRenderer);
    function("flushRenderer", &flushRenderer);
    function("rendererUseDeferredSession", &rendererUseDeferredSession);
    function("rendererDrawRenderer", &rendererDrawRenderer);
    function("resizeRenderer", &resizeRenderer);
    function("saveRenderer", &saveRenderer);
    function("restoreRenderer", &restoreRenderer);
    function("transformRenderer", &transformRenderer);
    function("modulateOpacityRenderer", &modulateOpacityRenderer);
}
