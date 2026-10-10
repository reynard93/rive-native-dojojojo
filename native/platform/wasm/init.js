Module["onRuntimeInitialized"] = function () {
  // Always read the live buffer: under memory growth a cached heap view
  // detaches, and atomics on a detached view throw.
  function heapBuffer() {
    return Module["wasmMemory"]["buffer"];
  }

  const makeRenderer = Module["makeRenderer"];
  const cppDeleteRenderer = Module["deleteRenderer"];
  let _offscreenGL = null;
  // Device capabilities from the first feature probe. Immutable for the
  // page's lifetime, so an offscreen rebuild after releaseOffscreenGL can
  // skip re-probing (and the extra context the MSAA re-probe would create).
  let _glCaps = null;

  // Live WebGL2 contexts created by this module (canvases + the offscreen
  // probe), decremented on genuine release. Browsers cap live contexts
  // (~16 browser-wide) and expose no way to observe the count, so tests
  // assert against this instead.
  let _liveGLContexts = 0;
  Module["liveGLContextCount"] = function () {
    return _liveGLContexts;
  };

  function makeGLRenderer(canvas, enableMSAA = false) {
    var contextAttributes = {
      "alpha": true,
      "depth": enableMSAA,
      "stencil": enableMSAA,
      "antialias": enableMSAA,
      "premultipliedAlpha": true,
      "preserveDrawingBuffer": 1,
      "powerPreference": "high-performance",
      "failIfMajorPerformanceCaveat": 0,
      "enableExtensionsByDefault": false,
      "explicitSwapControl": 0,
      "renderViaOffscreenBackBuffer": 0,
    };

    var gl = canvas.getContext("webgl2", contextAttributes);
    if (!gl) {
      return null;
    }
    var handle = GL.registerContext(gl, contextAttributes);

    GL.makeContextCurrent(handle);

    // RenderContextGLImpl::MakeContext can still fail on a context the
    // browser handed out. Give the context straight back rather than keeping
    // a slot of the page's budget for a renderer that does not exist. Safe to
    // deleteContext here: C++ never saw this context, so nothing uploaded to
    // it can outlive it.
    var ptr = makeRenderer(canvas.width, canvas.height);
    if (!ptr) {
      var lose = gl.getExtension("WEBGL_lose_context");
      if (lose) {
        lose.loseContext();
      }
      if (GL.deleteContext) {
        GL.deleteContext(handle);
      }
      return null;
    }

    _liveGLContexts++;
    return {
      "_ptr": ptr,
      _handle: handle,
      _canvas: canvas,
      _gl: gl,
    };
  }

  // Fully release a renderer made by makeGLRenderer: the C++ renderer (PLS +
  // ore contexts) first, while its WebGL context is still alive, then the
  // browser context itself via WEBGL_lose_context. The context slot is the
  // scarce resource — the browser caps live contexts at ~16 and a lost one
  // no longer counts.
  //
  // Deliberately do NOT GL.deleteContext: objects uploaded to this context
  // can outlive it (an image's GPU texture is torn down when its File is
  // disposed, which may be after the render texture died), and that teardown
  // re-binds the upload context by handle. A lost-but-registered context
  // makes those glDelete* calls safe no-ops, whereas an unregistered handle
  // nulls Emscripten's current context and the next GL call crashes with
  // "Cannot read properties of undefined (reading 'deleteTexture')" — the
  // same class of bug as runtime_wasm PRs #12770/#12886. The registry entry
  // it keeps is a few objects per released texture; the context itself is
  // gone.
  function releaseGLRenderer(renderer) {
    if (renderer["_ptr"]) {
      cppDeleteRenderer(renderer["_ptr"]);
      renderer["_ptr"] = 0;
    }
    const lose = renderer._gl.getExtension("WEBGL_lose_context");
    if (lose) {
      lose.loseContext();
    }
    if (_activeRenderer === renderer) {
      _activeRenderer = null;
    }
    // Unconditional: the extension is universally implemented, and remains
    // queryable even on a lost context (it is the recovery extension) — a
    // null `lose` in practice means the context is already lost, i.e. its
    // browser slot is already free and this release is pure bookkeeping.
    _liveGLContexts--;
  }

  // Genuinely destroy a renderer returned by Module["makeRenderer"] — used
  // by the Dart side when a disposed render texture doesn't go back to the
  // (bounded) pool.
  Module["releaseRenderer"] = releaseGLRenderer;

  // Release the shared offscreen probe context (feature detection + GPU
  // limits). Recreated on demand by the next makeRenderer call; lets an idle
  // page drop to zero live contexts.
  Module["releaseOffscreenGL"] = function () {
    if (_offscreenGL) {
      releaseGLRenderer(_offscreenGL);
      _offscreenGL = null;
    }
  };

  // Null rather than a throw when the browser will not give out a context.
  // Callers turn that into a blank widget and a warning: this runs inside
  // frame callbacks and inside File.dispose, where a throw took down the
  // app's own teardown rather than just the one widget that could not draw.
  Module["makeRenderer"] = function (canvas) {
    if (!_offscreenGL) {
      function MakeOffscreenGL(enableMSAA) {
        const offscreenCanvas = document.createElement("canvas");
        offscreenCanvas.width = 1;
        offscreenCanvas.height = 1;
        _offscreenGL = makeGLRenderer(offscreenCanvas, enableMSAA);
        if (!_offscreenGL) {
          return null;
        }

        _offscreenGL._hasPixelLocalStorage = Boolean(
          _offscreenGL._gl.getExtension("WEBGL_shader_pixel_local_storage"),
        );

        _offscreenGL._maxRTSize = Math.min(
          _offscreenGL._gl.getParameter(_offscreenGL._gl.MAX_RENDERBUFFER_SIZE),
          _offscreenGL._gl.getParameter(_offscreenGL._gl.MAX_TEXTURE_SIZE),
        );

        // WEBGL_shader_pixel_local_storage works without MSAA.
        _offscreenGL._enableAntialiasCanvas =
          !_offscreenGL._hasPixelLocalStorage;

        const webglDebugInfo = _offscreenGL._gl.getExtension(
          "WEBGL_debug_renderer_info",
        );
        if (webglDebugInfo) {
          const vendor = _offscreenGL._gl.getParameter(
            webglDebugInfo.UNMASKED_VENDOR_WEBGL,
          );
          const renderer = _offscreenGL._gl.getParameter(
            webglDebugInfo.UNMASKED_RENDERER_WEBGL,
          );
          if (
            vendor.includes("Google") &&
            renderer.includes("ANGLE Metal Renderer")
          ) {
            // We experience flickering on Chrome/Metal when using a WebGL context with
            // "antialias:true". This appears to be a synchronization issue internal to the browser.
            // Avoid "antialias:true" in this case, opting instead to do our own internal MSAA.
            _offscreenGL._enableAntialiasCanvas = false;
          }
        }

        return _offscreenGL;
      }

      if (_glCaps) {
        // Rebuild after releaseOffscreenGL, reusing the cached probe results.
        const offscreenCanvas = document.createElement("canvas");
        offscreenCanvas.width = 1;
        offscreenCanvas.height = 1;
        _offscreenGL = makeGLRenderer(
          offscreenCanvas,
          _glCaps._enableAntialiasCanvas,
        );
        if (!_offscreenGL) {
          console.warn(
            "rive_native: WebGL2 is unavailable or disabled in this browser, " +
              "so Rive content cannot render.",
          );
          return null;
        }
        Object.assign(_offscreenGL, _glCaps);
      } else {
        _offscreenGL = MakeOffscreenGL(/*enableMSAA =*/ true);
        if (!_offscreenGL) {
          console.warn(
            "rive_native: WebGL2 is unavailable or disabled in this browser, " +
              "so Rive content cannot render.",
          );
          return null;
        }
        if (!_offscreenGL._enableAntialiasCanvas) {
          // This browser prefers "antialias:false". Re-create the offscreen without MSAA.
          const msaaProbe = _offscreenGL;
          _offscreenGL = MakeOffscreenGL(/*enableMSAA =*/ false);
          // Keep the MSAA one rather than ending up with none at all.
          if (!_offscreenGL) {
            _offscreenGL = msaaProbe;
            return null;
          }
          // Release the discarded probe (C++ renderer + WebGL context): an
          // idle context still occupies one of the browser's ~16 slots,
          // contributing to context-loss evictions elsewhere (including
          // Flutter's own CanvasKit surfaces).
          releaseGLRenderer(msaaProbe);
        }
        _glCaps = {
          _hasPixelLocalStorage: _offscreenGL._hasPixelLocalStorage,
          _maxRTSize: _offscreenGL._maxRTSize,
          _enableAntialiasCanvas: _offscreenGL._enableAntialiasCanvas,
        };
      }
    }
    var renderer = makeGLRenderer(
      canvas,
      /*enableMSAA =*/ _offscreenGL._enableAntialiasCanvas,
    );
    if (!renderer) {
      console.warn(
        "rive_native: the browser refused a WebGL2 context for a canvas; " +
          "its live WebGL context limit is likely exhausted.",
      );
      return null;
    }
    if (renderer) {
      // Extract the renderer-owned ore + PLS render context pointers.
      // These are created in the WebGL2Renderer constructor in the same
      // GL context, so they're guaranteed to match this canvas.
      renderer._oreCtxPtr = Module["_rendererGetOreContext"](renderer["_ptr"]);
      renderer._renderCtxPtr = Module["_rendererGetGPURenderContext"](
        renderer["_ptr"],
      );
      // The GPU's render-target limit, used to clamp canvas backing sizes in
      // clearRenderer (a backing beyond it fails to render at all).
      renderer._maxRTSize = _offscreenGL._maxRTSize;
      // Track the most recently created renderer so clearRenderer() can
      // restore the correct GL context each frame.
      _activeRenderer = renderer;
    }
    return renderer;
  };

  // Hand the canvas to the shared replay worker and create the GL renderer
  // there. Null when the worker entries are absent so Dart falls back inline.
  Module["makeDeferredWorkerRenderer"] = function (canvas, sessionAddr) {
    if (!Module["_riveDeferredWorkerTid"]) {
      return null;
    }
    // The OffscreenCanvas inherits this size, so size before transferring.
    const w = (canvas.clientWidth * (window.devicePixelRatio || 1)) | 0 || 1;
    const h = (canvas.clientHeight * (window.devicePixelRatio || 1)) | 0 || 1;
    canvas.width = w;
    canvas.height = h;
    const oc = canvas.transferControlToOffscreen();
    const tid = Module["_riveDeferredWorkerTid"](); // starts the worker
    // The canvas post waits in resolveWorkerPtr until the worker listener is
    // up, so nothing races the spawn.
    return {
      _ptr: 0,
      _ptrSlot: 0,
      _sessionAddr: sessionAddr,
      _canvas: canvas,
      _oc: oc,
      _tid: tid,
      _w: w,
      _h: h,
      _deferredWorker: true,
    };
  };

  // Posts the canvas with the create request once the worker is ready, both
  // handled in one worker task. Returns 0 until the worker fills the slot.
  function resolveWorkerPtr(renderer) {
    if (renderer._ptr) {
      return renderer._ptr;
    }
    if (!renderer._ptrSlot) {
      if (!Module["_riveDeferredWorkerReady"]()) {
        return 0;
      }
      const rec = PThread.pthreads[renderer._tid];
      const w = rec && rec.worker ? rec.worker : rec;
      if (!w) {
        return 0;
      }
      const slot = Module["_malloc"](4);
      Atomics.store(Module["heapViewU32"](slot, 1), 0, 0);
      w.postMessage(
        {
          riveCanvas: 1,
          id: renderer._canvas.id,
          canvas: renderer._oc,
          tid: renderer._tid,
          session: renderer._sessionAddr,
          w: renderer._w,
          h: renderer._h,
          slot: slot,
        },
        [renderer._oc],
      );
      renderer._ptrSlot = slot;
      return 0;
    }
    const p = Atomics.load(Module["heapViewU32"](renderer._ptrSlot, 1), 0);
    if (p === 0xffffffff) {
      // The worker could not create the renderer; this is terminal.
      renderer._workerFailed = true;
      return 0;
    }
    if (p) {
      renderer._ptr = p;
      renderer._oreCtxPtr = Module["_rendererGetOreContext"](p);
      renderer._renderCtxPtr = Module["_rendererGetGPURenderContext"](p);
    }
    return renderer._ptr || 0;
  }

  // False while the worker renderer is being created, recording then would
  // pile paints into one illegal replayed frame. Also pumps the resolve along.
  Module["deferredRendererReady"] = function (renderer) {
    if (renderer._workerFailed) {
      return -1; // terminal: creation failed, retrying cannot help
    }
    return !renderer._deferredWorker || resolveWorkerPtr(renderer) ? 1 : 0;
  };

  const cppClear = Module["clearRenderer"];
  const cppResize = Module["resizeRenderer"];
  const cppFlush = Module["flushRenderer"];

  // A transferred canvas cannot transfer again, so re-attach reuses the worker
  // renderer. False while it is still being created, the caller retries.
  Module["redeferWorkerRenderer"] = function (renderer, sessionAddr) {
    if (!renderer._ptrSlot) {
      // Nothing posted yet, the eventual create carries the new session.
      renderer._sessionAddr = sessionAddr;
      return true;
    }
    const ptr = resolveWorkerPtr(renderer);
    if (!ptr) {
      return false;
    }
    Module["_riveDeferredWorkerRendererUseSession"](ptr, sessionAddr);
    renderer._sessionAddr = sessionAddr;
    return true;
  };

  // Gives the worker renderer and its GL context back. This is the only place
  // they can be released: the renderer outlives any single session, so session
  // teardown must leave it alone. False while the renderer is still being
  // created — the caller keeps it and retires it later.
  Module["deleteDeferredWorkerRenderer"] = function (renderer) {
    if (!renderer || !renderer._deferredWorker) {
      return false;
    }
    const ptr = resolveWorkerPtr(renderer);
    if (!ptr) {
      return false;
    }
    Module["_riveDeleteDeferredWorkerRenderer"](ptr);
    renderer._ptr = 0;
    renderer._ptrSlot = 0;
    renderer._retired = true;
    return true;
  };

  // Track the active renderer so we know which GL context to restore after
  // ore operations that may have changed it.
  let _activeRenderer = null;

  // Backing policy is pushed onto the renderer by the Dart side
  // (RenderResolution): an explicit physical size wins; otherwise size from
  // the element's layout × devicePixelRatio × per-axis scales (which carry
  // the ancestor paint scale under the display policy), capped at a logical
  // max (aspect preserved). Everything is finally clamped to the GPU's
  // render-target limit.
  function backingSize(renderer) {
    const canvas = renderer._canvas;
    let w, h;
    if (renderer._fixedWidth > 0 && renderer._fixedHeight > 0) {
      w = renderer._fixedWidth;
      h = renderer._fixedHeight;
    } else {
      let lw = canvas.clientWidth * (renderer._backingScaleX || 1);
      let lh = canvas.clientHeight * (renderer._backingScaleY || 1);
      const maxLogical = renderer._maxBackingLogical || 0;
      const longest = Math.max(lw, lh);
      if (maxLogical > 0 && longest > maxLogical) {
        const f = maxLogical / longest;
        lw *= f;
        lh *= f;
      }
      w = Math.round(lw * window.devicePixelRatio) || 1;
      h = Math.round(lh * window.devicePixelRatio) || 1;
    }
    const maxRT = renderer._maxRTSize || 0;
    const longestPhysical = Math.max(w, h);
    if (maxRT > 0 && longestPhysical > maxRT) {
      const f = maxRT / longestPhysical;
      w = Math.max(1, Math.floor(w * f));
      h = Math.max(1, Math.floor(h * f));
    }
    return [w, h];
  }

  Module["clearRenderer"] = function (renderer, color) {
    _activeRenderer = renderer;
    if (renderer._deferredWorker) {
      // The worker owns the GL context, nothing to make current here. Skip
      // until the renderer is ready, the frame is dropped at flush.
      const ptr = resolveWorkerPtr(renderer);
      if (ptr) {
        const [w, h] = backingSize(renderer);
        if (w !== renderer._w || h !== renderer._h) {
          renderer._w = w;
          renderer._h = h;
          Module["_resizeDeferredRendererOnWorker"](ptr, w, h);
        }
        cppClear(ptr, color);
      }
      return;
    }
    GL.makeContextCurrent(renderer._handle);

    const canvas = renderer._canvas;
    const [w, h] = backingSize(renderer);
    if (canvas.width != w || canvas.height != h) {
      canvas.width = w;
      canvas.height = h;
      cppResize(renderer["_ptr"], canvas.width, canvas.height);
    }
    cppClear(renderer["_ptr"], color);
  };

  // Flush takes the renderer object (immediate or deferred worker).
  Module["flushRenderer"] = function (renderer) {
    if (renderer._deferredWorker) {
      const ptr = resolveWorkerPtr(renderer);
      if (!ptr) {
        // Unreachable when the producer gates on deferredRendererReady. No
        // reset, the stream is stateful and creates must replay in order.
        if (!renderer._warnedNotReady) {
          renderer._warnedNotReady = true;
          console.warn(
            "rive_native: flush before worker renderer ready; " +
              "gate frames on canAcceptDeferredFrame",
          );
        }
        return;
      }
      cppFlush(ptr);
      return;
    }
    cppFlush(renderer["_ptr"]);
  };

  Module["stringViewU8"] = function (start) {
    var buffer = heapBuffer();
    var data = new Uint8Array(buffer, buffer.byteOffset, buffer.byteLength);
    var current = start;
    while (data[current] != 0 && current < buffer.byteLength) {
      current++;
    }
    return new Uint8Array(buffer, start, current - start);
  };

  var nativeMakeGlyphPath = Module["makeGlyphPath"];
  var move = 0;
  var line = 1;
  var quad = 2;
  var cubic = 4;
  var close = 5;
  Module["makeGlyphPath"] = function (font, glyphId) {
    var glyph = nativeMakeGlyphPath(font, glyphId);
    var verbCount = glyph[3];
    var ptsPtr = glyph[1];
    var verbPtr = glyph[2];
    var verbs = Module["heapViewU8"](verbPtr, verbCount);

    let pointCount = 0;
    for (var verb of verbs) {
      switch (verb) {
        case move:
        case line:
          pointCount++;
          break;
        case quad:
          pointCount += 2;
          break;
        case cubic:
          pointCount += 3;
          break;
        default:
          break;
      }
    }

    const ptsStart = ptsPtr;
    return {
      "rawPath": glyph[0],
      "verbs": verbs,
      "points": Module["heapViewF32"](ptsStart, pointCount * 2),
    };
  };

  // Editor-only boolean path ops (absent in flutter_runtime wasm builds).
  // Like makeGlyphPath, converts the embind value_array (indexed, raw heap
  // pointers) into an object with named fields and typed-array views.
  var nativePathOpsResult = function (result) {
    var verbCount = result[3];
    var pointCount = result[4];
    return {
      "rawPath": result[0],
      "points": Module["heapViewF32"](result[1], pointCount * 2),
      "verbs": Module["heapViewU8"](result[2], verbCount),
      "verbCount": verbCount,
      "pointCount": pointCount,
      "fillRule": result[5],
      "success": result[6],
    };
  };
  // Editor-only exports (excluded from flutter_runtime modules). Gate on
  // ALL of them so a partial module leaves everything unwrapped and the
  // Dart side's link() fails closed (pathOpsAvailable == false) instead of
  // wrapping a missing export.
  if (
    Module["combinePaths"] &&
    Module["simplifyPath"] &&
    Module["deletePathOpsResult"]
  ) {
    var nativeCombinePaths = Module["combinePaths"];
    Module["combinePaths"] = function (op, ptsA, vbsA, fillA, ptsB, vbsB, fillB) {
      return nativePathOpsResult(
        nativeCombinePaths(op, ptsA, vbsA, fillA, ptsB, vbsB, fillB)
      );
    };
    var nativeSimplifyPath = Module["simplifyPath"];
    Module["simplifyPath"] = function (pts, vbs, fill) {
      return nativePathOpsResult(nativeSimplifyPath(pts, vbs, fill));
    };
  }

  var nativeShapeText = Module["shapeText"];
  Module["shapeText"] = function (codeUnits, runsList, level) {
    var shapeResult = nativeShapeText(codeUnits, runsList, level);
    return {
      "rawResult": shapeResult,
      "results": Module["heapDataView"](shapeResult),
    };
  };

  var nativeBreakLines = Module["breakLines"];
  Module["breakLines"] = function (shape, width, align, wrap, wordBreak) {
    var breakResult = nativeBreakLines(shape, width, align, wrap, wordBreak);
    return {
      "rawResult": breakResult,
      "results": Module["heapViewU8"](breakResult),
    };
  };

  var nativeFontFeatures = Module["fontFeatures"];
  Module["fontFeatures"] = function (font) {
    var featuresPtr = nativeFontFeatures(font);
    var heap = Module["heap"]();
    const view = new DataView(heap, featuresPtr);
    var dataPtr = view["getUint32"](0, true);
    var size = view["getUint32"](4, true);

    const dataView = new DataView(heap, dataPtr);

    var tags = [];
    for (var i = 0; i < size; i++) {
      var tag = dataView["getUint32"](i * 4, true);
      tags.push(tag);
    }

    Module["deleteFontFeatures"](featuresPtr);
    return tags;
  };

  Module["heap"] = function (start, length) {
    return heapBuffer();
  };

  Module["heapViewU8"] = function (start, length) {
    return new Uint8Array(heapBuffer(), start, length);
  };

  Module["heapViewU16"] = function (start, length) {
    return new Uint16Array(heapBuffer(), start, length);
  };

  Module["heapViewU32"] = function (start, length) {
    return new Uint32Array(heapBuffer(), start, length);
  };

  Module["heapViewF32"] = function (start, length) {
    return new Float32Array(heapBuffer(), start, length);
  };

  Module["heapDataView"] = function (start, length) {
    return new DataView(heapBuffer(), start, length);
  };

  var scriptingWorkspaceResponse = Module["scriptingWorkspaceResponse"];
  Module["scriptingWorkspaceResponse"] = function (workspace, workId) {
    var response = scriptingWorkspaceResponse(workspace, workId);
    var available = response[0];
    var dataPtr = response[1];
    var size = response[2];
    var data = available ? Module["heapDataView"](dataPtr, size) : null;

    return {
      "available": available,
      "data": data,
    };
  };

  var riveLuaConsole = Module["riveLuaConsole"];
  Module["riveLuaConsole"] = function (state) {
    var response = riveLuaConsole(state);
    var dataPtr = response[0];
    var size = response[1];
    var data = Module["heapDataView"](dataPtr, size);

    return data;
  };

  var scriptingWorkspaceHighlightRow = Module["scriptingWorkspaceHighlightRow"];
  Module["scriptingWorkspaceHighlightRow"] = function (workspace, name, row) {
    var response = scriptingWorkspaceHighlightRow(workspace, name, row);
    var count = response[0];
    var dataPtr = response[1];
    var data = Module["heapViewU32"](dataPtr, count);

    return data;
  };

  var nativeFontBytes = Module["_nativeFontBytes"];
  Module["nativeFontBytes"] = function () {
    var dataPtr = nativeFontBytes();
    var count = Module["_nativeFontSize"]();
    return Module["heapViewU8"](dataPtr, count);
  };

  // initGPUScriptingGL and getGPURenderContextPtr removed — GL context handle,
  // ore context, and render context are now passed explicitly through
  // riveVMAdopt via the RenderTexture, eliminating global renderer tracking.

  // riveLuaPushCanvas / riveLuaPushGPUCanvas are now RIVE_FFI_EXPORT'd at their
  // definition sites, so EMSCRIPTEN_KEEPALIVE exports them as _riveLuaPush*.
  // The Dart-web layer accesses them without the leading underscore.
  Module["riveLuaPushCanvas"] = Module["_riveLuaPushCanvas"];
  Module["riveLuaPushGPUCanvas"] = Module["_riveLuaPushGPUCanvas"];
  Module["riveLuaContextBeginRenderPass"] =
    Module["_riveLuaContextBeginRenderPass"];

  // GL context switching and frame management are handled in C++ inside
  // riveGPUBeginFrameExport / riveGPUEndFrameExport (WASM-only wrappers).
  Module["riveGPUBeginFrame"] = Module["_riveGPUBeginFrameExport"];
  Module["riveGPUEndFrame"] = Module["_riveGPUEndFrameExport"];

  if (typeof Module["requestSerializedViewModelInstanceWasm"] === "function") {
    var requestSerializedViewModelInstanceWasm =
      Module["requestSerializedViewModelInstanceWasm"];
    var freeViewModelInstanceSerializedDataWasm =
      Module["freeViewModelInstanceSerializedDataWasm"];
    Module["_requestSerializedViewModelInstance"] = function (
      filePtr,
      instancePtr,
    ) {
      var response = requestSerializedViewModelInstanceWasm(
        filePtr,
        instancePtr,
      );
      if (!response || response.size === 0) {
        return null;
      }
      var bytes = Module["heapViewU8"](response.data, response.size);
      var copy = Array.from(bytes);
      freeViewModelInstanceSerializedDataWasm(response);
      return copy;
    };
  }
};
