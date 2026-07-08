# Motion Brush (working title) — MVP PRD & Technical Specification

Version 1.0 — July 2026
Status: Ready for implementation
Audience: An autonomous coding agent building the iOS MVP end-to-end. This document is the single source of truth; where behavior is unspecified, follow the Tunable Constants table (§T) and the stated product principle rather than inventing UI.

---

# PART 1 — PRODUCT REQUIREMENTS (PRD)

## 1. One-liner

Record a short video; the app automatically cuts the main subject out of every frame and turns the sequence into a paint brush. Drawing a stroke stamps the frames in order along the path — like dragging a flip-book across a canvas.

## 2. Product principle (governs all ambiguity)

**The user makes exactly one creative decision: what to point the camera at.** Everything downstream — subject selection, segmentation, frame count, brush spacing, stamp size — is automatic. There are no sliders, no mask editors, no confirmation dialogs, no settings screen in the MVP. When the pipeline produces an imperfect result, the product treats it as a happy accident, never as an error to be corrected by the user. Any implementation choice that would add a user decision is wrong by definition.

## 3. Target user & platform

Casual creative users (all ages; assume kids and adults). iPhone only for MVP, portrait orientation only, iOS 17.0+. No accounts, no network, everything on-device. Apple Pencil is not required; touch is the primary input (iPad support is out of scope).

## 4. User journey

The app has three states that form a loop:

1. **Canvas (home).** A white canvas fills the screen. A brush shelf runs along the bottom showing saved brushes as small looping animated stroke previews. A prominent camera button opens Capture. If the user has zero brushes (first launch), the canvas is replaced by an empty state with a single call-to-action: the camera button and the line "Film something that moves."
2. **Capture.** Full-screen camera. Press-and-hold (or tap-to-start / tap-to-stop) records a clip between 1 and 8 seconds. Releasing (or hitting the cap) immediately transitions to Processing. A flip-camera button is the only other control.
3. **Processing ("the theater").** No spinner. As each frame is segmented, its cutout animates into view, stacking like scissored paper dolls, with a frame counter ("14 of 72"). When complete, the app transitions to the Canvas and, before handing over control, draws a demo squiggle across the canvas with the new brush by itself over ~1.5 s. This demo stroke teaches the mechanic wordlessly. The demo stroke is a real stroke (it appears on canvas and is undoable).

The loop: draw → want a new brush → record → new brush appears selected on the shelf → draw.

## 5. Functional requirements

Requirements are numbered for traceability. "MUST" items are MVP-blocking.

### 5.1 Capture

- **FR-1** The app MUST record video via the rear camera by default, with a flip-camera toggle. 1080p, 30 fps, portrait.
- **FR-2** Recording duration MUST be clamped to 1.0–8.0 s. Recording auto-stops at 8.0 s. Clips under 1.0 s are discarded with a brief toast ("Hold longer") and the camera stays open.
- **FR-3** A live duration indicator (progress ring or bar filling toward the 8 s cap) MUST be visible while recording.
- **FR-4** The recorded clip MUST NOT be saved to the user's photo library. It is a temporary intermediate, deleted after brush creation succeeds or fails.
- **FR-5** Camera and microphone: request camera permission only (no audio track needed — configure the session without audio input so no mic permission prompt appears).
- **FR-6** Importing videos from the photo library is OUT of MVP scope. Capture only.

### 5.2 Segmentation & brush creation

