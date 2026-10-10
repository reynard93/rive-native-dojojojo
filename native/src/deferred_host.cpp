/*
 * Copyright 2026 Rive
 */

#if defined(RIVE_CANVAS) && defined(RIVE_ORE)

#include "rive_native/deferred_host.hpp"
#include "rive_native/deferred_consumer.hpp"
#include "rive/renderer/render_canvas.hpp"
#include "rive/renderer/render_context.hpp"
#include "rive/renderer/render_context_impl.hpp"
#include <stdio.h>
#include <unordered_set>

#if defined(__ANDROID__)
#include <android/log.h>
// stderr goes nowhere on Android, route diagnostics to logcat.
#define DEFERRED_WARN(...)                                                     \
    __android_log_print(ANDROID_LOG_ERROR, "RiveNative", __VA_ARGS__)
#else
#define DEFERRED_WARN(...) fprintf(stderr, __VA_ARGS__)
#endif

namespace rive_native
{

static std::mutex g_hostMutex;
static std::unordered_set<const DeferredTextureHost*> g_liveHosts;

std::mutex& hostMutex() { return g_hostMutex; }
void noteHostCreated(DeferredTextureHost* host) { g_liveHosts.insert(host); }
void noteHostDestroyed(DeferredTextureHost* host) { g_liveHosts.erase(host); }
bool hostIsLive(const DeferredTextureHost* host)
{
    return g_liveHosts.count(host) != 0;
}

DeferredTextureHost::~DeferredTextureHost()
{
    if (m_deferredSession != nullptr)
    {
        m_deferredSession->detach(this);
    }
}

void DeferredTextureHost::deferredSessionDestroyed()
{
    m_deferredSession = nullptr;
    m_screenTarget = 0;
}

void DeferredTextureHost::joinDeferredSession(
    rive::cmd::DeferredSession* session)
{
    m_deferredSession = session;
    // A session serves every texture on its render context, so this host
    // claims an identity within it rather than assuming it is the only one.
    m_screenTarget = session->acquireScreenTarget();
    session->attach(this);
}

void DeferredTextureHost::leaveDeferredSession()
{
    m_deferredSession->releaseScreenTarget(m_screenTarget);
    m_deferredSession->detach(this);
    m_screenTarget = 0;
    m_deferredSession = nullptr;
}

void DeferredTextureHost::useDeferredSession(
    rive::cmd::DeferredSession* session)
{
    if (m_deferredSession == session)
    {
        return;
    }
    if (m_deferredSession != nullptr)
    {
        drainDeferred();
        auto* previous = m_deferredSession;
        leaveDeferredSession();
        deferredConsumerFor(previous)->noteTargetCount(
            previous->attachedTargetCount());
    }
    if (session != nullptr)
    {
        joinDeferredSession(session);
        deferredConsumerFor(session)->noteTargetCount(
            session->attachedTargetCount());
    }
}

void DeferredTextureHost::deferredClear(bool clear, uint32_t color)
{
    m_deferredDoClear = clear;
    m_deferredColor = color;
    m_deferredSession->beginTargetFrame(m_screenTarget);
    m_deferredSession->recordOreReplayMarker();
    m_recordStart = std::chrono::steady_clock::now();
}

// Blocks until every queued frame that may reference this renderer replays.
void DeferredTextureHost::drainDeferred()
{
    if (m_deferredSession != nullptr)
    {
        // Whatever this host had open is never going to close, and a stuck
        // target would hold the session's window shut for its neighbours.
        m_deferredSession->abandonTargetFrame(m_screenTarget);
        deferredConsumerFor(m_deferredSession)->drain();
    }
}

bool DeferredTextureHost::deferredReplayOre() const
{
    return m_deferredSession->oreContext().stream().commandBytes().size() != 0;
}

bool DeferredTextureHost::snapshotDeferredFrame(DeferredFrameJob& out)
{
    static bool bannered = false;
    if (!bannered)
    {
        bannered = true;
        DEFERRED_WARN("rive_native: deferred replay threaded\n");
    }
    out.consumer = deferredConsumerFor(m_deferredSession);

    // The window belongs to the session, not to this host; taking it while a
    // neighbour is still recording would reset the stream underneath it.
    if (!m_deferredSession->endTargetFrame(m_screenTarget))
    {
        return false;
    }

    if (!m_deferredSession->recordedThisFrame())
    {
        return false;
    }

    // Snapshot on the producer so recording can continue; the stream is
    // stateful so a recorded frame is never dropped, the producer gate holds
    // off recording instead.
    auto snapshotStart = std::chrono::steady_clock::now();
    out.replayOre = deferredReplayOre();
    out.consumer->noteStreamBytes(m_deferredSession->streamBytes());
    out.frame = std::make_shared<rive::cmd::DeferredFrame>(
        rive::cmd::takeFrame(*m_deferredSession));
    out.consumer->addRecordUs(static_cast<uint64_t>(
        std::chrono::duration<double, std::micro>(snapshotStart - m_recordStart)
            .count()));
    out.doClear = m_deferredDoClear;
    out.color = m_deferredColor;
    return true;
}

static void warnReplayNoScreen(size_t commandBytes)
{
    static int skips = 0;
    if (skips < 16)
    {
        skips++;
        DEFERRED_WARN("rive deferred: replay did not reach screen "
                      "(%zu command bytes)\n",
                      commandBytes);
    }
}

static void warnDroppedDraws(uint32_t droppedDraws)
{
    if (droppedDraws == 0)
    {
        return;
    }
    static int drops = 0;
    if (drops < 16)
    {
        drops++;
        DEFERRED_WARN("rive deferred: %u draws DROPPED this frame (mixed "
                      "factories or replay bug)\n",
                      droppedDraws);
    }
}

void replayDeferredFrame(const DeferredFrameJob& job,
                         HostFrameSink& sink,
                         const std::function<void()>& present)
{
    auto replayStart = std::chrono::steady_clock::now();
    job.consumer->replayer().replayFrame(*job.frame, sink);
    if (sink.began())
    {
        present();
    }
    else
    {
        warnReplayNoScreen(job.frame->commands.size());
    }
    warnDroppedDraws(job.consumer->replayer().droppedDraws());
    job.consumer->addReplayUs(static_cast<uint64_t>(
        std::chrono::duration<double, std::micro>(
            std::chrono::steady_clock::now() - replayStart)
            .count()));
    job.consumer->addFrame();
}

bool DeferredTextureHost::deferredReplayInline(
    HostFrameSink& sink,
    const std::function<void()>& present)
{
    auto* consumer = deferredConsumerFor(m_deferredSession);
    consumer->noteInlineReplay();

    if (!m_deferredSession->endTargetFrame(m_screenTarget))
    {
        return true;
    }

    if (!m_deferredSession->recordedThisFrame())
    {
        return true;
    }

    auto replayStart = std::chrono::steady_clock::now();
    consumer->addRecordUs(static_cast<uint64_t>(
        std::chrono::duration<double, std::micro>(replayStart - m_recordStart)
            .count()));
    consumer->noteStreamBytes(m_deferredSession->streamBytes());

    consumer->replayer().replayFrame(*m_deferredSession, sink);
    m_deferredSession->resetFrame();

    if (sink.began())
    {
        present();
    }
    warnDroppedDraws(consumer->replayer().droppedDraws());
    consumer->addReplayUs(static_cast<uint64_t>(
        std::chrono::duration<double, std::micro>(
            std::chrono::steady_clock::now() - replayStart)
            .count()));
    consumer->addFrame();
    return true;
}

void warnNoDeferredSession()
{
    static bool warned = false;
    if (!warned)
    {
        warned = true;
        DEFERRED_WARN("rive_native: texture has no deferred session, nothing "
                      "will draw (deferred rendering is the only mode)\n");
    }
}

} // namespace rive_native

#endif // RIVE_CANVAS && RIVE_ORE
