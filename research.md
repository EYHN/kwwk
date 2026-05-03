# KW Computer Use Background Activation Research

## Current Findings

- `CGEvent.postToPid(pid)` is a good background action transport: it can deliver clicks to the target process without moving the system cursor and without raising the target window.
- `postToPid` does not go through the WindowServer hardware-input activation path, so by itself it does not make the target app/window enter AppKit `active` / `key` / `main` state. It also does not reliably light the macOS traffic-light controls.
- `AXPress` can invoke a control in the background, but it also does not create AppKit activation. Combining `AXPress` with `NSRunningApplication.activate(...)` did not produce background `active/key/main`.
- `NSRunningApplication.activate(.activateAllWindows)` plus focus-event suppression is not a usable synthetic activation path. In the Probe test it left ProbeB inactive/key false/main false.
- A real HID click through `CGEvent.post(tap: .cghidEventTap)` can trigger the AppKit/CPS activation path. With per-pid focus-event suppression, ProbeB can remain internally:
  - `NSApp.isActive == true`
  - `window.isKeyWindow == true`
  - `window.isMainWindow == true`
  - `NSApp.keyWindow === window`
  - `NSApp.mainWindow === window`
  while the system frontmost app is restored to ProbeA or another previous app.
- The working activation shape is:
  1. Install per-pid event taps for the previous frontmost app and the target app using `CGEvent.tapCreateForPid`.
  2. During target activation, drop the previous app's AppKit/CPS focus-lost messages and allow the target app's focus-gained messages.
  3. Trigger target activation with a trusted HID mouse event.
  4. Restore the previous frontmost app.
  5. During restore/hold, drop the target app's resign/deactivate/key-lost/main-lost messages.
- The focus messages observed so far include raw CG event types `13`, `19`, and `20`; `NSEvent(cgEvent:)` often reports `type.rawValue == 13`, with subtypes such as `1`, `2`, `4`, `21`, `22`, and `23`.
- The current HID activation path has a major drawback: even after removing explicit `.mouseMoved`, HID mouse down/up updates WindowServer's global cursor location. This violates the requirement that KW background actions must not move the user's visible cursor.

## Working Separation

The implementation should separate activation from action delivery:

- Activation layer: find a cursor-preserving way to put the target app/window into background AppKit `active/key/main`.
- Action layer: use `postToPid` where possible for click/type/scroll/drag so actions do not move the user's cursor.

## Candidate Activation Experiments

Each experiment must reset ProbeA/ProbeB before running, because previous focus suppression can leave Probe state contaminated.

- AX focused-window path:
  - `AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute, window)`
  - `AXUIElementSetAttributeValue(window, kAXMainAttribute, true)` if settable
  - observe whether ProbeB reaches `active/key/main` without cursor movement or raise.
- AX raise/focus combinations:
  - `AXUIElementPerformAction(window, kAXRaiseAction)`
  - then focused-window/main attributes
  - observe whether it activates, raises, or only changes AX bookkeeping.
- Cursor-detached HID:
  - `CGAssociateMouseAndMouseCursorPosition(false)`
  - post HID mouse down/up to target window
  - `CGAssociateMouseAndMouseCursorPosition(true)`
  - observe whether the visible/global cursor remains fixed while activation succeeds.
- Window-addressed HID:
  - keep event location at current cursor
  - set target pid/window event fields such as target Unix pid and window-under-pointer fields
  - post to `.cghidEventTap`
  - observe whether WindowServer routes activation to the target without cursor movement.
- HID activate then `postToPid` action:
  - use the best activation primer only for `active/key/main`
  - deliver the actual button click with `postToPid`
  - observe whether traffic lights remain active and the cursor stays put.

## Experiment Run: 2026-05-02

Harness:

- `tmp/activation-probe/activation_harness.swift`
- Each experiment terminates and relaunches ProbeA/ProbeB.
- ProbeA is restored as baseline frontmost app before each experiment.
- Cursor is placed at a neutral point inside ProbeA before each experiment and restored to the original cursor position after the full run.

Results:

| Experiment | Cursor moved | ProbeB active/key/main | ProbeB clicks | Window layer result |
| --- | --- | --- | --- | --- |
| `ax-focused-window-main` | no | no | 0 | unchanged, ProbeA front |
| `ax-raise-focused-window-main` | no | no | 0 | unchanged, ProbeA front |
| `post-to-pid-button-click` | no | no | 0 | unchanged, ProbeA front |
| `post-to-pid-button-click-target-fields` | no | no | 0 | unchanged, ProbeA front |
| `post-to-pid-move-button-click-target-fields` | no | no | 0 | unchanged, ProbeA front |
| `hid-window-fields-current-cursor` | no | no | 0 | unchanged, ProbeA front |
| `hid-detached-titlebar` | yes | yes | 0 | ProbeB raised to layer-0 front |
| `hid-titlebar-warp-back` | no final movement | yes | 0 | ProbeB raised to layer-0 front |
| `hid-titlebar-warp-back-restore-allows-previous` | no final movement | yes | 0 | ProbeB raised to layer-0 front |
| `hid-detached-button` | yes | yes | 1 | ProbeB raised to layer-0 front |
| `hid-detached-titlebar-then-post-to-pid-button` | yes | yes | 0 | ProbeB raised to layer-0 front |
| `hid-titlebar-warp-back-then-post-to-pid-move-button` | no final movement | yes | 0 | ProbeB raised to layer-0 front |

