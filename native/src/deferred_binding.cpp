// Deferred session and consumer exports for Dart FFI. Split out of
// rive_luau_binding_gpu.cpp so the Flutter runtime, which stubs out Luau, can
// still link deferred rendering.
#if defined(RIVE_CANVAS) && defined(RIVE_ORE)
#include "rive_native/external.hpp"
#include "rive/renderer/render_context.hpp"
#include "rive/renderer/render_canvas.hpp"
#include "rive/renderer/ore/ore_context.hpp"
#include "rive/renderer/render_context_impl.hpp"
#include "rive/renderer/cmd/deferred_session.hpp"
#include "rive/renderer/cmd/deferred_replayer.hpp"
#include "rive_native/deferred_consumer.hpp"
#include "rive_native/deferred_host.hpp"
#include <unordered_map>
#include <memory>

using namespace rive;

// Platform render thread hook, see deferred_consumer.hpp. Unset runs inline.
static std::function<void(const std::function<void()>&)> g_renderThreadRunner;
void rive_native::setRenderThreadRunner(
    std::function<void(const std::function<void()>&)> runner)
{
    g_renderThreadRunner = std::move(runner);
}
void rive_native::runOnRenderThread(const std::function<void()>& task)
{
    if (g_renderThreadRunner)
    {
        g_renderThreadRunner(task);
    }
    else
    {
        task();
    }
}

// Platform backpressure hook, see deferred_consumer.hpp. Unset accepts.
static std::function<bool()> g_canAcceptProbe;
void rive_native::setDeferredCanAcceptProbe(std::function<bool()> probe)
{
    g_canAcceptProbe = std::move(probe);
}
bool rive_native::deferredCanAcceptProbe()
{
    return !g_canAcceptProbe || g_canAcceptProbe();
}

static std::unique_ptr<rive::ore::Context> g_ownedOreContext;
// RenderContext the cached ore context was minted for. A changed context
// means the old GPU and queue are gone, so re-mint.
static void* g_ownedOreContextForRC = nullptr;

EXPORT void* riveInitGPUScripting(void* renderContextPtr)
{
    if (g_ownedOreContext && g_ownedOreContextForRC == renderContextPtr)
    {
        return g_ownedOreContext.get();
    }
    // ~ContextGL issues glDelete* for its scratch objects, so tearing the old
    // one down must run on the render thread, same as minting it below. The
    // file static's own destruction at process exit runs without a current
    // context, where glDelete* is a no-op: accepted residual risk.
    if (g_ownedOreContext)
    {
        rive_native::runOnRenderThread([&] { g_ownedOreContext.reset(); });
    }
    g_ownedOreContextForRC = nullptr;
    auto* rc = static_cast<rive::gpu::RenderContext*>(renderContextPtr);
    if (rc == nullptr || rc->impl() == nullptr)
    {
        return nullptr;
    }
    // makeOreContext queries GL, so it must run on the render thread when the
    // backend has one.
    rive_native::runOnRenderThread(
        [&] { g_ownedOreContext = rc->impl()->makeOreContext(); });
    if (g_ownedOreContext)
    {
        g_ownedOreContextForRC = renderContextPtr;
    }
    return g_ownedOreContext.get();
}

EXPORT void riveDeleteDeferredSession(void* sessionPtr);

// The one session the process render context owns. Held here rather than in
// Dart so its lifetime is the context's: it outlives every file and texture
// that recorded into it.
static rive::cmd::DeferredSession* g_contextSession = nullptr;
static void* g_contextSessionForRC = nullptr;

// Deferred recording session: records the file's 2D and GPU work into a
// pointer free serializable command stream. Replay runs the stream against a
// real RenderContext.

// The session is the import factory, pass it as the factory to loadRiveFile
// so the file's resources record. Free with riveDeleteDeferredSession.
EXPORT void* riveMakeDeferredSession(void* realOreContextPtr)
{
    // Null is allowed, web creates the session before the real ore context
    // exists and late binds its caps on texture attach.
    auto* realOre = static_cast<rive::ore::Context*>(realOreContextPtr);
    return new rive::cmd::DeferredSession(
        realOre != nullptr ? rive::ore::ReplayCaps::from(*realOre)
                           : rive::ore::ReplayCaps{});
}

