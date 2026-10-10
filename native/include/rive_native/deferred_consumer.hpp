/*
 * Copyright 2026 Rive
 */

#pragma once

#if defined(RIVE_CANVAS) && defined(RIVE_ORE)

#include "rive/renderer/cmd/deferred_replayer.hpp"
#include "rive/renderer/scoped_autorelease_pool.hpp"
#include <atomic>
#include <cstdint>
#include <functional>
#include <utility>

#if defined(__EMSCRIPTEN_PTHREADS__)
// Web threaded: a worker pthread polls a job queue from its JS event loop.
// Only the event loop turn presents the OffscreenCanvas.
#include <cstdio>
#include <deque>
#include <mutex>
#include <emscripten/emscripten.h>
#include <emscripten/eventloop.h>
#include <emscripten/threading.h>
#include <pthread.h>
#elif !defined(__EMSCRIPTEN__)
// Native: a real thread with a bounded queue.
#include <condition_variable>
#include <deque>
#include <mutex>
#include <thread>
#if defined(__APPLE__)
#include <pthread.h>
#endif
#endif

namespace rive_native
{

#if defined(__EMSCRIPTEN_PTHREADS__)
// The process replay worker servicing every session. Canvases arrive by
// postMessage transfer and each job makes its own canvas GL context current.
// Leaky singleton, the worker lives with the process.
class DeferredWebWorker
{
public:
    static DeferredWebWorker& instance()
    {
        static DeferredWebWorker* worker = new DeferredWebWorker();
        return *worker;
    }

    // Spawn once with no canvases, they are posted to the live worker.
    void start()
    {
        if (m_started)
        {
            return;
        }
        m_started = true;
        pthread_create(&m_worker,
                       nullptr,
                       &DeferredWebWorker::workerMain,
                       this);
    }

    pthread_t tid()
    {
        start();
        return m_worker;
    }

    // True once the listener can receive canvas transfers.
    bool ready() const { return m_ready.load(std::memory_order_acquire); }

    // Signaling the worker keeps the render cadence in step with vsync.
    void post(std::function<void()> job)
    {
        start();
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            m_jobs.push_back(std::move(job));
        }
        // clang-format off
        EM_ASM({
            var rec = PThread.pthreads[$0];
            var w = (rec && rec.worker) ? rec.worker : rec;
            if (w) { w.postMessage({rivePoll: 1}); }
            else if (!Module["riveWarnedNoWorker"]) {
                Module["riveWarnedNoWorker"] = true;
                console.warn("rive_native: replay worker record missing, " +
                             "jobs continue on the poll timer");
            }
        }, (int)(uintptr_t)m_worker);
        // clang-format on
    }

    // Runs on the worker, returning lets the event loop present the canvases.
    void pollJobs()
    {
        for (;;)
        {
            std::function<void()> job;
            {
                std::lock_guard<std::mutex> lock(m_mutex);
                if (m_jobs.empty())
                {
                    return;
                }
                job = std::move(m_jobs.front());
                m_jobs.pop_front();
            }
            job();
        }
    }

private:
    DeferredWebWorker() = default;

    static void* workerMain(void* arg)
    {
        auto* self = static_cast<DeferredWebWorker*>(arg);
        emscripten_set_thread_name(pthread_self(), "rive.deferred.replay");
        // riveCanvas registers the canvas and creates the renderer in the same
        // task so nothing runs between. rivePoll drains queued jobs.
        // clang-format off
        EM_ASM({
            self.addEventListener('message', function(e) {
                var d = e.data;
                if (!d) { return; }
                if (d.riveCanvas) {
                    var sp = _malloc(12);
                    var heap = new Uint32Array(wasmMemory.buffer, sp, 3);
                    heap[0] = d.canvas.width;
                    heap[1] = d.canvas.height;
                    heap[2] = d.tid;
                    GL.offscreenCanvases[d.id] = {
                        offscreenCanvas: d.canvas,
                        canvasSharedPtr: sp,
                        id: d.id
                    };
                    var sel = "#" + d.id;
                    var len = Module["lengthBytesUTF8"](sel) + 1;
                    var selPtr = _malloc(len);
                    Module["stringToUTF8"](sel, selPtr, len);
                    Module["_riveDeferredWorkerCreateRenderer"](
                        d.session, selPtr, d.w, d.h, d.slot);
                    _free(selPtr);
                } else if (d.riveTeardown) {
                    Module["_riveDeferredWorkerRunTeardown"](
                        d.session, d.consumer);
                } else if (d.rivePoll) {
                    Module["_riveDeferredWorkerPoll"]();
                }
            });
            // A rivePoll postMessage can be lost, so an interval also drains.
            // emscripten_set_interval never fires here, use raw setInterval.
            setInterval(function() {
                Module["_riveDeferredWorkerPoll"]();
            }, 100);
        });
        // clang-format on
        self->m_ready.store(true, std::memory_order_release);
        // Run anything queued during the spawn window now.
        self->pollJobs();
        emscripten_exit_with_live_runtime();
        return nullptr; // unreachable
    }