Important corrections from this run:

- `hid-window-fields-current-cursor` only appeared promising when the cursor was already over ProbeB. With a neutral cursor over ProbeA, setting target pid/window fields does not route activation to ProbeB.
- `CGAssociateMouseAndMouseCursorPosition(false)` does not prevent global cursor movement for these HID mouse events on this setup.
- Posting the HID click and immediately warping the cursor back preserves the final cursor position and still creates ProbeB `active/key/main`.
- Allowing previous-app focus events during restore did not put ProbeA back on top in the CG window stack. The final system frontmost app is ProbeA, but the ProbeB window is still raised to layer-0 front.
- The current `postToPid` harness variants did not trigger the Probe button. That needs separate action-layer debugging; it does not change the activation conclusion.

Current best activation candidate:

- `HID titlebar primer + focus suppression + immediate cursor warp-back`
- Pros:
  - Produces ProbeB `active/key/main`.
  - Final cursor location is unchanged.
  - Does not click the Probe button when using titlebar point.
- Cons:
  - ProbeB window is raised in the CG layer stack.
  - Cursor may still visibly jump for a very short interval before warp-back.

Status update:

- This HID path is not acceptable for KW's final implementation. Even if the final cursor coordinate can be warped back, the HID event still updates WindowServer's global cursor state and can visibly move the user's pointer. Treat HID only as a control experiment that proves which AppKit/CPS state transitions are needed.
- The final activation mechanism must avoid HID mouse events for activation and action delivery.

Remaining open problem:

- Find a non-HID way to produce the same target-side AppKit `active/key/main` state while preserving cursor position and CG window ordering.
- Likely search space: AppKit/CPS/CGS private activation APIs, Codex Computer Use reverse engineering, and target-process/AppKit event or state manipulation. `postToPid` remains the preferred action-delivery path once activation is solved.

## Experiment Run: Carbon Activation

Reverse-engineering Codex Computer Use 1.0.770 showed:

- Main executable: `SkyComputerUseService`
- Nested client: `SkyComputerUseClient.app`
- No direct SkyLight linkage in `otool -L`.
- It does dynamically load symbols via `dlopen` / `dlsym`.
- Relevant class/string evidence:
  - `SyntheticAppFocusEnforcer`
  - `SystemFocusStealPreventer`
  - `FocusStealSuppression`
  - `SystemFrontmostApplicationTracker`
  - `WindowOrderingObserver`
  - `EventTap`
  - `applicationBelievesItHasFocus`
  - `targetLostFocusHandler`
  - `targetGainedFocusHandler`
  - `kCPSNotifyTypingFocusChanged`
  - `kCPSNotifyLostTypingFocus`
  - `kCPSNotifyKeyFocusChanged`
  - `kCPSNotifyKeyFocusReturned`
  - `kCPSNotifyKeyFocusTaken`
  - `kCPSNotifyLostKeyFocus`
  - `kCPSNotifyNewFront`

Carbon `SetFrontProcessWithOptions` was tested under the same Probe reset harness.

Results:

- `SetFrontProcessWithOptions` can non-HID activate ProbeB.
- It produces ProbeB `active/key/main`.
- It does not move the cursor.
- It still raises ProbeB to the front of the CG window stack.
- Adding `kSetFrontProcessFrontWindowOnly`, `kSetFrontProcessCausedByUser`, or both does not prevent the raise.
- Restoring ProbeA with Carbon plus repeated `AXRaise` can make the final stack correct in repeated tests, while ProbeB remains `active/key/main`.

Important rejection:

- Carbon activation is not acceptable as a final implementation path if any visible transient app/window layer switch is unacceptable. Even when final state is correct, it still temporarily raises ProbeB.
- Treat Carbon only as a control path for discovering the exact AppKit/CPS activation events, not as the final KW mechanism.

Next viable direction:

- Capture the target-side focus events created by Carbon activation, then attempt to replay equivalent events into ProbeB with `postToPid` while ProbeB remains behind ProbeA.
- If replay works, derive a synthetic no-raise activation sequence.
- If replay fails, continue toward private CPS/CGS state manipulation or target-process AppKit state manipulation.

## Experiment Run: Synthetic Focus Event Replay

Harness:

- `tmp/activation-probe/focus_replay_harness.swift`

Method:

1. Reset ProbeA/ProbeB.
2. Use Carbon activation only once as a recorder/control path.
3. Capture ProbeB's target-side focus event with `CGEvent.tapCreateForPid`.
4. Restore/reset ProbeB to inactive behind ProbeA.
5. Replay the captured event to ProbeB with `postToPid`.
6. Then construct equivalent synthetic events and test them from a fresh Probe reset.

Captured event:

- One target-side event was enough.
- Captured shape:
  - raw `CGEventType == 20`
  - `NSEvent.type.rawValue == 13`
  - `NSEvent.subtype.rawValue == 1`
  - `data1` varied per run and was not important.
  - `data2` was `64` in captured runs but was not required.

Replay result:

- Replaying the captured event with `postToPid` made ProbeB become:
  - `isActive=true`
  - `isKey=true`
  - `isMain=true`
  - `keyWindowSelf=true`
  - `mainWindowSelf=true`
- ProbeA remained the system frontmost app.
- ProbeA remained layer-0 front in the CG window stack.
- ProbeB remained behind ProbeA.
- Cursor did not move.