- **FR-7** The app MUST sample the clip at a target rate of 12 fps, capped at 96 frames total (see §T). An 8 s clip therefore yields 96 frames; a 2 s clip yields 24.
- **FR-8** For each sampled frame, the app MUST segment the "main character" fully automatically using on-device Vision instance masks, with temporal anchoring: the dominant subject of the first usable frame is tracked across subsequent frames by mask-overlap matching (algorithm in §9.3). The user never selects or confirms a subject.
- **FR-9** Frames where segmentation finds no acceptable instance MUST reuse the most recent successful frame's cutout (never a blank stamp, never an error).
- **FR-10** If fewer than 8 frames in the entire clip produce a usable mask, brush creation fails gracefully: return to Capture with the message "Couldn't find a subject — try filming something that moves." No partial brush is saved.
- **FR-11** Each successful frame becomes a cropped, matted RGBA stamp, downsampled to at most 512 px on the longest edge, preserving the raw scale variation between frames (no size normalization — subject growing/shrinking along the stroke is intended behavior).
- **FR-12** Processing MUST stream progress to the theater UI per frame (cutout image + index) so the stacking animation reflects real work.
- **FR-13** Total processing time budget: ≤ 10 s for an 8 s clip on an iPhone 14 (A16) class device; ≤ 6 s on A17 Pro and later. If exceeded, ship anyway — the theater absorbs the wait — but log it.
- **FR-14** On success, the brush is persisted (format in §10), auto-named ("Brush 1", "Brush 2", …), selected as the active brush, and the app transitions to Canvas and plays the demo stroke (FR-24).

### 5.3 Brush library (shelf)

- **FR-15** Saved brushes appear on a horizontal shelf at the bottom of the Canvas, most recent first. Each shelf item shows a looping animated preview: a short pre-rendered stroke made with that brush (generated once at creation time as an animated image, see §10.4).
- **FR-16** Tapping a shelf item selects it as the active brush (visible selection ring). Exactly one brush is always active when at least one exists.
- **FR-17** Long-pressing a shelf item offers exactly one action: Delete (with confirm). Deleting the active brush activates the next most recent. No rename, no reorder, no duplicate in MVP.
- **FR-18** The shelf MUST support at least 50 brushes with smooth scrolling. There is no hard cap in MVP; storage pressure is out of scope.

### 5.4 Canvas & drawing

- **FR-19** The canvas is a fixed-size white surface matching the device screen's point size at 2× pixel density (no zoom, no pan, no layers in MVP).
- **FR-20** Drawing a stroke stamps the active brush's frames in order along the path at a fixed arc-length interval (default 0.40 × stamp width, §T). Frame index resets to 0 at the start of every stroke and loops forward (frame 0 follows the last frame) on strokes longer than one cycle.
- **FR-21** Stroke rendering MUST feel latency-free: use coalesced and predicted touches; visible tip lag on a ProMotion device should be imperceptible in hand testing.
- **FR-22** Stamps composite with standard premultiplied-alpha "over" blending in stroke order. Later strokes draw over earlier strokes.
- **FR-23** Undo: an undo button reverts the most recent stroke; MUST support at least the last 20 strokes. A clear-canvas button (with confirm) erases everything. No redo in MVP.
- **FR-24** Demo stroke: after brush creation, the app programmatically draws a predefined smooth S-curve across the upper-middle canvas using the new brush at normal spacing, animated over ~1.5 s. It is a normal stroke (undoable, exportable).
- **FR-25** Export: a share button composites the canvas over white, produces a PNG at canvas pixel resolution, and presents the system share sheet. Saving to Photos happens through the share sheet (use the add-only photo permission path).

### 5.5 Persistence & lifecycle

- **FR-26** Brushes and the current canvas MUST survive app termination. On relaunch, restore the canvas bitmap, brush shelf, and active brush selection. (Undo history does not need to survive relaunch.)
- **FR-27** All data lives in the app sandbox. No network calls of any kind. No analytics SDKs in MVP.

## 6. Non-goals (explicitly out of MVP)

No mask editing or subject re-selection. No brush parameters exposed to users (size, spacing, opacity). No color tinting. No layers, zoom, pan, or eraser. No video import from library. No iPad/landscape. No accounts, cloud sync, sharing feeds, or watermarks. No ping-pong or randomized frame ordering. No pressure/velocity dynamics (scaffold the hooks, ship them off — §T). No localization beyond English.

## 7. Edge cases & required behaviors