    pthread_t m_worker{};
    std::mutex m_mutex;
    std::deque<std::function<void()>> m_jobs;
    std::atomic<bool> m_ready{false};
    bool m_started = false;
};
#endif

#if !defined(__EMSCRIPTEN__)
// Serial worker every deferred session's replays run on. Leaky singleton, the
// thread lives with the process.
class DeferredRenderThread
{
public:
    static DeferredRenderThread& instance()
    {
        static DeferredRenderThread* thread = new DeferredRenderThread();
        return *thread;
    }

    void post(std::function<void()> job)
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        m_jobs.push_back(std::move(job));
        m_hasWork.notify_one();
    }

private:
    DeferredRenderThread() : m_thread([this] { loop(); }) {}

    void loop()
    {
#if defined(__APPLE__)
        pthread_setname_np("rive.deferred.replay");
#endif
        for (;;)
        {
            std::function<void()> job;
            {
                std::unique_lock<std::mutex> lock(m_mutex);
                m_hasWork.wait(lock, [this] { return !m_jobs.empty(); });
                job = std::move(m_jobs.front());
                m_jobs.pop_front();
            }
            job();
        }
    }

    std::mutex m_mutex;
    std::condition_variable m_hasWork;
    std::deque<std::function<void()>> m_jobs;
    std::thread m_thread;
};
#endif

// Per session consumer: the session's replayer plus its delivery to the render
// thread. One consumer per session keeps the replayer's resident tables single
// threaded. Streams are stateful so frames are never dropped, the producer
// holds off recording instead. Three delivery models share one interface.
class DeferredConsumer
{
public:
    // Frames one render target may run ahead of replay by.
    static constexpr size_t kMaxQueued = 2;

    // A consumer serves every target on its render context, and each target
    // records and flushes on its own within a host frame, so the queue holds
    // one frame per target before the first replays. Bounding the whole queue
    // at kMaxQueued would make each target wait out its neighbours' replays
    // inside enqueue, on the thread that records. Targets take turns, so
    // scaling the bound with them keeps a target's own run ahead at
    // kMaxQueued, the same depth it had when it owned the consumer.
    void noteTargetCount(size_t targets)
    {
        m_maxQueued.store(kMaxQueued * (targets > 0 ? targets : 1),
                          std::memory_order_relaxed);
    }
    size_t maxQueued() const
    {
        return m_maxQueued.load(std::memory_order_relaxed);
    }

    rive::cmd::DeferredReplayer& replayer() { return m_replayer; }

    // Stats in microseconds accumulated since the last take.
    void addRecordUs(uint64_t us) { m_recordUs += us; }
    void addReplayUs(uint64_t us) { m_replayUs += us; }
    void addFrame() { m_frames += 1; }
    // High water mark rather than a sum: the session's stream drains at every
    // frame boundary, so only the value one frame reached says anything about
    // how much stream a session costs. Recording thread only, like the record
    // clock, so a plain read modify write is enough.
    void noteStreamBytes(uint64_t bytes)
    {
        if (bytes > m_streamPeakBytes.load(std::memory_order_relaxed))
        {
            m_streamPeakBytes.store(bytes, std::memory_order_relaxed);
        }
    }
    void takeStats(uint64_t* recordUs,
                   uint64_t* replayUs,
                   uint32_t* frames,
                   uint64_t* streamPeakBytes)
    {
        *recordUs = m_recordUs.exchange(0);
        *replayUs = m_replayUs.exchange(0);
        *frames = m_frames.exchange(0);
        *streamPeakBytes = m_streamPeakBytes.exchange(0);
    }

#if defined(__EMSCRIPTEN_PTHREADS__)
    // Web threaded: every session shares the DeferredWebWorker.

    // Jobs capture this consumer's replayer, so drain before dying. Draining
    // on the worker would deadlock it against its own queue.
    ~DeferredConsumer()
    {
        if (!pthread_equal(pthread_self(), DeferredWebWorker::instance().tid()))
        {
            drain();
        }
    }

    // Single producer, so true guarantees room for one enqueue.
    bool canAccept() const
    {
        return m_queued.load(std::memory_order_acquire) < maxQueued();
    }

    // A worker cannot block, so enqueueing past the bound is allowed but
    // flagged once.
    void enqueue(std::function<void()> job)
    {
        if (!canAccept() && !m_warnedOverQueue)
        {
            m_warnedOverQueue = true;
            fprintf(stderr,
                    "rive_native: deferred producer enqueued past the bound; "
                    "gate frames on canAcceptDeferredFrame\n");
        }
        m_queued.fetch_add(1, std::memory_order_release);
        DeferredWebWorker::instance().post([this, job = std::move(job)]() {
            job();
            m_queued.fetch_sub(1, std::memory_order_release);
        });
    }

