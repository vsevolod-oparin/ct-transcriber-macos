# Research: Finite State Machine Programming for UI

**Date:** 2026-03-19
**Scope:** Literature survey of FSM/statechart-based UI development + analysis of CTTranscriber codebase for improvement opportunities

---

## Part I: The School of Thought

### Origins and Intellectual Lineage

There is a distinct movement in software engineering advocating that UI behavior should be modeled as **finite state machines (FSMs)** or their more powerful extension, **statecharts**. This is not a single framework but a cross-language, cross-platform philosophy rooted in the idea that UI is fundamentally a reactive, event-driven system — and state machines are the mathematically precise way to model such systems.

**Key timeline:**

| Year | Person | Contribution |
|------|--------|-------------|
| 1987 | **David Harel** | Invented statecharts as "a visual formalism for complex systems," extending flat FSMs with hierarchy, concurrency, and communication. Paper: *Statecharts: A Visual Formalism for Complex Systems*, Science of Computer Programming 8(3) |
| 1999 | **Ian Horrocks** | Wrote *Constructing the User Interface with Statecharts* — the first full treatment of applying statecharts specifically to UI construction. Defined the UCM (User-Centered Model) architecture |
| 2015 | **W3C** | Published SCXML (State Chart XML) as a W3C Recommendation — formal standardization of statechart semantics after 10 years of work |
| 2016 | **Richard Feldman** | Popularized "Make Impossible States Impossible" at elm-conf — showed how algebraic data types (sum types) enforce valid state at compile time |
| 2016 | **Andy Matuschak** | Published a composable pattern for pure state machines with effects in Swift, bridging functional-core/imperative-shell with Harel statecharts |
| 2017+ | **David Khourshid** | Created XState and founded Stately.ai — the most visible advocate for statechart-driven UI in the JS/TS ecosystem |
| 2019+ | **Point-Free** (Brandon Williams & Stephen Celis) | Created The Composable Architecture (TCA) for Swift — reducer-based state machines for SwiftUI |