| # | Situation | Required behavior |
|---|---|---|
| E1 | Camera permission denied | Capture screen shows explanation + button deep-linking to Settings |
| E2 | Subject leaves frame mid-clip | Tracking reuses last good cutout (FR-9); when subject returns, IoU matching may or may not reacquire it — either outcome ships |
| E3 | Multiple subjects, tracker drifts to the wrong one | Ships as-is (happy accident, per §2) |
| E4 | Zero usable frames | FR-10 failure message, return to capture |
| E5 | App backgrounded during processing | Pipeline continues via background task if granted; if killed, no partial brush persists (creation is atomic, §10.3) |
| E6 | App backgrounded mid-stroke | Stroke is committed as-is at touch cancellation |
| E7 | Very fast flick stroke | Stamps remain at fixed arc-length spacing (may be only 2–3 stamps); no minimum stamp count |
| E8 | Tap without drag | Places a single stamp (frame 0) |
| E9 | Low storage / write failure | Brush creation fails with a toast; capture clip deleted; app remains stable |
| E10 | Device thermal throttling during processing | Acceptable slowdown; no timeout abort |

## 8. Acceptance criteria (MVP is "done" when)

1. Fresh install → first brush drawn on canvas in under 60 seconds of user time, with the only decisions being "what to film" and "where to draw."
2. Recording a 5 s clip of a person walking produces a brush whose stamps visibly step through the motion in order when drawing a long stroke.
3. Drawing at 120 Hz on a ProMotion device shows no hitching (Instruments: no frame > 16 ms during a stroke; target 8 ms).
4. Kill and relaunch the app: canvas contents, shelf, and selection restore exactly.
5. All of §5 MUST items pass the manual QA checklist in §14.

---

# PART 2 — TECHNICAL SPECIFICATION

## 9. Platform, stack, and architecture

### 9.1 Targets and dependencies