Synthetic result:

- A directly constructed event works from a fresh reset:

```swift
let event = NSEvent.otherEvent(
    with: .appKitDefined,
    location: .zero,
    modifierFlags: [],
    timestamp: 0,
    windowNumber: 0,
    context: nil,
    subtype: Int16(1),
    data1: 0,
    data2: 0
)!.cgEvent!
event.postToPid(targetPID)
```

- This produces the same ProbeB `active/key/main` state with:
  - no HID event
  - no cursor movement
  - no window raise
  - no system frontmost change

Additional synthetic variants that also worked:

- raw `CGEventType == 20` with no fields set.
- raw `CGEventType == 20` with target pid only.
- raw `CGEventType == 20` with `data2 = 64`.
- raw `CGEventType == 13` appKit-defined subtype `1` with `data2 = 64`.
- `data1` values `0`, `1`, `999`, `65535`, and captured values all worked.

Superseded activation conclusion:

- A single AppKit-defined focus event looked like the best no-touch activation candidate in two-window tests:
  - `NSEvent.EventType.appKitDefined`
  - subtype `1`
  - posted to the target pid
- It satisfied these constraints only in the two-window Probe setup:
  - target app believes it is active/key/main
  - frontmost app is unchanged
  - window stack is unchanged
  - cursor is unchanged
  - no HID
  - no transient raise
- Later three-window testing showed this conclusion was wrong: subtype `1` promotes the target window to directly below the current frontmost window. It is not a final implementation candidate.

## Experiment Run: Action After Synthetic Focus

Harness:

- `tmp/activation-probe/postpid_after_focus_harness.swift`

Method:

1. Reset ProbeA/ProbeB.
2. Activate ProbeB in the background using the synthetic AppKit-defined focus event.
3. Try several mouse action transports with `postToPid`.

Results:

| Action transport | Cursor moved | Window stack changed | ProbeB active/key/main | Button clicked |
| --- | --- | --- | --- | --- |
| `CGEvent` mouse down/up at AX screen point + target fields + `postToPid` | no | no | yes | no |
| `NSEvent.mouseEvent` local window point + target window number + `postToPid` | no | no | yes | no |
| `NSEvent.mouseEvent` screen point + target window number + `postToPid` | no | no | yes | no |

Conclusion:

- Activation is now separate from action delivery.
- Synthetic activation does not automatically make the existing `postToPid` mouse variants trigger an `NSButton`.
- The action layer still needs separate work. AX semantic actions (`AXPress`) remain likely useful for element clicks, while coordinate clicks need more investigation.

## Completion Verifier

Verifier:

- `tmp/activation-probe/synthetic_activation_verifier.swift`

Purpose:

- Verify the final activation hack directly, without relying on HID or Carbon for the activation itself.
- Sample cursor, `NSWorkspace.frontmostApplication`, and the CG window stack every 2ms around the activation event to catch transient visible changes.

Verified method:

```swift
let event = NSEvent.otherEvent(
    with: .appKitDefined,
    location: .zero,
    modifierFlags: [],
    timestamp: 0,
    windowNumber: 0,
    context: nil,
    subtype: Int16(1),
    data1: 0,
    data2: 0
)!.cgEvent!

event.postToPid(targetPID)
```

Verifier output:

```text
before_state=isActive=false isKey=false isMain=false keySelf=false mainSelf=false front=ProbeA clicks=0
after_state=isActive=true isKey=true isMain=true keySelf=true mainSelf=true front=ProbeA clicks=0
before_stack=aIndex=0 bIndex=1 frontLayer0=ProbeA:28516:3782
after_stack=aIndex=0 bIndex=1 frontLayer0=ProbeA:28516:3782
before_frontmost=ProbeA:28516
after_frontmost=ProbeA:28516
cursor_before=(240,426) cursor_after=(240,426)
samples=143
frontmost_change_samples=0
cursor_change_samples=0
a_index_change_samples=0
b_index_change_samples=0
success_target_active=true
success_frontmost_unchanged=true
success_cursor_unchanged=true
success_stack_unchanged=true
```

Completion conclusion:

- This verifier was insufficient because it only used two Probe windows. If the target is moved from the bottom to directly below the frontmost window, a two-window stack still appears unchanged.
- The AppKit-defined focus event does not move the cursor.
- It does not change the system frontmost app.
- It makes the target app/window believe it is active/key/main.
- It does change CG window ordering when there are at least three normal windows.
- It does not solve the separate action-delivery problem.

## Correction: Three-Window Ordering Test

Harness:

- `tmp/activation-probe/three_window_order_verifier.swift`

Setup:

- ProbeA is frontmost and layer-0 index `0`.
- ProbeB is layer-0 index `1`.
- ProbeC is layer-0 index `2`.
- Synthetic activation is posted to ProbeC:

```swift
NSEvent.otherEvent(
    with: .appKitDefined,
    location: .zero,
    modifierFlags: [],
    timestamp: 0,
    windowNumber: 0,
    context: nil,
    subtype: Int16(1),
    data1: 0,
    data2: 0
)!.cgEvent!.postToPid(probeCPID)
```

Observed result:

```text
before_stack=A=0 B=1 C=2 front=ProbeA:3937
after_stack=A=0 B=2 C=1 front=ProbeA:3937
frontmost=ProbeA
cursor_before=(872,411) cursor_after=(872,411) moved=false
ProbeC_state=isActive=true isKey=true isMain=true keyWindowSelf=true mainWindowSelf=true front=ProbeA clicks=0
```