// The session the render context owns. Every file imports through it and
// every artboard instances against it, so a resource recorded once resolves
// for whichever texture ends up replaying it. Do not free: the context owns
// it for the life of the process.
EXPORT void* riveContextDeferredSession(void* renderContextPtr)
{
    if (g_contextSession != nullptr &&
        g_contextSessionForRC == renderContextPtr)
    {
        return g_contextSession;
    }
    // A different context means the GPU objects the old stream named are
    // gone, so the recording cannot be carried over.
    riveDeleteDeferredSession(g_contextSession);
    g_contextSession = nullptr;
    g_contextSessionForRC = nullptr;
    auto* rc = static_cast<rive::gpu::RenderContext*>(renderContextPtr);
    auto* realOre = static_cast<rive::ore::Context*>(
        riveInitGPUScripting(renderContextPtr));
    if (rc == nullptr || realOre == nullptr)
    {
        return nullptr;
    }
    auto* session =
        new rive::cmd::DeferredSession(rive::ore::ReplayCaps::from(*realOre));
    // Scripts imported through the session talk GPU state to the real
    // context; only their drawing records.
    session->bindRenderContext(rc);
    g_contextSession = session;
    g_contextSessionForRC = renderContextPtr;
    return session;
}

// Binds the process render context to an already-created deferred session so
// session->renderContext() (and thus Artboard::factory()->renderContext())
// resolves. Sessions made via riveMakeDeferredSession — like the editor's,
// which the VM is created with — carry no context by default; native off-screen
// canvas work (e.g. cache-as-bitmap) must allocate against the same context the
// frame replays on. Idempotent; scripts that had their context set out-of-band
// still outrank this default.
EXPORT void riveDeferredSessionBindRenderContext(void* sessionPtr,
                                                 void* renderContextPtr)
{
    auto* session = static_cast<rive::cmd::DeferredSession*>(sessionPtr);
    auto* rc = static_cast<rive::gpu::RenderContext*>(renderContextPtr);
    if (session == nullptr || rc == nullptr)
    {
        return;
    }
    session->bindRenderContext(rc);
}

// Consumers live with the session, not any texture. Resident tables must
// survive texture recreation, a fresh consumer could not re-learn resources.
static std::unordered_map<void*, std::unique_ptr<rive_native::DeferredConsumer>>
    g_sessionConsumers;

rive_native::DeferredConsumer* rive_native::deferredConsumerFor(
    void* sessionPtr)
{
    auto& consumer = g_sessionConsumers[sessionPtr];
    if (consumer == nullptr)
    {
        consumer = std::make_unique<rive_native::DeferredConsumer>();
    }
    return consumer.get();
}

// Flush the destroys every live session has queued. They otherwise wait for
// the session's next drawn frame, so an idle session holds its resources.
EXPORT void riveDeferredFlushDestroysAll()
{
    for (auto& entry : g_sessionConsumers)
    {
        if (entry.second == nullptr || entry.first == nullptr)
        {
            continue;
        }
        entry.second->flushPendingDestroys(
            *static_cast<rive::cmd::DeferredSession*>(entry.first));
    }
}

#if defined(__EMSCRIPTEN_PTHREADS__)
// Shared replay worker surface, see DeferredWebWorker.
EXPORT void riveDeferredWorkerPoll()
{
    rive_native::DeferredWebWorker::instance().pollJobs();
}
EXPORT uint32_t riveDeferredWorkerTid()
{
    return (uint32_t)(uintptr_t)rive_native::DeferredWebWorker::instance()
        .tid();
}
EXPORT int riveDeferredWorkerReady()
{
    return rive_native::DeferredWebWorker::instance().ready() ? 1 : 0;
}
#endif

