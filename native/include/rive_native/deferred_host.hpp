/*
 * Copyright 2026 Rive
 */

#pragma once

#if defined(RIVE_CANVAS) && defined(RIVE_ORE)

#include "rive/renderer/cmd/deferred_host.hpp"
#include "rive/renderer/cmd/deferred_replayer.hpp"
#include "rive/renderer/rive_renderer.hpp"
#include <chrono>
#include <functional>
#include <memory>
#include <mutex>

// Deferred rendering host layer for the platform bindings. The sink lives in
// the shared runtime host layer; each platform keeps only how it reaches its
// render context, opens its screen frame, and schedules the replay.
namespace rive_native
{

class DeferredConsumer;

using HostFrameSink = rive::cmd::HostFrameSink;

// One frame's snapshot plus the policy bits replay needs, safe to copy onto
// another thread.
struct DeferredFrameJob
{
    std::shared_ptr<rive::cmd::DeferredFrame> frame;
    DeferredConsumer* consumer = nullptr;
    bool doClear = true;
    uint32_t color = 0;
    bool replayOre = true;
};

// Deferred session state and the producer half of the flush, mixed into each
// platform's texture renderer.
class DeferredTextureHost : public rive::cmd::DeferredSessionAttachment
{
public:
    // Swapping sessions drains so no queued replay references the old one.
    void useDeferredSession(rive::cmd::DeferredSession* session);
    // The session died first, so nothing here may reach it again.
    void deferredSessionDestroyed() override;
    rive::cmd::DeferredSession* deferredSession() const
    {
        return m_deferredSession;
    }
    // This host's render target within its session. Its recorder and its
    // replayed segments are named by it.
    uint64_t screenTarget() const { return m_screenTarget; }
    // The recorder this host draws through, null without a session.
    rive::Renderer* deferredScreenRenderer() const
    {
        return m_deferredSession == nullptr
                   ? nullptr
                   : m_deferredSession->screenRenderer(m_screenTarget);
    }
    void deferredClear(bool clear, uint32_t color);
    virtual void drainDeferred();

protected:
    // Reached still attached only when the platform tore the host down under
    // a live producer, as engine shutdown does. The target stays with the
    // session: releasing its recorder here could pull it from under a draw
    // in flight on the producer thread.
    ~DeferredTextureHost() override;

    // Target and registration only, no drain and no consumer bookkeeping, so
    // a host whose replay lives on another thread can call these there.
    void joinDeferredSession(rive::cmd::DeferredSession* session);
    void leaveDeferredSession();

    // False when nothing was recorded, or when another target on this session
    // is still recording and owns the window; the last presented frame stays
    // up either way.
    bool snapshotDeferredFrame(DeferredFrameJob& out);
    // The recorded frame has Ore content, so replay brackets an Ore frame.
    bool deferredReplayOre() const;
    // GL thread affine host: replay straight out of the session on the
    // calling thread, with no snapshot copy in between.
    bool deferredReplayInline(HostFrameSink& sink,
                              const std::function<void()>& present);

    rive::cmd::DeferredSession* m_deferredSession = nullptr;
    uint64_t m_screenTarget = 0;
    bool m_deferredDoClear = true;
    uint32_t m_deferredColor = 0;
    // Set at clear, read at flush for UI time stats.
    std::chrono::steady_clock::time_point m_recordStart;
};

// Replay one snapshot through the sink on whatever thread the host's enqueue
// policy chose; present runs only when replay reached the screen.
void replayDeferredFrame(const DeferredFrameJob& job,
                         HostFrameSink& sink,
                         const std::function<void()>& present);

// Deferred only: rendering without a recording session is unsupported.
void warnNoDeferredSession();

// Hosts are freed on the platform thread, and on Windows the Dart UI isolate
// runs elsewhere and may still hold the pointer: engine shutdown deletes every
// host before it stops the isolate. Exports resolve a host through this set
// and destruction erases from it, all under hostMutex(), so a stale pointer
// is refused instead of read. Session deletion holds the lock too, since a
// dying session writes into its hosts.
std::mutex& hostMutex();
void noteHostCreated(DeferredTextureHost* host);
void noteHostDestroyed(DeferredTextureHost* host);
bool hostIsLive(const DeferredTextureHost* host);

} // namespace rive_native

#endif // RIVE_CANVAS && RIVE_ORE