Swift 6 language mode (or 5.10 with strict concurrency), Xcode 16+, deployment target iOS 17.0. Frameworks: SwiftUI (app chrome), UIKit (touch handling host view), AVFoundation (capture + frame extraction), Vision (segmentation), CoreImage (matting/cropping), Metal + MetalKit (canvas), CoreVideo, Photos (export via share sheet only). **Zero third-party dependencies.** No PencilKit (it cannot render animated stamp brushes). No CoreML models bundled in MVP (Vision's built-in requests only).

### 9.2 Module layout (Swift Package targets inside the app project)

```
MotionBrush/
├── App/                     SwiftUI app, navigation state machine, screens
│   ├── CanvasScreen.swift   hosts CanvasView (UIViewRepresentable), shelf, toolbar
│   ├── CaptureScreen.swift  hosts camera preview + record control
│   └── ProcessingScreen.swift  the "theater" (consumes AsyncStream from BrushFactory)
├── CaptureService/          AVCaptureSession wrapper → temp .mov URL
├── BrushFactory/            video URL → BrushAsset (the full pipeline, §9.3–9.6)
│   ├── FrameSampler.swift
│   ├── SubjectSegmenter.swift
│   ├── StampProcessor.swift
│   └── AtlasPacker.swift
├── BrushStore/              persistence, index, thumbnails (§10)
├── CanvasEngine/            Metal renderer + stroke model (§11)
│   ├── CanvasRenderer.swift
│   ├── StrokeBuilder.swift  touch → path → stamp list
│   ├── Shaders.metal
│   └── UndoStack.swift
└── Shared/Constants.swift   every tunable in §T lives here, nowhere else
```

App navigation is a simple three-state enum (`canvas`, `capture`, `processing(job)`) held in an `@Observable` AppModel. No routing library.

### 9.3 Pipeline stage 1 — frame sampling (FrameSampler)

Input: local `.mov` URL. Output: ordered `[CVPixelBuffer]` (or stream of them).

Use `AVAssetReader` with an `AVAssetReaderTrackOutput` on the video track, `outputSettings` requesting `kCVPixelFormatType_32BGRA`. Do NOT use `AVAssetImageGenerator` (an order of magnitude slower for sequential reads). Compute a keep-stride from the track's nominal frame rate:

```
sourceFPS   = videoTrack.nominalFrameRate            // typically 30
targetFPS   = K.samplingFPS                          // 12
stride      = max(1, Int(round(sourceFPS / targetFPS)))
keep frame i where i % stride == 0, until K.maxFrames (96) kept
```

Apply the track's `preferredTransform` so buffers are upright before segmentation. Emit frames via `AsyncThrowingStream<SampledFrame>` where `SampledFrame = (index: Int, pixelBuffer: CVPixelBuffer, time: CMTime)` so downstream stages and the theater UI can consume progressively. Run on a dedicated background task; never touch the main thread.

### 9.4 Pipeline stage 2 — segmentation with temporal anchoring (SubjectSegmenter)

Per frame, run `VNGenerateForegroundInstanceMaskRequest` via a `VNImageRequestHandler` on the pixel buffer. The request returns a `VNInstanceMaskObservation` containing N instances.

Selection algorithm (the core of "scenario 1 without a tap"):

```
state: previousMask: CGImage? (low-res), previousBBox: CGRect?

for each frame:
  observation = run VNGenerateForegroundInstanceMaskRequest
  if observation empty or has 0 instances → emit .miss; continue

  candidates = for each instance index i:
      mask_i  = observation.generateScaledMaskForImage(forInstances: [i], ...)
                 downscaled to 128 px longest edge (cheap comparison space)
      bbox_i  = bounding box of mask_i (normalized coords)
      area_i  = fraction of pixels > 0.5

  if previousMask == nil:                    // first usable frame: pick dominant
      score_i = area_i * (1.0 - K.centerBias * distance(bboxCenter_i, (0.5, 0.5)))
      pick argmax score_i; require area_i >= K.minSubjectArea (0.5% of frame) else .miss
  else:                                      // subsequent frames: track by overlap
      iou_i = IoU(bbox_i, previousBBox)      // bbox IoU first (cheap gate)
      pick argmax over candidates with iou_i >= K.minTrackIoU (0.10) of
           mask IoU(mask_i, previousMask)    // refine with 128px mask IoU
      if none pass the gate → fall back to dominant-pick rule above
                              (subject may have jumped; reacquire rather than miss)

  on pick: previousMask/BBox ← picked (at 128 px); emit .hit(instanceIndex)
```

Notes for the agent: `generateScaledMaskForImage(forInstances:from:)` produces the full-resolution matte for the chosen instance only — call it once per frame for the picked instance at full res (for matting) and use the cheap 128 px versions only for candidate comparison. Reuse one `VNImageRequestHandler` per frame; requests run on the Neural Engine automatically. A `.miss` frame is resolved by StampProcessor duplicating the previous stamp (FR-9). Track hit/miss counts; if hits < 8 at the end, throw `BrushError.noSubject` (FR-10).

### 9.5 Pipeline stage 3 — matting, cropping, stamp production (StampProcessor)

For each hit frame: build `CIImage` from the source buffer and the full-res soft matte; composite with `CIBlendWithMask` (source over clear background) so output is premultiplied RGBA with the matte as alpha. Compute the matte's tight bounding box at alpha > 0.02, outset by `K.cropPadding` (4% of the box's longest side), intersect with frame bounds, crop. Downsample so longest edge ≤ `K.maxStampEdge` (512 px) using `CILanczosScaleTransform`. Record the stamp's **anchor** as the alpha-weighted centroid of the matte in cropped-stamp coordinates (this is the point that rides the stroke path — centroid, not rect center, so lopsided cutouts don't wobble). Render to a `CGImage` via a shared `CIContext` (Metal-backed, created once). Emit `(index, cgImage, anchor, pixelSize)` to both the theater stream and the packer. No size normalization across frames (FR-11).

### 9.6 Pipeline stage 4 — atlas packing (AtlasPacker)