The dedicated community hub is [statecharts.dev](https://statecharts.dev/).

### The Fundamental Problem FSMs Solve

Traditional UI state management uses scattered boolean flags (`isLoading`, `hasError`, `isAuthenticated`) that create a **combinatorial explosion of possible states**. With N booleans, you have 2^N combinations, most of which are invalid.

Example: with `isLoading`, `hasData`, `hasError` → 8 possible combinations, but only 4 are valid (idle, loading, success, error). The other 4 are "impossible states" that code must somehow handle or ignore.

As statecharts.dev puts it: *"Pretty soon you will find a messy if-statement, or a switch statement, that modifies the state of various variables in order to try to keep them consistent. It's as if you don't need statecharts until it's too late."*

### Six Core Arguments for FSMs in UI

1. **Eliminates impossible states** — By modeling states as mutually exclusive, contradictory flag combinations cannot exist
2. **Makes behavior explicit and visual** — A statechart diagram IS the specification; no gap between design and implementation
3. **Prevents race conditions** — Transitions are atomic; events in invalid states are ignored
4. **Enables exhaustive testing** — Every state and transition can be enumerated and tested mechanically
5. **Reduces accidental complexity** — Adding a feature = adding states and transitions, not boolean checks scattered through existing code
6. **Self-documenting** — The state machine IS the documentation of component behavior

### Common UI Bugs FSMs Prevent

| Bug | Traditional Cause | FSM Prevention |
|-----|------------------|----------------|
| Loading spinner + error shown simultaneously | `isLoading` and `hasError` both true | States are mutually exclusive |
| Double form submission | User clicks submit twice | In `submitting` state, `submit` event has no transition |
| Stale data from cancelled request | Async response arrives after navigation | Machine moved to different state; late event ignored |
| Flash of wrong content | Flags updated in wrong order | Transition is atomic — never half-A/half-B |
| Edit form accessible during save | View not disabled during async save | In `saving` state, `edit` events not handled |
| UI stuck in loading state | Error response not handled | Explicit `error` transition from `loading`; missing transitions are design-time decisions |
| Race between concurrent operations | Two async ops modify overlapping state | Machine serializes events; each transition is atomic |

---

## Part II: Swift/iOS Ecosystem

### Available Libraries and Patterns

| Library / Pattern | Description |
|---|---|
| **The Composable Architecture (TCA)** | Dominant state-machine architecture for SwiftUI. Reducer-based: `(State, Action) -> (State, Effect)`. Composition via feature scoping. [github.com/pointfreeco/swift-composable-architecture](https://github.com/pointfreeco/swift-composable-architecture) |
| **Swift enum state machines** | Lightweight approach using `switch (self, event)` pattern matching. Compiler enforces exhaustiveness |
| **GKStateMachine** (Apple GameplayKit) | Apple's built-in FSM. Each state is a `GKState` subclass with `isValidNextState(_:)`, `didEnter(from:)`, `willExit(to:)` |
| **Andy Matuschak's pattern** | Pure state machines with effects — value type with `handle(event:) -> Command?` method. Separates transitions from side effects. [GitHub Gist](https://gist.github.com/andymatuschak/d5f0a8730ad601bcccae97e8398e25b2) |
| **SwiftState** (ReactKit) | Elegant state machine DSL for Swift |
| **Tinder/StateMachine** | Cross-platform DSL (Kotlin & Swift) |

### How FSMs Map to SwiftUI

The key mindset shift: instead of "what should happen when the user taps this button?", ask "what state is the UI in, and is this event valid in that state?"

**Step 1 — Model states as enum:**
```swift
enum ChatState {
    case idle
    case recording(startTime: Date)
    case transcribing(progress: Double)
    case result(text: String)
    case error(Error, canRetry: Bool)
}
```

**Step 2 — Define events:**
```swift
enum ChatEvent {
    case startRecording
    case stopRecording(Data)
    case transcriptionProgress(Double)
    case transcriptionComplete(String)
    case transcriptionFailed(Error)
    case retry
    case reset
}
```

**Step 3 — Transition function with optional effect:**
```swift
mutating func handle(_ event: ChatEvent) -> Effect? {
    switch (self, event) {
    case (.idle, .startRecording):
        self = .recording(startTime: .now)
        return .beginAudioCapture
    case (.recording, .stopRecording(let data)):
        self = .transcribing(progress: 0)
        return .startTranscription(data)
    // ...
    default:
        return nil  // Event ignored in this state
    }
}
```

**Step 4 — UI switches on state:**
```swift
var body: some View {
    switch viewModel.state {
    case .idle: IdleView()
    case .recording(let start): RecordingView(startTime: start)
    case .transcribing(let p): TranscribingView(progress: p)
    case .result(let text): ResultView(text: text)
    case .error(let err, let canRetry): ErrorView(error: err, canRetry: canRetry)
    }
}
```

### Comparison: MVVM vs FSM vs Redux vs TCA

| Dimension | MVVM (current) | FSM/Statechart | Redux | TCA |
|---|---|---|---|---|
| State representation | Published properties | Enum (mutually exclusive) | Single store | Struct + Reducer |
| Invalid states | Possible | Structurally impossible | Possible | Unlikely (disciplined) |
| Transitions | Method calls (implicit) | Explicit, enumerated | Actions + reducers | Actions + reducers |
| Async handling | Manual (Task, flags) | Built-in states | Middleware | Effects system |
| Testability | Test methods | Enumerate all state-event pairs | Test reducers | Test reducers + effects |
| Visualization | None | Statechart diagrams | DevTools | None (debuggable) |

**Key insight:** FSMs and MVVM are complementary. You can use a state machine INSIDE a ViewModel. The state machine provides the missing structure for *what states exist* and *what transitions are valid*.

---

## Part III: CTTranscriber Codebase Analysis

### Current State Management Patterns

The codebase uses `@Observable` classes (modern SwiftUI), `@State` properties, SwiftData models, and some explicit enums. The architecture reveals a **mixed pattern**: some areas already use enum-based state machines well (ModelManager, TaskManager), while the core ChatViewModel relies on boolean flags and implicit state.

### Already Good: Enum-Based State Machines

These areas already follow FSM principles:

**1. `BackgroundTask.TaskStatus`** — Clean FSM with explicit states:
```
pending → running → completed | failed | cancelled
```

**2. `ModelManager.ModelStatus`** — Well-defined download lifecycle:
```
notDownloaded → downloading(step) → ready(path, sizeMB) | error(String)
```

**3. `PythonEnvironment.Status`** — Simple linear FSM:
```
notChecked → missing(reason) | ready(pythonPath)
```

These serve as **internal examples of what works well** in the codebase.

### Problem Area 1: ChatViewModel Boolean Flag Proliferation

**File:** `ChatViewModel.swift` (~795 lines)

The core ViewModel manages state through independent properties:

```swift
// Streaming state
var streamingConversationIDs: Set<UUID>         // Set membership = boolean
var isStreaming: Bool { !streamingConversationIDs.isEmpty }  // Computed
var isStreamingCurrentConversation: Bool { ... }             // Computed

// Transcription state
var activeTranscriptionCount: Int               // Counter as implicit boolean
var isTranscribing: Bool { activeTranscriptionCount > 0 }   // Computed
var transcriptionProgress: Double               // 0.0–1.0
var pendingTranscriptions: [(...)]              // Queue

// Title generation
var isGeneratingTitle: Bool = false             // Standalone flag

// Error state
var lastError: String?                          // nil/non-nil as implicit boolean

// Task tracking
var streamingTasks: [UUID: Task<Void, Never>]
var transcriptionTasks: [UUID: Task<Void, Never>]
```

**Impossible state risks:**
- `isGeneratingTitle = true` with no async work actually running (if Task is cancelled but flag not cleared)
- `lastError` non-nil while `isStreaming` — which takes priority in the UI?
- `activeTranscriptionCount` out of sync with actual running tasks (defensive `max(0, ...)` suggests this has been an issue)

### Problem Area 2: String-Prefix-Based State Detection

**File:** `ChatViewModel.swift`, `retryMessage()` (lines ~219-275)

Message state is determined by inspecting string content:
```swift
private func isTranscriptionMessage(_ message: Message) -> Bool {
    let c = message.content
    return c.hasPrefix(Self.transcriptionErrorPrefix) ||
           c.hasPrefix("⏳") ||
           c.hasPrefix("Transcribing") ||
           c.hasPrefix("Transcription cancelled") ||
           c.hasPrefix("**Transcription**")
}
```

This is **fragile** — if the message format changes, the state detection breaks silently. A proper FSM approach would store message state as a typed enum rather than inferring it from string prefixes.

### Problem Area 3: Transcription Queue Management

**File:** `ChatViewModel.swift` (lines ~605-737)

The transcription queue uses implicit state:
```swift
if activeTranscriptionCount >= maxParallel {
    pendingTranscriptions.append(...)  // Queue
} else {
    startTranscription(...)            // Start immediately
}

private func finishTranscription(taskID: UUID) {
    activeTranscriptionCount = max(0, activeTranscriptionCount - 1)
    if !pendingTranscriptions.isEmpty && activeTranscriptionCount < maxParallel {
        let next = pendingTranscriptions.removeFirst()
        startTranscription(...)
    }
}
```

**Risks:**
- If `startTranscription()` fails immediately, `finishTranscription()` still decrements count and starts next item — the entire queue processes and fails if the error is persistent (e.g., model missing)
- Pending items are not individually tracked — state per-item is implicit
- No guard against persistent errors draining the queue

### Problem Area 4: Streaming Cleanup Choreography

**File:** `ChatViewModel.swift` (lines ~314-403)

Multiple code paths call `finalizeStreaming()`:
```swift
private func finalizeStreaming(for conversationID: UUID? = nil) {
    if let id = conversationID {
        streamingConversationIDs.remove(id)
    } else {
        streamingConversationIDs.removeAll()
    }
    saveContext()
    refreshConversations()
}
```

Completion, error, and cancellation all converge on this method — implicit state transitions rather than explicit ones.

### Problem Area 5: Trigger Counters for Side Effects

```swift
private(set) var focusCounter: Int = 0
private(set) var scrollToTopTrigger: Int = 0
private(set) var scrollToBottomTrigger: Int = 0
```

Counter-based triggers can skip notifications if incremented multiple times between SwiftUI render cycles.

### Problem Area 6: ConversationListView Edit Mode

**File:** `ConversationListView.swift`

Rename flow uses separate booleans:
```swift
@State private var editingConversationID: UUID?
@State private var editingTitle: String
@State private var showDeleteConfirmation: Bool
@State private var editingSystemPromptConversation: Conversation?
```

These can technically be in conflicting states (e.g., `showDeleteConfirmation = true` while `editingConversationID != nil`).

---

## Part IV: Proposed Improvements

### Priority 1 (High): Per-Conversation Activity State Machine

Replace the scattered tracking of what's happening per-conversation with an explicit FSM:

```swift
/// What the system is currently doing for a given conversation
enum ConversationActivity {
    case idle
    case streaming(task: Task<Void, Never>, assistantMessage: Message)
    case transcribing(task: Task<Void, Never>, progress: Double, message: Message)
    case generatingTitle(task: Task<Void, Never>)
}

// In ChatViewModel:
private var activities: [UUID: ConversationActivity] = [:]
```

**What this replaces:**
- `streamingConversationIDs: Set<UUID>`
- `streamingTasks: [UUID: Task<Void, Never>]`
- `transcriptionTasks: [UUID: Task<Void, Never>]`
- `isGeneratingTitle: Bool`
- `activeTranscriptionCount: Int`

**What this prevents:**
- Streaming and transcribing the same conversation simultaneously (if that's invalid)
- Orphaned tasks (task reference is in the state — if state transitions, task must be dealt with)
- isGeneratingTitle stuck true after cancelled task

**Computed properties still work:**
```swift
var isStreamingCurrentConversation: Bool {
    guard let id = selectedConversationID else { return false }
    if case .streaming = activities[id] { return true }
    return false
}
```

### Priority 2 (High): Message Lifecycle Enum

Add a typed state to Message instead of inferring state from string content:

```swift
enum MessageState: String, Codable {
    case draft
    case sent
    case streaming         // Assistant message being generated
    case transcriptionQueued
    case transcribing
    case complete
    case errorTranscription
    case errorLLM
}

// On Message model:
var messageState: MessageState = .complete
```

**What this replaces:**
- `isTranscriptionMessage()` string-prefix detection
- Error prefix checking for retry logic
- The "⏳" / "Transcribing" / "**Transcription**" content markers

**Impact on retry logic:**
```swift
func retryMessage(_ message: Message, in conversation: Conversation) {
    switch message.messageState {
    case .errorTranscription:
        // Re-trigger transcription
    case .errorLLM:
        // Re-trigger LLM
    case .complete where message.role == .user:
        // Delete and re-send
    default:
        break  // Not retryable
    }
}
```

### Priority 3 (Medium): Transcription Queue FSM

Replace the counter + array with an explicit per-item state machine:

```swift
enum TranscriptionItemState {
    case queued
    case starting
    case inProgress(progress: Double)
    case complete(text: String)
    case failed(error: String, retryable: Bool)
}

struct TranscriptionItem: Identifiable {
    let id: UUID
    let audioPath: String
    let displayName: String
    let conversationID: UUID
    let messageID: UUID
    var state: TranscriptionItemState
}

// In ChatViewModel:
private var transcriptionQueue: [TranscriptionItem] = []
```

**What this fixes:**
- Persistent errors no longer drain the entire queue (item enters `.failed`, queue manager checks if error is retryable)
- Each item has individual state tracking
- Progress is per-item, not global

### Priority 4 (Medium): ConversationListView Interaction State

```swift
enum SidebarInteraction {
    case browsing
    case renaming(conversationID: UUID, text: String)
    case confirmingDelete(conversationIDs: Set<UUID>)
    case editingSystemPrompt(conversation: Conversation)
}

@State private var interaction: SidebarInteraction = .browsing
```

Prevents conflicting modals/states.

### Priority 5 (Low): Replace Trigger Counters

Use `PassthroughSubject` or `AsyncStream` instead of counter-based triggers for scroll/focus commands. These don't lose events between render cycles.

---

## Part V: Implementation Strategy

### Recommended Approach: Incremental, Inside-Out

Do NOT adopt TCA or a full framework rewrite. Instead:

1. **Start with Message.messageState** — lowest risk, highest clarity gain. Add the enum to the SwiftData model, migrate string-prefix checks to enum checks. This is a data model change that makes everything downstream cleaner.

2. **Add ConversationActivity** — extract from ChatViewModel. This is the biggest win for reliability. Each conversation gets one explicit activity state instead of scattered bookkeeping.

3. **Refactor transcription queue** — build on the ConversationActivity enum, add per-item state tracking.

4. **Sidebar interaction state** — small, self-contained, good practice.

5. **Trigger counters** — last, since they work adequately now.

### What NOT to Do

- **Don't adopt TCA** — the codebase is already functional with `@Observable` + SwiftUI. TCA would be a massive rewrite for diminishing returns at this scale.
- **Don't use GKStateMachine** — overkill for these patterns; Swift enums do the same thing with less boilerplate and compile-time safety.
- **Don't model everything as FSM** — Settings, static models, and simple CRUD don't benefit. Focus on async lifecycle and UI mode management.

---

## References

### Foundational

1. Harel, D. (1987). "Statecharts: A Visual Formalism for Complex Systems." *Science of Computer Programming* 8(3), 231-274
2. Horrocks, I. (1999). *Constructing the User Interface with Statecharts.* Addison-Wesley — [archive.org](https://archive.org/details/isbn_9780201342789)
3. W3C (2015). "State Chart XML (SCXML): State Machine Notation for Control Abstraction." W3C Recommendation

### Talks and Articles

4. Feldman, R. (2016). "Making Impossible States Impossible." elm-conf — [youtube](https://www.youtube.com/watch?v=IcgmSRJHu_8)
5. Matuschak, A. (2016). "A composable pattern for pure state machines with effects." — [gist](https://gist.github.com/andymatuschak/d5f0a8730ad601bcccae97e8398e25b2)
6. Khourshid, D. (2021). "XState: the Visual Future of State Management." React Summit
7. Dodds, K.C. "Make Impossible States Impossible." — [blog](https://kentcdodds.com/blog/make-impossible-states-impossible)

### Swift-Specific

8. Point-Free. The Composable Architecture — [github](https://github.com/pointfreeco/swift-composable-architecture)
9. Swift by Sundell. "Modelling state in Swift" — [article](https://www.swiftbysundell.com/articles/modelling-state-in-swift/)
10. LINE Engineering (2025). "Implementing a robust state machine with Swift Concurrency" — [blog](https://techblog.lycorp.co.jp/en/20250117a)

### Community

11. [statecharts.dev](https://statecharts.dev/) — Community resource hub
12. [Statecharts in User Interfaces](https://statecharts.dev/use-case-statecharts-in-user-interfaces.html) — Applied patterns
13. [stately.ai](https://stately.ai/) — XState visual editor and tooling