Correction:

- The AppKit-defined focus event is not a final no-touch activation hack.
- It preserves cursor and `frontmostApplication`, but it moves the target window to the slot directly below the current frontmost window.
- The remaining unsolved requirement is: activate target AppKit state without changing the full CG window ordering, even in a stack of three or more windows.

## Experiment Run: AppKit-Defined Subtype Sweep

Harness:

- `tmp/activation-probe/subtype_sweep_verifier.swift`

Setup:

- Each subtype starts from a fresh three-window reset.
- ProbeA is frontmost and layer-0 index `0`.
- ProbeB is layer-0 index `1`.
- ProbeC is layer-0 index `2`.
- The test posts one `NSEvent.EventType.appKitDefined` event to ProbeC with the candidate subtype.

Results:

| Subtype | ProbeC active/key/main | Full order unchanged |
| --- | --- | --- |
| `0` | no | yes |
| `1` | yes | no; `A=0 B=1 C=2` became `A=0 B=2 C=1` |
| `2` | no | yes |
| `4` | no | yes |
| `9` | no | yes |
| `21` | no | yes |
| `22` | no | yes |
| `23` | no | yes |
| `24` | no | yes |
| `25` | no | yes |
| `26` | no | yes |
| `27` | no | yes |
| `28` | no | yes |
| `29` | no | yes |
| `30` | no | yes |

Conclusion:

- Among the tested AppKit-defined subtypes, only subtype `1` activates ProbeC.
- The only activating subtype is also the subtype that changes window ordering.
- The synthetic event route cannot yet satisfy the hard requirement by varying subtype alone.

## Experiment Run: Codex Coordinate Click Path

Observation:

- Newer Codex Computer Use only triggers the background AppKit focus effect on the coordinate-click path.
- `get_app_state` and element/AX-style entry points are not reliable probes for this behavior.

Three-window setup:

- ProbeA frontmost.
- ProbeC middle.
- ProbeB bottom.
- Initial relative order: `A>C>B`.

Codex coordinate click result:

```text
ProbeB isActive=true isKey=true isMain=true keyWindowSelf=true mainWindowSelf=true front=ProbeA clicks=1
start_stack=A>C>B start_frontmost=ProbeA start_cursor=(819,672)
end_stack=A>C>B end_frontmost=ProbeA end_cursor=(819,672)
samples=837 changes=0
```

Conclusion:

- Codex coordinate click satisfies the hard background-focus constraints in the Probe test:
  - target app/window becomes AppKit active/key/main
  - system frontmost app remains ProbeA
  - full relative order of ProbeA/ProbeC/ProbeB remains unchanged
  - cursor position remains unchanged
  - no transient order/frontmost/cursor changes were seen in a 2ms sampler

Per-pid event tap capture during Codex coordinate click:

```text
raw=5  mouseMoved target pid/window fields
raw=13 appKitDefined subtype=1 windowNumber=<target-window>
raw=1  leftMouseDown windowNumber=<target-window>
raw=2  leftMouseUp   windowNumber=<target-window>
raw=13 appKitDefined subtype=22 windowNumber=<target-window>
raw=13 appKitDefined subtype=23 windowNumber=<target-window>
raw=1  leftMouseDown windowNumber=<target-window>
raw=2  leftMouseUp   windowNumber=<target-window>
```

Important distinction:

- The earlier failing synthetic event used `windowNumber = 0`.
- Codex's focus event uses `appKitDefined subtype=1` with the target `windowNumber` and target pid/window fields.

Minimal activation replay:

- `appKitDefined subtype=1` with `windowNumber = targetWindowID`:
  - keeps `A>C>B` unchanged
  - sets `NSApp.isActive=true`
  - does not set key/main
- Then posting an `NSEvent.mouseEvent` down/up with the same target `windowNumber`:
  - keeps `A>C>B` unchanged
  - sets target `isActive/key/main=true`
  - does not move the cursor
  - did not trigger the Probe button action in our replay

Current interpretation:

- The activation hack is likely window-addressed, not app-only:
  1. Post a target-window AppKit-defined focus event (`subtype=1`, `windowNumber=targetWindowID`) to the target pid.
  2. Post a target-window mouse down/up pair to make that window key/main.
  3. Perform the actual semantic action separately, likely via AX hit-testing / `AXPress` when the coordinate resolves to an AX actionable element.
- This explains why Codex coordinate click can both light the target traffic lights and click Probe Button, while replaying only the CG/NSEvent mouse events reproduces activation but not the button action.

Remaining action-layer question:

- For coordinate clicks that do not correspond to an AX actionable element, we still need a working non-HID action delivery path.
- For normal buttons/controls, `window-addressed activation + AXPress` is the strongest current candidate.

## Experiment Run: Coordinate Action Delivery

Probe was rebuilt with extra logging in:

- `NSWindow.sendEvent`
- root view `mouseDown` / `mouseUp`
- button `mouseDown` / `mouseUp`
- button action handler

Codex coordinate click event path in ProbeB:

```text
window.sendEvent type=5 subtype=3 win=<target> loc=(108,53)
applicationDidBecomeActive front=ProbeA
window.sendEvent type=1 subtype=3 win=<target> loc=(30,256)
windowDidBecomeMain
windowDidBecomeKey
window.sendEvent type=2 subtype=3 win=<target> loc=(30,256)
window.sendEvent type=1 subtype=3 win=<target> loc=(108,53)
button.mouseDown type=1 subtype=3 win=<target> loc=(108,53)
buttonPressed count=...
```