Pack stamps into one or more 4096×4096 RGBA atlas pages using simple shelf packing (sort by height desc, fill rows left-to-right; no fancy bin packing needed at ≤96 stamps of ≤512 px). 2 px gutter between rects to prevent sampling bleed. Persist each page as HEIC with alpha (quality 0.9); record per-frame `{page, rect(px), anchor(px), sourceSize}` in the manifest. At draw time the CanvasEngine loads pages into `MTLTexture`s (loaded lazily on brush activation, kept for the active brush only).

Pipeline concurrency: stages 1→2 run as an async pipeline with a small buffer (segmentation is the bottleneck; do not parallelize segmentation across frames beyond 2 in flight — tracking is sequential by nature since each pick depends on the previous). Stage 3 can run concurrently per frame after its pick is made. The whole job is cancellable (user backs out of processing → cancel, delete temp files).

## 10. Brush asset format & persistence (BrushStore)

### 10.1 On-disk layout

```
Application Support/Brushes/
├── index.json                     ordered list of brush IDs + active brush ID
└── <uuid>/
    ├── manifest.json
    ├── atlas-0.heic               (atlas-1.heic … if needed)
    └── preview.gif                looping shelf preview (§10.4)
Application Support/Canvas/
└── canvas.png                     current canvas bitmap (saved on scene background)
```

### 10.2 manifest.json schema

```json
{
  "schemaVersion": 1,
  "id": "8F0C…",
  "name": "Brush 3",
  "createdAt": "2026-07-07T15:04:05Z",
  "frameCount": 72,
  "sourceDuration": 6.0,
  "suggestedSpacingFactor": 0.40,
  "atlasPages": ["atlas-0.heic"],
  "frames": [
    { "i": 0, "page": 0, "rect": [2, 2, 388, 500],
      "anchor": [190.4, 261.0], "duplicateOf": null },
    { "i": 7, "page": 0, "rect": [2, 2, 388, 500],
      "anchor": [190.4, 261.0], "duplicateOf": 6 }
  ]
}
```

`duplicateOf` marks miss-frames that reuse an earlier stamp (they share the atlas rect; no pixels duplicated).

### 10.3 Atomicity

Build each brush in a temp directory; on full success, move it into `Brushes/` and rewrite `index.json` (write-temp-then-rename). A crash mid-creation leaves no partial brush (E5).

### 10.4 Shelf preview

At creation time, render a fixed 12-stamp S-curve stroke with the new brush into 12 accumulating frames at 240×120 pt and encode as a looping GIF (or APNG) via ImageIO. The shelf just plays the file — no live Metal rendering per shelf cell, which keeps 50-brush scrolling cheap (FR-18).

## 11. CanvasEngine (Metal)

### 11.1 Rendering model

- `MTKView`, `bgra8Unorm`, `isPaused = true`, draw on demand (`setNeedsDisplay` per touch batch and per commit). Canvas pixel size = view point size × 2 regardless of device scale (FR-19).
- **committedTexture** (`MTLTexture`, canvas-sized): all finished strokes, initialized white (or from `canvas.png` on restore).
- **liveStroke**: the in-progress stroke's stamp list, re-rendered each frame on top of committedTexture. Predicted-touch stamps are appended for display but flagged and dropped when real touches supersede them.
- On `touchesEnded`: render the final stamp list into committedTexture (one offscreen pass), push the stroke onto the undo stack, clear liveStroke.
- Draw pass: blit committedTexture to drawable → instanced draw of liveStroke stamps. Blending: premultiplied source-over (`sourceRGB = one, destRGB = oneMinusSourceAlpha`).

### 11.2 Touch → path → stamps (StrokeBuilder)

In a `UIView` subclass (hosted via `UIViewRepresentable`):

```
touchesMoved:
  pts += event.coalescedTouches(for: touch).map { $0.location }
  predicted = event.predictedTouches(for: touch)?.map { $0.location } ?? []
```