    // Teardown only, spins until this session's jobs finish.
    void drain()
    {
        while (m_queued.load(std::memory_order_acquire) > 0)
        {
        }
    }

private:
    std::atomic<uint32_t> m_queued{0};
    bool m_warnedOverQueue = false;

#elif !defined(__EMSCRIPTEN__)
    // Native: jobs from all sessions run serially on one shared render
    // thread. Each consumer bounds only its own in flight frames.

    bool canAccept() const { return true; } // bound lives in enqueue's wait

    void enqueue(std::function<void()> job)
    {
        {
            std::unique_lock<std::mutex> lock(m_mutex);
            m_notFull.wait(lock, [this] { return m_inFlight < maxQueued(); });
            m_inFlight++;
        }
        DeferredRenderThread::instance().post([this, job = std::move(job)]() {
            {
                // The render thread has no run loop, so autoreleased command
                // buffers and encoders only drain here; the pool pops before
                // completion is signaled so drain() covers it.
                rive::gpu::ScopedAutoreleasePool pool;
                job();
            }
            std::lock_guard<std::mutex> lock(m_mutex);
            m_inFlight--;
            m_notFull.notify_all();
            m_idle.notify_all();
        });
    }

    // Waits on this session's work only, the shared thread keeps running.
    void drain()
    {
        std::unique_lock<std::mutex> lock(m_mutex);
        m_idle.wait(lock, [this] { return m_inFlight == 0; });
    }

    // Jobs capture this consumer's replayer, so drain before dying.
    ~DeferredConsumer() { drain(); }

private:
    std::mutex m_mutex;
    std::condition_variable m_notFull;
    std::condition_variable m_idle;
    uint32_t m_inFlight = 0;

#else
    // Web single threaded: no worker, replay inline.

    bool canAccept() const { return true; }
    void enqueue(std::function<void()> job) { job(); }
    void drain() {}

private:
#endif

public:
    // Drains first so the walk sees quiescent tables, then reads them on the
    // calling thread. That makes it a sampling call, not a per frame one:
    // draining stalls the caller for whatever replay is in flight.
    rive::cmd::GpuCensus gpuCensus()
    {
        drain();
        return m_replayer.gpuCensus();
    }

    // Frees what an idle session queued but no frame will carry. Must ride the
    // queue this session's frames replay on: that keeps it ordered behind
    // them and the tables on one thread. Recording thread only.
    void flushPendingDestroys(rive::cmd::DeferredSession& session)
    {
        if (!canFlushDestroys())
        {
            return; // they stay queued and ride the next frame
        }
        auto pending = session.takePendingDestroys();
        if (pending.empty())
        {
            return;
        }
        enqueue([this, pending = std::move(pending)] {
            m_replayer.replayDestroys(pending.commands, pending.oreCommands);
        });
    }

    // A host that replays inline has no queue to order a flush against.
    void noteInlineReplay() { m_replaysInline = true; }

private:
    // Only where frames replay through enqueue(). Android replays on its GL
    // thread and web needs its canvas's GL context current, so a flush there
    // would free GL objects on the wrong thread or context.
    bool canFlushDestroys() const
    {
#if defined(__EMSCRIPTEN__) || defined(__ANDROID__)
        return false;
#else
        return !m_replaysInline;
#endif
    }

    rive::cmd::DeferredReplayer m_replayer;
    bool m_replaysInline = false;
    std::atomic<size_t> m_maxQueued{kMaxQueued};
    std::atomic<uint64_t> m_recordUs{0};
    std::atomic<uint64_t> m_replayUs{0};
    std::atomic<uint32_t> m_frames{0};
    std::atomic<uint64_t> m_streamPeakBytes{0};
};

// Defined in deferred_binding.cpp, created on demand, destroyed with the
// session.
DeferredConsumer* deferredConsumerFor(void* sessionPtr);

#if defined(__EMSCRIPTEN_PTHREADS__)
// Defined in webgl_factory.cpp, runs on the replay worker with the owning GL
// context current so the resident resource deletes hit it.
void deferredWorkerSessionTeardown(void* sessionPtr,
                                   DeferredConsumer* consumer);
#endif

// GL contexts are thread affine, so a backend with a dedicated render thread
// registers this to run GL touching setup there. Unset runs inline.
void setRenderThreadRunner(
    std::function<void(const std::function<void()>&)> runner);
void runOnRenderThread(const std::function<void()>& task);

// Backend probe for the Dart producer gate, dropping a recorded frame would
// desync the stateful stream. Unset always accepts.
void setDeferredCanAcceptProbe(std::function<bool()> probe);
bool deferredCanAcceptProbe();

} // namespace rive_native

#endif