The titlebar down/up is not required for the final click delivery. It is one way to make the target window key/main. The actual button click is delivered by the second mouse down/up at the button coordinate.

Failed replay:

- `CGEvent(mouseEventSource: ..., mouseCursorPosition: screenPoint)` with `postToPid`
- public target pid / window-under-pointer fields
- no private field `58`

Result:

- Event either did not reach the per-pid tap, or AppKit decoded the event location as `(0, windowHeight)`.
- The button was not hit.

Successful replay:

- Post mouse down/up to the target pid.
- Set `CGEventField(rawValue: 51)` to the target CG window ID.
- Set `CGEventField(rawValue: 58)` to any non-zero value.
- `field58=1` works.
- `field58=20137`, `21061`, `21062`, `21063`, `22000`, and `65535` also worked.
- `field58=0` failed.

Minimal field matrix:

| Mouse event fields | Button clicked |
| --- | --- |
| `field51 + field58` | yes |
| `field51 + field58 + under-pointer fields` | yes |
| `field51 + field58 + subtype` | yes |
| no `field51` | no |
| no `field58` | no |
| no `field53` | yes |
| no under-pointer fields | yes |
| no mouse subtype | yes |
| no event number | yes |
| no target pid field, but still `postToPid(targetPID)` | yes |
| no click state | yes |
| no pressure | yes |

Minimal coordinate click sequence:

```swift
let event = CGEvent(
    mouseEventSource: nil,
    mouseType: .leftMouseDown, // then .leftMouseUp
    mouseCursorPosition: screenPoint,
    mouseButton: .left
)!
event.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(targetWindowID))
event.setIntegerValueField(CGEventField(rawValue: 58)!, value: 1)
event.postToPid(targetPID)
```

Results:

- Direct button down/up with `field51 + field58` triggers `NSButton` in the background.
- Direct button down/up does not require target AppKit active/key/main.
- Direct button down/up does not move the cursor.
- Direct button down/up does not change the CG window order.
- If we first send the window-addressed AppKit focus event, then the same direct button click also leaves the target app/window in `active/key/main` state.

Implementation conclusion:

- The action delivery solution is not AXPress-only.
- Coordinate click can be delivered as real AppKit mouse events through `postToPid` when the event includes:
  - target window field `51`
  - private routing flag field `58 = 1`
- KW should avoid `.cghidEventTap` for mouse actions.
- KW should send a window-addressed focus event first when the action should also produce Codex-style background AppKit active/key/main.

## Experiment Run: Full Action Delivery Coverage

Harnesses:

- `tmp/activation-probe/action_field_matrix.swift`
- `tmp/activation-probe/keyboard_delivery_verifier.swift`
- `tmp/activation-probe/scroll_drag_delivery_verifier.swift`
- `tmp/activation-probe/ax_scroll_delivery_verifier.swift`

All verifier runs reset the Probe windows before the tested sequence or reset the ordering before each matrix row. The three-window baseline is:

- ProbeA frontmost
- ProbeC middle
- ProbeB bottom
- Relative order `A>C>B`

Window-addressed activation sequence now used by KW:

1. Post `NSEvent.EventType.appKitDefined`, subtype `1`, with `windowNumber = targetWindowID` to the target pid.
2. Set raw CG fields:
   - `CGEventField(rawValue: 51) = targetWindowID`
   - `CGEventField(rawValue: 58) = 1`
3. Post a titlebar mouse down/up pair to the target pid with the same `field51 + field58`.

This differs from the rejected earlier synthetic activation because the old event used `windowNumber = 0`. In a three-window stack that old variant promoted the target from bottom to directly under the current frontmost window. The window-addressed sequence keeps `A>C>B` unchanged in the Probe tests.

Click replay:

```text
variant=field51-field58-only clicked=true unchanged=true state=isActive=true isKey=true isMain=true keyWindowSelf=true mainWindowSelf=true front=ProbeA clicks=7
variant=no-field51 clicked=false unchanged=true state=isActive=true isKey=false isMain=false keyWindowSelf=false mainWindowSelf=false front=ProbeA clicks=6
variant=no-field58 clicked=false unchanged=true state=isActive=true isKey=true isMain=true keyWindowSelf=true mainWindowSelf=true front=ProbeA clicks=6
```

Click conclusions:

- `field51 + field58` is the minimum mouse routing pair for AppKit hit delivery.
- `field58` is not required for the target to remain active/key/main after the titlebar primer, but it is required for the subsequent coordinate click to hit the button.
- Public fields such as event number, subtype, `field53`, pressure, click state, and under-pointer fields are not required for the minimal Probe click.
- KW still sets public target pid / under-pointer fields in the dispatcher because they are harmless in the matrix and help preserve the intended routing shape.

Keyboard replay:

```text
value=kw
before_stack=A>C>B after_stack=A>C>B unchanged=true
before_front=ProbeA:<pid> after_front=ProbeA:<pid> unchanged=true
cursor_moved=false
state=isActive=true isKey=true isMain=true keyWindowSelf=true mainWindowSelf=true front=ProbeA clicks=0
```

Keyboard conclusions:

- Unicode keyboard `CGEvent`s posted to the target pid, with `field51 + field58`, write into the background focused text field.
- The target stays AppKit active/key/main.
- The system frontmost app, full CG window order, and cursor position stay unchanged.
- Detail: a Probe follow-up showed `delete` virtual-key delivery works, but `command+a` did not select all text in the Probe text field. Therefore `set-value` should not depend on `command+a` / `delete` to replace content; it should set `AXValue` directly after background activation.

Drag and CG scroll replay:

```text
scroll_seen=false drag_seen=true
before_stack=A>C>B after_stack=A>C>B unchanged=true
before_front=ProbeA:<pid> after_front=ProbeA:<pid> unchanged=true
cursor_moved=false
state=isActive=true isKey=true isMain=true keyWindowSelf=true mainWindowSelf=true front=ProbeA clicks=0
```

Drag conclusions:

- Mouse moved/down/dragged/up events posted to pid with `field51 + field58` reach the background Probe window.
- Drag delivery does not move the real cursor and does not alter frontmost app or window ordering.

Scroll conclusions:

- `CGEvent(scrollWheelEvent2Source:)` posted to pid did not reach Probe's `NSWindow.sendEvent` or root `scrollWheel`, even with:
  - `field51 + field58`
  - public target pid and under-pointer fields
  - `.hidSystemState` event source
  - line and pixel units
  - scroll phase fields
- Product scroll should therefore prefer an AX scrollbar path and keep CG scroll as a best-effort fallback only.

AX scrollbar fallback:

- Probe was rebuilt with a real `NSScrollView`.
- The verifier performs the same product fallback shape:
  1. Find vertical/horizontal `AXScrollBar` from the target element and window root.
  2. Try `AXIncrement` / `AXDecrement`.
  3. If the action is unavailable, set `AXValue` directly within min/max.

Verifier output:

```text
performed=true before_value=0.0 after_value=0.18 scrolled=true
before_stack=A>C>B after_stack=A>C>B unchanged=true
before_front=ProbeA:<pid> after_front=ProbeA:<pid> unchanged=true
cursor_moved=false
state=isActive=true isKey=true isMain=true keyWindowSelf=true mainWindowSelf=true front=ProbeA clicks=0
```

Implementation conclusion:

- Mutating KW actions should all begin with the same background window activation sequence.
- Click/type/press-key/drag use `CGEvent.postToPid(targetPID)` with `field51 + field58`.
- Set-value uses direct `AXValue` assignment after background activation; this avoids relying on app-specific `command+a` handling.
- Scroll uses AX scrollbar actions first because pid-posted scroll-wheel CGEvents do not reliably enter AppKit.
- No action should use SkyLight or `.cghidEventTap`; HID remains rejected because it can move the user's visible cursor and/or affect visible ordering.

## Implementation Audit: One Path For AX And Coordinate Actions

Code shape:

- All mutating actions now go through a single `performWithBackgroundActivation(on:)` wrapper in `ComputerUseActions`.
- The wrapper is responsible for:
  1. `BackgroundActivationSession.start(targetPID:)`
  2. `activateWindow(windowNumber:windowFrame:)`
  3. running the action body
  4. `restorePreviousAndHold()`
  5. `finish()`
- The `restorePreviousAndHold()` and `finish()` calls are in `defer`, so successful actions and thrown actions use the same focus-suppression cleanup.

Covered actions:

- `click` with `element_index`
- `click` with `x/y`
- `type-text`
- `set-value`
- `press-key`
- `scroll`
- `perform-secondary-action`
- `drag`

This means AX semantic paths and coordinate paths share the same background-focus envelope. The only differences left are the action delivery primitive:

- Coordinate click / element click / drag: pid-posted mouse events with `field51 + field58`.
- Type / key: pid-posted keyboard events with `field51 + field58`.
- Set value: direct AXValue assignment inside the same envelope.
- Secondary AX action: `AXUIElementPerformAction` inside the same envelope.
- Scroll: AX scrollbar inside the same envelope, with pid-posted CG scroll only as a fallback.

AX semantic verifier:

- `tmp/activation-probe/ax_action_delivery_verifier.swift`
- This verifier resets ProbeA/B/C, applies the same background activation sequence, then:
  - sets ProbeB input via `AXValue`
  - presses ProbeB button via `AXPress`

Verifier output:

```text
ax_set_success=true value=ax
ax_press_success=true clicked=true
before_stack=A>C>B after_stack=A>C>B unchanged=true
before_front=ProbeA:<pid> after_front=ProbeA:<pid> unchanged=true
cursor_moved=false
state=isActive=true isKey=true isMain=true keyWindowSelf=true mainWindowSelf=true front=ProbeA clicks=1
```

Final dependency audit:

- No production action path uses SkyLight.
- No production action path uses `.cghidEventTap` or `CGEvent.post(tap:)`.
- No production action path uses SLS/CGS window ordering APIs.
- Remaining dynamic symbol lookups are AX/HIServices helpers only:
  - `_AXUIElementGetWindow`
  - `_AXObserverAddNotificationAndCheckRemote`

## Final Design: Direct In-Process Actions Without Helper Daemon

Decision:

- Remove the helper daemon from KW computer use.
- Execute all `ComputerUseAgent.executeAction` calls in the current KW process.
- Do not install, launch, connect to, or shut down a helper app for computer use.

Removed product surface:

- `Sources/kwwk-cu/HelperDaemon.swift`
- `--install-helper` / `--reinstall-helper`
- `--no-helper` / `--disable-helper`
- `KWWK_CU_DISABLE_HELPER`
- helper app install/sign/copy logic
- helper daemon socket protocol
- helper owner watchdog

Direct product-action verifier:

- `Tests/KWWKComputerUseTests/InProcessComputerUseBehaviorTests.swift`
- Gated behind:
  - `KWWK_CU_RUN_GUI_PROBE_TESTS=1`
- The verifier launches ProbeB, ProbeC, ProbeA to establish `A>C>B`, then calls the real product action executor in-process:
  - `get-app-state`
  - `click` with `element_index`
  - `click` with `x/y`
  - `type-text`
  - `set-value`
  - `perform-secondary-action` / `AXPress`

Verified command:

```bash
KWWK_CU_RUN_GUI_PROBE_TESTS=1 swift test --filter InProcessComputerUseBehaviorTests/directProductActionsPreserveBackgroundFocusInvariants
```

Result:

```text
Test "direct product actions preserve background focus invariants" passed after 12.829 seconds.
```

Assertions covered after each direct in-process action:

- relative CG window order remains `A>C>B`
- frontmost app remains ProbeA
- cursor does not move
- target ProbeB state contains:
  - `isActive=true`
  - `isKey=true`
  - `isMain=true`
  - `front=ProbeA`
- expected side effect occurs:
  - button click count increments for element click, coordinate click, and AXPress
  - text field value changes for type-text and set-value

Conclusion:

- The background activation/action effect does not depend on a helper daemon.
- The effect lives in `KWWKComputerUse`'s action layer and works when called directly in-process.
- The only remaining permission identity is the current executable/test host/KW process.

## Task-Level Computer Use Session

Decision:

- Treat one full computer use task as one `ComputerUseSession`.
- The CLI creates one session before constructing the `computer_use` tool and calls `finish()` when `agent.prompt(...)` returns or throws.
- Mutating actions reuse the same session instead of creating a fresh activation lease per action.

Session behavior:

- At most one background-active target window is retained by a session.
- Repeated actions against the same pid/window reuse the existing background activation.
- When an action targets a different pid/window:
  1. send an AppKit `applicationDeactivated` event to the previous background target, unless that target app is now the real frontmost app
  2. finish the previous focus-suppression taps
  3. create a new target activation lease for the new pid/window
- During each action, target focus events are allowed and previous-frontmost focus-loss events are suppressed.
- Between actions, focus suppression is held so neither the frontmost app nor the background target consumes late focus events.
- On session finish, the current background target is restored with the same "skip if target is real frontmost" rule.

Prompt policy:

- The agent prompt now prefers `get-app-state` with `include_screenshot=false`.
- Screenshots should be requested only when accessibility is missing/incomplete, for canvas/WebGL/game-like surfaces, or for genuinely visual/pixel work.

Verified commands:

```bash
swift build --product kwwk-cu
swift test --filter KWWKComputerUse
KWWK_CU_RUN_GUI_PROBE_TESTS=1 swift test --filter InProcessComputerUseBehaviorTests
```

## Generic Computer Use Traversal Harness

Computer Use plugin comparison:

- Current Codex Computer Use exposes a service/client split with `get_app_state`, element-index actions, and a refetchable AX tree. Binary strings show `RefetchableSkyshotAXTree`, invalid-element refetch errors, and cumulative AX tree diffs from the initial snapshot.
- The important behavioral difference is not a special Slack API. The plugin keeps a task/session-level tree model and can recover when element IDs become stale.
- KW's generic path returned a fresh snapshot after every action, but the agent still had to manually maintain a visited set and list boundary. In long lists, that made it repeat visible rows and occasionally target stale/clipped rows.
- Electron apps often expose useful row summaries through `AXDescription`; those descriptions should be treated as first-class stable labels, not as app-specific special cases.

Implementation decision:

- Do not add a Slack-specific action.
- Make `ComputerUseSession` the task harness: it tracks observations per pid/window, the initial tree labels, the previous tree labels, and recent actions.
- Every tool result with snapshot metadata is annotated with:
  - candidate targets derived generically from AX role/title/description/identifier
  - recent actions with stable labels when available
  - label deltas since the previous observation
  - label deltas since the initial observation
- If an action hits stale element state, the tool returns a fresh app state with a plugin-like invalid-element message instead of leaving the agent with only a thrown error.
- The agent prompt tells the model to keep a visited set from stable labels/descriptions and scroll only after visiting relevant visible rows.
- The harness explicitly says visible rows are not "visited" for click/traversal tasks until a successful action result or selected/opened state confirms them.
- Default snapshots avoid aggressive visible-frame pruning so Electron/Blink row descriptions remain available to the generic harness.

Expected Slack behavior:

- A natural-language `kwwk-cu` request such as "请点击遍历 Slack 联系人列表收集最新信息" should use ordinary `get-app-state`, `click`, and `scroll` actions.
- Slack rows should appear as generic candidate targets when they have stable AX descriptions.
- After each click/scroll, the harness deltas should help the model avoid repeating already visited visible rows.
- Debug focus logs should still stay on the user's foreground app while Slack receives background actions.

Action-delivery correction:

- Slack/Electron can expose correct row descriptions while returning collapsed row frames, for example multiple recent-conversation rows all reported `y=310 height=1`.
- Pure coordinate delivery cannot distinguish those rows, even when the AX element index and description are correct.
- Generic `click(element_index:)` now first tries the target element's own `AXPress` action inside the same `ComputerUseSession` focus-suppression window.
- If `AXPress` is unavailable or fails, `click` falls back to `postToPid` coordinate delivery. The coordinate fallback prefers descendant frames for structural groups/rows/cells before using the element's own frame.
- This is not Slack-specific: it is a generic action-delivery rule for any AX element that supports `AXPress`.

Verified commands:

```bash
swift test
swift run kwwk-cu --debug-focus --max-turns 24 "只读测试，不发送消息。请点击遍历 Slack 联系人列表，最多处理 3 个联系人；最终只输出联系人名，不要输出任何消息内容或摘要；不需要截图。"
swift run kwwk-cu --debug-focus --max-turns 16 "只读测试，不发送消息。请点击遍历 Slack 联系人列表，最多处理 2 个联系人；最终只输出联系人名，不要输出任何消息内容或摘要；不需要截图。"
```

The validation used ordinary `get-app-state` and `click` actions. Debug logs showed `ax press` delivery with `frontmost=Ghostty` and `target=Slack active=false`.

Additional Probe coverage:

- shared-session actions preserve the existing background target
- switching from ProbeB to ProbeC restores ProbeB to inactive
- `ComputerUseSession.finish()` restores the final background target to inactive
- window stack remains `A>C>B`
- real frontmost app remains ProbeA
- cursor remains stable

## Snapshot Output: Visible Filtering Experiment

Decision:

- A strict visible-only AX tree was tested but should not be the default harness path.
- Electron/Blink already virtualizes much of its AX tree; extra frame-based pruning can remove useful row descriptions that Codex/CUA keeps.
- The returned index space remains snapshot-local. Agents must not treat indexes as stable after scrolls, navigation, or layout changes.
- Focused and selected elements should be retained even if their frame is unusual, because they are important for text input and current selection context.

Implementation details:

- `ComputerUseCore.flattenTree(...)` can filter by intersection with the target window frame when `filterVisibleNodes=true`.
- The default capture path keeps plugin-like AX traversal and does not enable this filter.
- Hidden elements (`AXHidden == true`) are skipped unless they are focused or selected.
- Scroll-like containers create descendant clipping boundaries:
  - `AXScrollArea`
  - `AXList`
  - `AXOutline`
  - `AXTable`
  - `AXColumn`
  - `AXTabGroup`
  - `AXWebArea`
- Non-clipping structural roles such as `AXGroup` may still be traversed even when their own frame is missing or unreliable.

Verified commands:

```bash
swift build --product kwwk-cu
swift test --filter KWWKComputerUse
KWWK_CU_RUN_GUI_PROBE_TESTS=1 swift test --filter InProcessComputerUseBehaviorTests
```

Open follow-up:

- Visible-only output can reduce token load and avoid stale hidden list rows in native apps, but it does not solve stale snapshots by itself and can harm Electron parity.
- Action execution should continue to refresh the target window before every action and resolve the requested element through semantic signatures.
- If signature remapping fails, the tool should return a fresh snapshot instead of asking the agent to continue with the stale index.
- For apps like Slack, generic post-action settling should be paired with consistency checks where possible: selected sidebar row, main header/title, focused composer target, and stable window fingerprint should agree before the action result is returned.

## Snapshot Output: CUA/Codex Parity Correction

Finding:

- Codex Computer Use / CUA returns Slack's `Recent conversations` list and visible DM rows through AX without needing a screenshot.
- KW originally failed because its formatter ignored `AXDescription`, and the frame-based visible filter pruned Electron/WebArea subtrees too aggressively.
- A CUA source audit showed its `AppState.swift` primarily walks `AXChildren`; it does not union every relationship attribute and does not rely on frame-based visibility pruning for Electron. Electron/Blink virtualizes the AX tree itself, so the `AXChildren` tree is already close to the visible renderer state.
- The CUA article confirms the separate Electron issue: backgrounded Electron apps need remote-aware AX observer registration to keep their AX trees live. KW already keeps an observer and asserts `AXManualAccessibility`/`AXEnhancedUserInterface`; this remains necessary.

Correction:

- Capture and render `AXDescription` alongside title/value/help/identifier.
- Include `AXDescription` in cached element signatures so description-only rows remap across fresh snapshots.
- Revert traversal to the plugin-like primary `AXChildren` walk instead of relationship-union traversal; the union path caused duplicate Slack subtrees.
- Remove frame-based include/prune from `flattenTree`; keep hidden-node filtering and closed-menu pruning.
- Keep the frame visibility helpers for coordinate tests and future native-app filtering, but do not use them to prune Electron snapshot subtrees.

Slack verification:

- `get-app-state app=Slack include_screenshot=false` now returns:
  - `AXList Description: Recent conversations`
  - visible DM rows including `Yanyu`, `砍砍`, `Jc`, `Jimmfly`, `Peng Xiao`, `左子健`, `Feng Feng`, `hwang`, `Yiang Zhou`, `CatsJuice`, `darksky`, `Haowen Sun`, and `Yue Wu`
- The same snapshot also returns visible conversation message rows for the selected DM.

Verified commands:

```bash
swift build --product kwwk-cu
swift test --filter KWWKComputerUse
KWWK_CU_RUN_GUI_PROBE_TESTS=1 swift test --filter InProcessComputerUseBehaviorTests
```