Smooth with Catmull-Rom through the raw points (centripetal parameterization, α = 0.5), flatten each segment into ~8 line steps, and feed the polyline into an arc-length stamper that persists across the whole stroke:

```
struct Stamper {
  var residual: CGFloat = 0        // distance carried between touch batches
  var frameIdx: Int = 0            // resets to 0 per stroke (FR-20)
  mutating func consume(polyline: [CGPoint], brush: Brush) -> [Stamp] {
    var out: [Stamp] = []
    for seg in zip(polyline, polyline.dropFirst()) {
      var d = distance(seg.0, seg.1); var t0 = 0.0
      let spacing = brush.frames[frameIdx].width * K.spacingFactor  // 0.40
      while residual + (d - t0) >= spacing {
        t0 += spacing - residual; residual = 0
        let p = lerp(seg.0, seg.1, t0 / d)
        out.append(Stamp(center: p, frame: frameIdx))
        frameIdx = (frameIdx + 1) % brush.frameCount               // forward loop
      }
      residual += d - t0
    }
    return out
  }
}
```

A tap with no movement emits a single frame-0 stamp (E8). Stamp quads are positioned so the brush frame's `anchor` lands on the path point, sized to the frame's native pixel size mapped 1:1 to canvas pixels (i.e., a 512 px stamp is 256 pt on a 2× canvas). No rotation-to-path-tangent in MVP (`K.rotateToTangent = false` — scaffold the uniform, ship it off).

### 11.3 Shaders

One vertex/fragment pair. Vertex: instanced unit quad, per-instance `{center, halfSize, uvRect, pageIndex}` from a shared `MTLBuffer`; fragment samples the atlas (`texture2d_array` or bind per-page and bucket instances by page — with ≤2 pages, two draw calls is fine). Linear filtering, clamp-to-edge.

### 11.4 Undo & clear (UndoStack)

Undo is stroke-replay: keep the last `K.undoDepth` (20) strokes as stamp lists. On undo, clear committedTexture to white (or restored base) and replay all remaining strokes in one pass — at MVP stamp counts this is a few thousand instanced quads, i.e., trivially under one frame. The restored `canvas.png` acts as the replay base for strokes drawn before relaunch. Clear-canvas resets base to white and empties the stack (behind a confirm).

### 11.5 Export

Composite committedTexture (plus nothing else — no UI) over opaque white, read back to `CGImage`, wrap in PNG, present `UIActivityViewController` (FR-25).

## 12. Screen specs (App module)

**CanvasScreen.** Full-bleed canvas. Bottom shelf: horizontally scrolling 72 pt cells (preview GIF, 2 pt selection ring in accent color), leading camera button (56 pt, prominent). Top-trailing toolbar: undo, clear, share — plain SF Symbols, no labels. Empty state (0 brushes): hide shelf/toolbar, centered camera button + "Film something that moves."

**CaptureScreen.** `AVCaptureVideoPreviewLayer` full screen; bottom-center record control with progress ring toward 8 s; flip-camera top-trailing; close top-leading (returns to canvas without recording). Haptic on record start/stop.

**ProcessingScreen.** Consumes the BrushFactory `AsyncStream`. Each arriving cutout (CGImage) animates in with a small random rotation (±6°) and offset, stacking centered; counter "n of N" beneath; subtle scale-in per arrival (spring, 0.25 s). On success: crossfade to CanvasScreen, then run the demo stroke (feed the S-curve points through the normal StrokeBuilder at ~60 pts/s so it uses the production path, not a special case). On `BrushError.noSubject`: transition back to CaptureScreen with the FR-10 message as an overlay toast. A close/cancel button cancels the job and returns to Capture.

## 13. Error handling matrix