EXPORT void riveDeleteDeferredSession(void* sessionPtr)
{
    auto* session = static_cast<rive::cmd::DeferredSession*>(sessionPtr);
#if defined(__EMSCRIPTEN_PTHREADS__)
    // Draining here can deadlock main against a job that proxies back to it.
    // A ready worker may hold an in-flight canvas-create naming this session,
    // so teardown rides the same message channel to order after it.
    rive_native::DeferredConsumer* consumer = nullptr;
    auto it = g_sessionConsumers.find(sessionPtr);
    if (it != g_sessionConsumers.end() && it->second != nullptr)
    {
        consumer = it->second.release();
    }
    g_sessionConsumers.erase(sessionPtr);
    auto& worker = rive_native::DeferredWebWorker::instance();
    if (worker.ready())
    {
        // clang-format off
        int posted = EM_ASM_INT({
            var rec = PThread.pthreads[$0];
            var w = (rec && rec.worker) ? rec.worker : rec;
            if (!w) { return 0; }
            w.postMessage({riveTeardown: 1, session: $1, consumer: $2});
            return 1;
        }, (int)(uintptr_t)worker.tid(),
           (int)(uintptr_t)session,
           (int)(uintptr_t)consumer);
        // clang-format on
        if (posted)
        {
            return;
        }
    }
    if (consumer != nullptr)
    {
        worker.post([consumer, session] {
            rive_native::deferredWorkerSessionTeardown(session, consumer);
        });
        return;
    }
#else
    // The consumer destructor drains so nothing replays against the dying
    // session. The lock orders this against a platform thread freeing a host
    // the session is about to notify.
    std::lock_guard<std::mutex> lock(rive_native::hostMutex());
    g_sessionConsumers.erase(sessionPtr);
#endif
    delete session;
}

#if defined(__EMSCRIPTEN_PTHREADS__)
// Worker-side handler: drain queued detaches first, then tear down.
EXPORT void riveDeferredWorkerRunTeardown(void* sessionPtr, void* consumerPtr)
{
    rive_native::DeferredWebWorker::instance().pollJobs();
    rive_native::deferredWorkerSessionTeardown(
        sessionPtr,
        static_cast<rive_native::DeferredConsumer*>(consumerPtr));
}
#endif

// Record and replay microseconds plus frames since the last call, and the
// largest producer stream any one of those frames recorded. A session's stream
// drains at the frame boundary, so the peak is sampled at snapshot rather than
// read live.
EXPORT void riveDeferredThreadStats(void* sessionPtr,
                                    uint64_t* outRecordUs,
                                    uint64_t* outReplayUs,
                                    uint32_t* outFrames,
                                    uint64_t* outStreamPeakBytes)
{
    rive_native::deferredConsumerFor(sessionPtr)
        ->takeStats(outRecordUs, outReplayUs, outFrames, outStreamPeakBytes);
}

// Web readout without out params, sample into statics then read back. One
// deferred session per process, so statics are fine.
static uint32_t g_lastRecordUs = 0;
static uint32_t g_lastReplayUs = 0;
static uint32_t g_lastFrames = 0;
static uint32_t g_lastStreamPeakBytes = 0;
EXPORT void riveDeferredSampleStats(void* sessionPtr)
{
    uint64_t recordUs = 0, replayUs = 0, streamPeakBytes = 0;
    uint32_t frames = 0;
    rive_native::deferredConsumerFor(sessionPtr)
        ->takeStats(&recordUs, &replayUs, &frames, &streamPeakBytes);
    g_lastRecordUs = (uint32_t)recordUs;
    g_lastReplayUs = (uint32_t)replayUs;
    g_lastFrames = frames;
    // One frame of one session, so bytes fit a u32 with room to spare.
    g_lastStreamPeakBytes = (uint32_t)streamPeakBytes;
}
EXPORT uint32_t riveDeferredLastRecordUs() { return g_lastRecordUs; }
EXPORT uint32_t riveDeferredLastReplayUs() { return g_lastReplayUs; }
EXPORT uint32_t riveDeferredLastFrames() { return g_lastFrames; }
EXPORT uint32_t riveDeferredLastStreamPeakBytes()
{
    return g_lastStreamPeakBytes;
}

// The Dart render driver checks this before recording and skips the whole
// frame when the consumer is behind, pacing without blocking or dropping.
EXPORT int riveDeferredCanAccept(void* sessionPtr)
{
    if (!rive_native::deferredCanAcceptProbe())
    {
        return 0;
    }
    auto it = g_sessionConsumers.find(sessionPtr);
    if (it == g_sessionConsumers.end() || it->second == nullptr)
    {
        return 1;
    }
    return it->second->canAccept() ? 1 : 0;
}

#endif // RIVE_CANVAS && RIVE_ORE