| Error | Surface | Recovery |
|---|---|---|
| Camera permission denied | CaptureScreen inline state | Settings deep link (E1) |
| `BrushError.noSubject` | Toast on CaptureScreen | User re-records (FR-10) |
| `BrushError.io` (disk write) | Toast "Couldn't save brush" | Temp cleaned, stay stable (E9) |
| Reader/Vision throw mid-job | Treated as `.noSubject` if hits < 8, else proceed with hits | Same paths as above |
| Corrupt brush on load (manifest/atlas unreadable) | Skip brush, log; if it was active, activate next | Never crash on load |
| Metal device unavailable | Fatal alert (should not occur on iOS 17 hardware) | — |

## 14. Testing & QA

**Unit tests (XCTest):** (1) Stamper determinism — a fixed polyline + fixed brush produces an exact expected stamp list, including residual carry-over across `consume` calls and frame-index wraparound; (2) IoU picker — synthetic candidate sets verify first-frame dominant pick, tracking pick, gate-failure reacquisition, and miss emission; (3) AtlasPacker — all rects within page bounds, no overlaps, gutters respected; (4) BrushStore atomicity — simulated failure mid-creation leaves index and disk consistent; (5) manifest JSON round-trip.

**Integration test:** bundle a 3 s fixture video of a moving toy; full pipeline must produce ≥ 20 frames, monotonically ordered, with < 30% duplicateOf frames.

**Performance (Instruments, on-device):** stroke draw ≤ 8 ms/frame at 120 Hz with a 96-frame brush; pipeline within FR-13 budgets; memory high-water < 400 MB during processing (release buffers as the stream advances — do not hold all full-res pixel buffers simultaneously).

**Manual QA checklist:** every FR in §5; every edge case E1–E10; dark-mode/system-font-size sanity on chrome; kill-and-relaunch restore (acceptance #4).

## 15. Build order (milestones an agent should follow)

1. **M1 — Canvas engine with fixture brush.** CanvasEngine + StrokeBuilder + undo/export, loading a bundled folder of pre-cut PNGs as a hardcoded brush. Exit: acceptance #3 passes; drawing feels right. *All feel-tuning happens here against §T.*
2. **M2 — Brush pipeline offline.** BrushFactory end-to-end from a bundled fixture video to a BrushAsset on disk; unit + integration tests green.
3. **M3 — BrushStore + shelf.** Persistence, index, previews, selection, delete, relaunch restore.
4. **M4 — Capture + theater.** CaptureService, ProcessingScreen streaming, demo stroke, failure paths.
5. **M5 — Polish pass.** Haptics, animations, empty state, QA checklist, performance sign-off.

## §T — Tunable constants (Shared/Constants.swift; the ONLY place these values may live)

| Constant | Default | Notes |
|---|---|---|
| `samplingFPS` | 12 | FR-7 |
| `maxFrames` | 96 | FR-7 |
| `minClipSec / maxClipSec` | 1.0 / 8.0 | FR-2 |
| `minSubjectArea` | 0.005 | fraction of frame, first-frame pick gate |
| `centerBias` | 0.5 | first-frame dominant scoring |
| `minTrackIoU` | 0.10 | bbox gate before mask-IoU refine |
| `maskCompareEdge` | 128 | px, cheap-comparison mask size |
| `cropPadding` | 0.04 | of crop's longest side |
| `maxStampEdge` | 512 | px, FR-11 |
| `spacingFactor` | 0.40 | × current frame width, FR-20 |
| `resetFrameIndexPerStroke` | true | FR-20 |
| `rotateToTangent` | false | scaffolded, off in MVP |
| `velocitySpacing` | false | scaffolded, off in MVP |
| `undoDepth` | 20 | FR-23 |
| `demoStrokeDuration` | 1.5 s | FR-24 |
| `atlasPageEdge` | 4096 | px |

## 16. Post-MVP roadmap (for context; do not build)

SAM 2 Core ML propagation for robust tracking through occlusion; ping-pong frame ordering and velocity-modulated spacing as brush "moods" (still chosen automatically, never as settings); Apple Pencil pressure → stamp scale; iPad + larger canvases; brush sharing via exported `.brush` bundles.
