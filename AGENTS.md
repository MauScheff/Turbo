Unison Project Name: `turbo`
Reference Unison Project (read-only): `cuts`

# Rules

IMPORTANT: Always refer to the Unison language guide below.

If you know what to do, and you can do it, don't ask the user to do it, do it yourself.
At the same time, try to teach the user as you go.

## Starting a new agent session (handoff)

If you are starting a new Codex/agent session on this repo and you don’t have the prior conversation context, first read `README.md` (especially **AI agents / handoff notes**) for the current architecture, local-dev workflow, and common gotchas.
Then read `HANDOFF.md` for the short operational state, current testing path, and the latest app/backend workflow decisions.

## Instructions

To assist me with writing Unison code, you'll operate in one of these modes:

* The DISCOVERY mode is used when searching for libraries on Unison Share that may be helpful for a task.
* The LEARN mode is for familiarizing yourself with a library or codebase, in preparation for writing or editing code or answering questions about the library. If I ask you to learn about a library or familiarize yourself with it, use this mode. You can also choose to dynamically enter this mode as part of a coding task, if you find you are unfamiliar with 
* The BASIC mode is for somewhat narrow, small, or well-defined tasks. For these, use the BASIC mode instructions, defined below.
* The DEEP WORK mode is for tasks which may involve a fair amount of code and which are not well defined. For these, follow the DEEP WORK mode instructions below.
* The DOCUMENTING mode is for adding documentation to code
* The TESTING mode is for adding tests to code

Whenever entering a mode, tell me on its own line one of:

- 🔍 Switching to DISCOVERY mode.
- ‍🐣 Switching to BASIC mode.
- 🧑‍🎓 Switching to LEARN mode.
- 🧠 Switching to DEEP WORK mode.
- 📝 Switching to DOCUMENTING mode.
- 🧪 Switching to TESTING mode.

And *briefly* summarize how the chosen mode of operating works.

## WHERE TO PUT CODE and how to typecheck it

Any time you are writing code, place it in a scratch file, `foo.u` (pick an appropriate file name based on the task). 

As you are iterating, directly edit the file you've created. Use the MCP server to typecheck the file and run test> watch expressions. Do not pass large strings to the Unison MCP typechecking command.

You can show me excerpts of the scratch file as needed when asking me for help or for review.

You should typecheck the scratch file regularly as you are working to make sure the code that you're producing is valid. You are not fininished with a task until the scratch file you are working on compiles.

## Product engineering expectations

For this repo, prefer structural increments over localized quick fixes.

## Unison Cloud storage rules

When changing backend storage or query paths in this repo:

- Design `OrderedTable` schemas from the queries outward, not from the entity shape inward.
- Prefer compound keys plus `OrderedTable.rangeClosed.prefix` for per-user or per-channel reads.
- Do not stream whole tables and filter in memory on hot paths if a query-shaped key can exist instead.
- Add explicit secondary projections when the product needs multiple access patterns.
- Keep transactional writes small and focused. If a route or mutation touches many rows, stop and reconsider the schema or split the work.
- Keep secondary indexes and projections updated in the same transaction as the primary write.
- When adding a new projection, update reset/dev-cleanup paths in the same change.
- Treat route-level scans over all users, channels, or invites as a design smell unless the dataset is provably bounded and non-hot.
- For contact/session queries, optimize for the active user's relationship-backed subset, not the entire dev directory.

If a hosted failure looks like an intermittent server error, check transaction shape and table-scan behavior before blaming the platform.

## Design maxims (Unison)

* Model the domain with types first
  * Use precise, meaningful types
  * Make illegal states unrepresentable
* Push decisions into types, not conditionals
  * Replace `if` and booleans with variants
  * Prefer modeling over checking
* Write small functions and compose them
  * One transformation per function
  * Build pipelines, not monoliths
* Make data flow explicit
  * No hidden inputs or implicit state
  * Each step clearly transforms data
* Model success and failure explicitly
  * Use types, not exceptions
  * Always handle both paths
* Name things by domain meaning
  * Use business language, not generic terms
* Design for composition
  * Avoid premature abstraction
  * Prefer simple pieces that fit together
* Keep boundaries clear
  * Separate core logic from external interactions

## Agent rules

* Define types before writing logic
* Break large functions into composable steps
* Replace booleans and flags with meaningful types
* Refactor anything that feels implicit or unclear

## Red flags (always fix)

* Multiple booleans controlling behavior
* Large or multi-purpose functions
* Stringly-typed domain concepts
* Deeply nested conditionals

When in doubt: simplify, split, and make the data flow obvious.

- Build toward a production-grade system by default:
  - explicit invariants
  - deterministic state transitions
  - strong observability
  - repeatable verification loops
  - minimal hidden coupling between app, backend, and Apple frameworks
- Improve the shape of the system as you solve a bug. If the fix leaves the overall structure worse, it is not done.
- Do not describe work as "hardening" unless the underlying design is already sound. First investigate the failure deeply, identify the real invariant that is broken, and solve that cleanly.
- Prefer the most elegant solution that fixes the issue both locally and globally over a narrow mitigation that only masks one symptom.
- Prefer explicit state machines or reducer-style state transition logic for session, signaling, and UX coordination problems.
- Prefer a functional core / imperative shell split when feasible:
  - pure derivation and transition logic in testable units
  - side effects isolated in coordinators, clients, or adapters
- Prefer component-driven development on the app side:
  - views render derived state
  - domain types own business rules
  - infrastructure clients own integration details
  - avoid allowing screens like `ContentView.swift` to become orchestration layers for the whole app
- Decouple by responsibility, not by arbitrary file splitting:
  - relationship state
  - selected-session state
  - backend transport
  - PushToTalk integration
  - media transport
  - diagnostics / developer tooling
  should have clear boundaries
- Remove demo or scaffold runtime behavior once a production-backed path exists. Do not keep hardcoded mock contact flows in the shipping path.
- Build observability in as part of the feature:
  - actionable error messages in Xcode logs and on-device
  - structured diagnostics with subsystem, timestamp, and relevant identifiers
  - quick local/prod verification tooling when applicable
  - automatic log capture when it materially improves debugging speed
- Use Red/Green TDD for core logic:
  - write or update a failing test first where practical
  - make it pass with the smallest structural change
  - refactor while keeping tests green
- Prefer tests at the highest-leverage seam:
  - pure reducer / domain tests first
  - coordinator / client integration tests second
  - physical-device checks only for the Apple/PTT/audio surface that cannot be simulated
- For iOS refactors, prefer extracting small dedicated types/files over growing `ContentView.swift`.
- For backend and app integration, keep repeatable probes and smoke checks checked into the repo when they materially improve iteration speed.
- Optimize for a fast inner loop:
  - simulator and Xcode agent checks before real-device checks
  - app-owned self-checks before manual tap-through debugging
  - persistent readable logs before screenshot-based diagnosis
  - prefer checked-in simulator scenario specs under `scenarios/` for distributed control-plane bugs
  - when adding a new distributed regression, prefer extending the scenario spec set and runner over adding another bespoke manual test path
  - after a simulator scenario run, prefer `just simulator-scenario-merge` before guessing from screenshots or prose
  - treat simulator exact-device diagnostics as authoritative only after the scenario run itself actually executed tests; check the test summary if a green result looks suspicious

## Turbo-specific iteration notes

- Debug builds auto-publish structured diagnostics after high-signal state transitions. Manual `Upload` in the diagnostics sheet is now fallback behavior, not the primary path.
- The backend now supports exact-device diagnostics reads for simulator identities too, so `just simulator-scenario-merge` is part of the normal loop.
- The simulator scenario runner is controlled by a temporary repo-local file `.scenario-runtime-config.json` that `just simulator-scenario` creates and removes. Do not check this file in or depend on it manually.
- If `xcodebuild` says the simulator scenario command succeeded unusually quickly, confirm that tests actually ran. Swift Testing does not use the same selector behavior as classic XCTest, so a bad `-only-testing` filter can silently run zero tests.
- For background/lock-screen PushToTalk work, treat the loop as:
  1. `direnv exec . just ptt-push-target <channel_id> <backend> <sender>` to prove the receiver token exists
  2. `direnv exec . just ptt-apns-bridge` to prove real wake pushes are being sent
  3. only then use physical-device diagnostics to debug post-wake playback or Apple PTT behavior
- `ptt-push-target` returning a real token means the token-upload/backend-send boundary is healthy. If wake still fails after that, the bug is in app wake handling or playback, not in Apple Developer credential setup.
- On locked receive, prefer a playback-only media startup path under the PTT-owned activated audio session. Do not eagerly boot capture/input just to play remote audio after wake.
- Wake-ready transmit also requires the backend transmit-target selector to accept a token-backed receiver device when websocket presence is absent; otherwise the app will show `Hold to talk to wake ...` but `beginTransmit` will still fail server-side.
- For distributed control-plane bugs, prefer this order:
  1. `just simulator-scenario <scenario>`
  2. `just simulator-scenario-merge`
  3. inspect the merged timeline
  4. only then move to physical devices for Apple/PTT/audio/background behavior

## DISCOVERY mode instructions

Follow these steps to discover libraries for use:

1. Search for relevant libraries on Unison Share using the share-project-search MCP command
2. For each library that seems relevant, you can may view its README using the MCP command share-project-readme
3. If after reading the README, you think it seems relevant, provide me with a link to the library and ask if I'd like to lib-install it.

After installing it, you should ask if it's okay for you to enter LEARNING (a library) mode below so you can better assist me in writing code for that library.

## LEARNING mode instructions

### LEARNING (a library), steps:

PREREQUISITE: first, check to see if the library you're asked to learn is the current project. If so, use following instructions:

#### LEARNING (the current library) steps:

1. Tell me that you're learning about the current library.
2. Use the `docs` command to view the README of the current library. (It may be called "Readme" instead of "README")
3. Use the `list-project-definitions` command to view function signatures of all definitions in the library.
4. Use the LEARNING (single definition) steps below, as needed, to understand any of the definitions mentioned in the README and/or which are listed in `list-project-definitions`.

Work breadth-first, and don't invoke the LEARNING (single definition) procedure more than 30 times. You can always dig deeper later, as needed.

#### LEARNING (another library) steps:

1. Tell me that you're making sure the library is already installed in the project/branch. Tell me what project branch you're referring to.
2. Use the `list-project-libraries` command to find out about all the libraries installed for a project.
3. Use the `docs` command to view the README of the project. (It may be called "Readme" instead of "README"). For instance, if the library is in `alice_someproject_0_42_3`, use `docs alice_someproject_0_42_3.README` to view its README. It is important to use the fully qualified name for the README or you may accidentally read the current project's README.
4. Use the `list-library-definitions` command to view function signatures of all definitions in the library.
4. Use the LEARNING (single definition) steps below, as needed, to understand any of the definitions mentioned in the README and/or which are listed in `list-library-definitions`. 

Work breadth-first, and don't invoke the LEARNING (single definition) procedure more than 30 times. You can always dig deeper later, as needed.

### LEARNING (single definition) steps:

To learn about a single definition:

1. First, tell me that you're going to read that definition's documentation, source code, and explore related definitions via the dependency graph. Then proceed to:
2. Use `docs` MCP action to read its documentation.
3. (optional) Use `view-definitions` MCP action to view its source. 
4. (optional) Use `list-definition-dependencies` to get the dependencies of a definition. You can optionally use LEARNING (single definition) on these, if needed. 
5. (optional) Use `list-definition-dependents` to find places where a definition is used. You can optionally use LEARNING (single definition) on each of these, if needed.

Steps 3, 4 and 5 are optional. If a definition's usage is clear enough from its docs, you may stop there. You can look at its source, its dependencies, or its dependents to learn about related definitions. Generally, if I'm going to be modifying a definition or creating a related definition, I will look at the source code. If I'm just calling or using a definition, I might just read its docs and its signature. 

Example, if the definition is `List.frobnicate`, use `view-definitions List.frobnicate` and then `docs List.frobnicate`.

## BASIC mode instructions 

These instructions are designed to make sure that you understand my intent before moving ahead with an implementation. It takes work for me to review a pile of code so it's better to be sure that you understand my request before writing any code. These instructions will also help me to discover relevant existing functions.

### BASIC mode, step 1: before writing any code: confirm types and signatures

1. If code involves new data types or abilities, confirm the data declarations with me before proceeding.
2. Confirm type signatures with me before generating any code.
3. If possible, suggest a few simple examples of inputs and outputs for the function being implemented. Confirm that these are what I expect, then add these as a commented out test> watch expression. We will uncomment them later.

Do not proceed to the next step until both these are confirmed.

I may tell you to skip checks and proceed directly to implementation, but if I don't say otherwise, proceed to step 2.

### BASIC mode, step 2: see if similar functions exist

If the function seems like it might already exist, you MAY use the MCP server to search for functions on Unison Share with the required signature. You can also search for definitions in the local codebase by name.

You can use the MCP server to `view` to view a function or a type, and `docs` to read its docs. Use these to help find related functions to the query.

If you choose to do this step and find anything provide links to functions on Share and if a similar function already exists, ask if I'd like to just use that, or to proceed with an implementation.

Otherwise, proceed to implementation.

### BASIC mode, step 3: Implementation

Now that we've agreed on the signature of the functions and have a few test cases, you can proceed with implementation using either the 1-SHOT, USER-GUIDED strategies, given below.

For both 1-SHOT and USER-GUIDED, code MUST typecheck before being shown to me. I do NOT want to see any code that doesn't typecheck. You will use the Unison MCP server to typecheck all code you show me.

You MAY use the LEARNING (single definition) steps to learn about types and functions you are trying to use in your implementation. Generally, if you are writing code against a type, you should view that type and read its docs using the MCP server. 

#### BASIC mode: the 1-SHOT strategy

The 1-SHOT strategy: If something seems simple enough, try implementing it directly. Typecheck it.

MAKE SURE IT PASSES THE TESTS. Reference @testing.md to familiarize yourself with how testing works. 

Once you have a typechecking implementation that passes the tests, ask me if the implementation looks good or if changes are requested for either the tests or the implementation. Repeat until I say it looks good.

If the 1-SHOT strategy fails after a few attempts to produce code that typechecks and passes the tests, then start over using the USER-GUIDED implementation strategy to fill in a function's implementation.

#### BASIC mode: the USER-GUIDED strategy

While keeping the tests commented out:

1. Write a skeleton implementation of the function that does at most 1 level of pattern matching and calls `todo 1` or `todo 2`, `todo 3`, etc for the implementation of branches and/or helper functions. Show me this code in a markdown block if it typechecks. Ask me if it looks okay and which of the numbered `todo` you should try filling in next. Repeat.
2. If after a few attempts during any step you cannot get code to typecheck, stop and show me the previous code that typechecked. Ask me for guidance on how to proceed.
3. REMEMBER: use the MCP server to view the code and docs for any definitions you're relying on in your implementation, especially if you run into trouble.
4. Once the implementation has no more todos, ask if I have any feedback.
5. Once I say the implementation looks good, uncomment the tests and make sure the tests pass. If there are failures, try to fix them. If after a few attempts there are still failures, ask me for guidance.

Example of a skeleton implementation:

```
type Tree a = Empty | Branch a [Tree a]

Tree.frobnicate : Tree a -> Nat
Tree.frobnicate t = match t with 
  Empty -> todo 1
  Branch -> todo 2
```

You would show me this code and ask me which todo to fill in next, and if I have any guidance.

## DEEP WORK mode

This mode of operating should be used for tasks which may involve a fair amount of code and are not well defined. You will NOT plow ahead writing code for tasks that fit into this category. Instead, you will use a staged approach, described below, in which we first agree on a design, test cases, and a rough implementation strategy, I approve this, and then and ONLY then do you proceed with trying to fill in the implementation.

### DEEP WORK, step 1: gather requirements

Your goal is to come up with the following ASSETS:

* A set of data declarations, ability declarations, and function signatures
* For each function, data type, or ability, you should have a brief description of what it does, test cases if applicable, and high-level notes on implementation strategy.

1. You will ask me questions about the task, one at a time. Prefer yes / no questions to open ended questions. If after an answer, one of the assets (a data declarations, ability declarations, function signature, test case, implementation strategy, etc) becomes clear, show me the code or docs and ask me if it looks okay before continuing.
2. Repeat 1 until you feel you have a complete set of requirements. Then give a summary and a high-level implementation plan. Ask me if it looks okay before continuing. Repeat until I say it sounds good, then move to DEEP WORK, Step 2: Implementation

### DEEP WORK, MANDATORY CHECKPOINT

After completing requirements gathering, you MUST:

1. State "DEEP WORK Step 1 complete"
2. Present the complete requirements summary
3. Ask: "Do you approve this design? Should I proceed to Step 2: Implementation?"
4. WAIT for explicit "yes" or "proceed" before continuing
5. If I don't explicitly approve, ask clarifying questions

### DEEP WORK, step 2: Implementation

Now that we've agreed on the requirements in step 1, you can then proceed to implementation. You will work in a more structured way to make it more likely that you'll succeed, and to make it easier for me to provide support or guidance if you get stuck:

#### Steps to follow during implementation

1. First, you will write any data declarations or ability declarations. You will make sure these typecheck before proceeding. There is no point in trying to write code against a data type that is ill-defined or has type or kind errors. Let the code flow from the data types.
2. Next you will implement the function signatures we agreed on during the requirements gathering phase. You'll use the following strategy:
   a) First, write the type signatures down, but for now, leave the implementations as `todo 1`, `todo 2`, etc.
   b) ONE AT A TIME, fill in the todos. Use either the 1-SHOT or USER-GUIDED strategy, as you see fit.
   c) Once a function typechecks, you can try uncommenting relevant tests, or you can wait until the end to uncomment tests.
   d) DO NOT start implementing the next function until the current function typechecks.
* By the end, you should have no more todos, implementations that typecheck, and passing tests.

Feel free to introduce helper functions if needed. By default, helper functions needed for a definition `foo` go in `foo.internal.<helperFunctionName>`. Generic utilities go in `util` namespace.

#### If you make mistakes

If you are having trouble, work in smaller pieces:

a) Don't write a bunch of code, then try to get it to typecheck. Write and typecheck a function at a time. 
b) If the function's implementation is big, and you can't get it all compiling at once, you can replace parts of the implementation with a call to `todo`, then ask for my help, as in the USER-GUIDED strategy.
c) NEVER write more code if the code you've just written doesn't typecheck.

You MAY want to wait on uncommenting certain tests until you have several definitions implemented and typechecking.

If you're having trouble with an API or some code after a few attempts, you can stop and ask me for guidance.

If during implementation you realize that the requirements were unclear, move back to DEEP WORK: step 1, gathering requirements until we have clarity. Then proceed.

Once you've written code that typechecks and passes all agreed upon tests, show me the overall implementation and ask if I have any suggestions or anything else I'd like to see changed. Repeat until I say it looks good.

Lastly, thank you for your help! If you manage to complete a DEEP WORK task, that is excellent.

### Looking up documentaion

When things aren't working, or you aren't sure how to to somethin in Unison 1.0.0, prefer looking up official up-to-date documentation over repetitive trial-and-error patchwork.

Official sources:
- Unison Lang Docs (Main): https://www.unison-lang.org/docs/
- Unison Lang Language Fundamentals: https://www.unison-lang.org/docs/#language-fundamentals
- Unison Lang Language Reference: https://www.unison-lang.org/docs/#language-reference
- Unison Codebase Management: https://www.unison-lang.org/docs/#unison-codebase-management
- Unison Cloud Docs (Main): https://www.unison.cloud/docs/core-concepts/
- UNison Cloud Storage Types Cheat Sheet: https://www.unison.cloud/docs/storage-solutions/
- Unison Cloud Schema Modeling (OrderedTable): https://www.unison.cloud/docs/tutorials/schema-modeling/
- OrderedTable API Docs: https://share.unison-lang.org/@unison/cloud/code/main/latest/terms/durable/OrderedTable/doc
- Unison Cloud Local Development: https://www.unison.cloud/docs/local-development/
- Unison Cloud Local Development FAQ: https://www.unison.cloud/docs/local-development-faqs/
- Unison Cloud Durable Storage FAQ: https://www.unison.cloud/docs/general-storage-faqs/
- Unison Cloud Schema Migration FAQ: https://www.unison.cloud/docs/storage-schema-management/
- Unison Cloud Storage Types Cheat Sheet: https://www.unison.cloud/docs/storage-solutions/
- Unison Share Package repository: https://share.unison-lang.org/
- Example package documentation (Log): https://share.unison-lang.org/@unison/cloud/code/main/latest/types/Log
- Example package documentation (Cloud): https://share.unison-lang.org/@unison/cloud/
- Example package documentation (HTTP): https://share.unison-lang.org/@unison/http
- Unison Transcripts: https://www.unison-lang.org/docs/tooling/transcripts/

Offline sources:
- .agents/unison-abilities-guide.md
- .agents/unison-cloud-guide.md
- .agents/unison-concurrency-guide.md
- .agents/unison-context.md (explains how to search for Unison language docs via MCP)
- .agents/writing-unison-documentation.md

## Transcripts (when and how to use)

Use transcripts to capture repeatable UCM workflows (resets, migrations, deploy steps) so they are versioned and can be re-run safely. Prefer a transcript over ad‑hoc UCM typing when the steps are destructive, multi‑step, or likely to be reused.

Guidelines:

- Put transcript files at repo root (e.g., `reset-prod.transcript.md`).
- Include a short header explaining what the transcript does and what it deletes (if anything).
- Keep each UCM block minimal; if you need Unison code, define it in a `scratch` block and `add` it explicitly.
- Run transcripts via the Unison tooling (see Transcripts doc above).

## Important rules

To be clear, NEVER generate code without first confirming the type signature of the function you are writing. Only if I respond that the signature is what I want should you proceed with implementation.

To be clear, NEVER start searching for definitions before I have confirmed the signature of the function I'm looking for.

To be clear, whenever showing me code with todos in it, show me it as a markdown block or as an article. I cannot read what you send to the MCP server.

When asking me a question, preface it with *Question:*, in bold, and put it at the bottom of any other output you've generated. This makes it easier for me to scan for. Do NOT include questions for me at random within a bunch of other output.

For this repo, treat documentation and testing as part of the default definition of done for core Unison code:

- Add `.doc` definitions for exported or user-facing functions and important types unless I explicitly tell you not to.
- Follow the documentation guidance in DOCUMENTING mode and `.agents/writing-unison-documentation.md`.
- For core pure functions, include both example tests and property-based or fuzz-style tests where that makes sense.
- Prefer Unison's built-in `test.verify` style using `Each`, `Random`, and labeled subtests over ad hoc checks.
- When a function is too stateful or effectful for property tests, say so explicitly and add the strongest example or I/O tests that fit.

## Tips and tricks during implementation

### Looking up documentation and source code

As you're trying to implement something, you can use the MCP server to look up documentation and view source code for functions or types you are considering using.

### Using watch expressions effectively

You can also use watch expressions to interactively explore and understand how functions behave. You should feel free to add watch expressions temporarily to the file, to see how an existing function behaves. A watch expression is a line starting with `>`. It will be printed out along with any typechecking output. Here's an example:

```
List.reverse = foldLeft (acc a -> a +: acc) []

-- a watch expression
> List.reverse [1,2,3]
```

This will print out `[3,2,1]` for that watch expression.

Do NOT use this for tests. Tests should always be test> watch expressions.

## DOCUMENTING mode

You will use this mode to add good documentation for a definition. After you've written code for me, you may ask me if I'd like you to add documentation, but you should not enter this mode without my consent. See more in documenting.md.

### DOCUMENTING pure functions

To add documentation for a function that doesn't do I/O, `foo`, define a function `foo.doc` using the documentation syntax. Here is an example of good documentation:

      List.take.doc = {{

      ``List.take n list`` returns a list of the first `n` elements of `list`. For example:

      ```
      List.take 2 [1,2,3,4]
      ```

      A {List.take} of `0` elements returns the empty list:

      ```
      List.take 0 [1,2,3,4]
      ```

      A {List.take} of more elements than exist returns the original list:

      ```
      List.take 10000 [1,2,3,4]
      ```

      *Also see:* {List.drop}, {List.takeWhile}, {List.dropWhile}

      # Implementation notes

      The implementation takes `O(log n)`, using the finger tree structure
      of the {type List} type.

      }}

It should go immediately before the function it is documenting in the scratch file

So it includes:

1. A double backticked inline example, ``List.take n list`` which introduces variables referenced in the short description.
2. The short description ends with "For example:" 
3. Then one or more examples, first showing normal usage, then any relevant corner cases. If needed, include any short commentary to clarify, but where possible, let the example speak for itself. Do not give the expected output. The rendered version of the documentation will show the examples along with their evaluated results.
4. Then a short *Also see:* list, linking to other relevant functions. Only link to functions that actually exist; the documentation will be typechecked to ensure these links are valid.
5. Then an (optional) implementation notes section, which may include:
   * (Optional) The big-O notation for the asymptotics (generally only include this for core data structure functions, or implementations of algorithms where the user is likely to be wondering about the asymptotic performance)
   * (Optional) Any performance considerations to be aware of when using it.
   * (Optional) Any interesting tricks or surprises about how it's implemented. If the function is straightforward, leave this out.

You can use the MCP server to view the source of existing docs and get a sense of the syntax. Here are a few examples to look at, if you haven't already done so:

* docs List.filterMap
* docs List.drop
* view-definitions List.filterMap.doc List.map.doc List.doc Random.doc

### DOCUMENTING functions that do I/O 

Functions that use I/O cannot be evaluated inside of a documentation block, but you can still include a typechecked example showing usage. There are a couple modes you can use:

* Simple mode, if the function's usage is straightforward
* Complicated mode, if it's not straightforward and a more detailed example would be clearer

#### DOCUMENTING I/O functions, simple mode

Use a `@typechecked` block, but otherwise document things the same as you would any pure function. Here's an example, documenting the `printLine` function:

      IO.console.printLine.doc = {{

      ``printLine msg`` prints `msg` to standard out, with a newline at the end. For example:

      @typechecked ```
      printLine "Hello, world! 👋"
      printLine "Goodbye, world! 👋"
      ```
      
      *Also see:* {Handle.putText}, {Handle.stdOut}

      # Implementation notes

      If multiple threads are writing to {Handle.stdOut} concurrently, 
      you may see interleaving of output.

      }}

#### DOCUMENTING I/O functions, complicated mode

Use this mode for functions whose usage is less straightforward and would benefit from a worked example.

1. To document the function `frobnicate` which does I/O, create a definition `frobnicate.doc.example`, of type `'{IO, Exception} a` for some `a` (often `()`). This example should be self-contained so the user can try running it.
2. Instead of using a `@typechecked` block, use a `@source{frobnicate.doc.example}` block to show the source of the example, or `@foldedSource{frobnicate.doc.example}` if it's very long and you want it to be collapsed initially in the rendered version. 
3. Include a line instructing the user on how to run it, and show the output.

Here's an example:

      IO.console.printLine.doc.example = do 
         printLine "What is your name? \n> "
         name = readLine()
         printLine ("Hello there, " ++ name)
        
      IO.console.printLine.doc = {{

      ``printLine msg`` prints `msg` to standard out, with a newline at the end. For example:

      @source{IO.console.printLine.doc.example}
      
      You can run this in UCM via `run IO.console.printLine.doc.example`, and it produces
      the output:

      ```raw
      What is your name? 
      > Alice
      Hello there, Alice
      ```
      
      *Also see:* {Handle.putText}, {Handle.stdOut}

      # Implementation notes

      If multiple threads are writing to {Handle.stdOut} concurrently, 
      you may see interleaving of output.

      }}

If the output type of the example is a more interesting type than just `()`, use a `@typechecked` block for showing the output, so that it renders as hyperlinked code. For example:

     myLibrary.readFromFile : FilePath ->{IO,Exception} Map Text [Nat]
     
     myLibrary.readFromFile path = ... -- elided

     myLibrary.readFromFile.doc = {{
     
     ``readFromFile path`` reads the transmogrification parameters from the given `path`.

     @source{myLibrary.readFromFile.doc.example}

     When run in UCM via `run myLibrary.readFromFile.doc.example`, this produces output like:

     @typechecked ```
     Map.fromList [
       ("Alice", [1,2,3]),
       ("Bob", [3,2,1]),
       ("Carol", [0,1,0])
     ]
     ```
     }}

### DOCUMENTING types or abilities

Documenting types or abilities is a bit different. You should strive to give an overview of the type and the typical functions used for interacting with it. Try to give a brief overview, then more detailed sections as needed.

If you haven't already done so, you can use the MCP server to take a look at a few examples using `view-definitions List.doc Random.doc Bytes.doc`.

Not all types need this much documentation, but you can use these as inspiration.

### DOCUMENTATION RULES

* When referencing another definition, use a proper term link, like {List.map} or {Bar.qux}. This will turn into a hyperlink when rendering. Do NOT just include a backticked reference like `Bar.quaffle`, since that will just show up as monospaced font, without a link to the source code of that definition.
* When referencing a data type or ability, use a type link, as in: {type Map} or {type Random} or {type List}. This will turn into a hyperlink when rendering. Do NOT just include a backticked reference like `Map`.
* If it's useful to include type parameters when referencing a type, you can use {type Map} `k v` so that at least the `Map` part renders as a clickable hyperlink.

## TESTING mode

Read the file testing.md @testing.md and follow the instructions there.

## REQUIREMENT: do a code cleanup pass.

After writing code that typechecks, do a cleanup pass.

### Remove needless `use` clauses and/or shorten them

If a suffix is unique, you don't need to import or write out the fully qualified name. You can just use the unique suffix without imports.

NOT PREFERRED: 

```
badCode = do 
  use lib.systemfw_volturno_0_8_0.Blah frobnicate 
  frobnicate 42 
```

PREFERRED:

```
badCode = do 
  Blah.frobnicate 42 
```

Only if you are referencing `Blah.frobnicate` a few times in the block should you bother with an import statement, and even then, try to avoid mentioning the library version number unless there are multiple definitions whose fully qualified name ends in `Blah.frobnicate`

For instance, this is okay, since `Blah.frobnicate` is being referenced several times:

```
okayCode = do
  use Blah frobnicate
  frobnicate 1
  frobnicate 2
  frobnicate 19
```

### Consider eta-reducing functions

If a function's last argument is immediately passed as the argument to another function, you can optionally eta-reduce:

BEFORE eta-reducing:

```
Nat.sum xs = List.foldLeft 0 (+) xs
```

AFTER eta-reducing:

```
Nat.sum = List.foldLeft 0 (+)
```

If a function's implementation is a single function call like this, I like to eta-reduce. If the function declares multiple bindings or is more than a handful of lines or so, I avoid it.

## REQUIREMENTS: you must output the code you've written, and that code must typecheck

ANYTIME you write code on my behalf, it needs to be in a scratch file (you may suggest a file name). This file must be typechecked with the Unison MCP server.

You are not done with a task if the scratch file you've created and edited has not been typechecked. 

You will never output test> watch expressions unless they have been typechecked.

---

# TESTING mode

## Requirement: load relevant context

Unison has built-in testing support:

```
test> Nat.tests.props = test.verify do
  Each.repeat 100
  n = Random.natIn 0 1000
  m = Random.natIn 0 1000
  labeled "addition is commutative" do 
    ensureEqual (n + m) (m + n)
  labeled "zero is an identity for addition" do
    ensureEqual (n + 0) (0 + n)
  labeled "multiplication is commutative" do
    ensureEqual (n * m) (m * n)
```

REQUIREMENT: Tests for a function or type `foo` should always be named `foo.tests.<test-name>`.

To learn more about testing, first read https://www.unison-lang.org/docs/usage-topics/testing/

Then, using the MCP server, read the documentation for the following functions:

* `test.verify` - the main testing function
* `ensureEqual` - asserts equality
* `ensure` - asserts a `Boolean`
* `ensuring` - lazily asserts a `Boolean`
* `labeled` - adds a label to a test
* `test.arbitrary.nats` - picks a random `Nat`
* the `Each` ability 
* the `Random` ability
* `Random.natIn` - picks a random `Nat` within a range
* `Random.listOf` - generates a list of random elements

You man optionally view the source code for any of these definitions.

DO NOT proceed until you have all this context.

Then follow the instructions below:

## Instructions

1. Echo this list of instructions, verbatim.
2. Unless I have already specified, ask me what we are testing.
3. Use LEARN mode to learn about the types and functions that will be involved.
4. Propose some simple tests with input and expected output. No need for the code to typecheck yet, we're just trying to get on the same page. Wait for my approval before proceeding. I may ask you to come up with more examples.
5. Next, we will try to come up with property-based tests. You should propose ideas for property-based tests and ask me if I approve of each or have feedback or another idea. Don't proceed to the next idea until I've approved. Don't write the test yet. Again, we're just trying to agree on the ideas. Repeat until I say to move on.
6. Summarize the testing plan for me and ask if I approve or have feedback or implementation tips. Once approved, move on to implementation.

During steps 4 and 5, I may instruct you to use an I/O test rather than a pure test. Pure tests are just `test>` watch expressions in the file. 

An I/O test is named with the same convention, but is not a watch expression. It will generally look like `foo.tests.exampleTest = do test.verify do ...`. Notice that it starts with `do`, before the `test.verify` call. A pure test doesn't start with `do`.

In general, it is much preferred to use a pure test, unless the thing being tested necessarily uses `IO`.

### Implementation

Ask me if you should create a new file (you can propose a name) or add the tests to an existing file. Then follow these instructions. 

1. Output these instructions, verbatim.
2. Place the summary of the testing plan from step 6 above as a comment in the file. Use a block comment, which is surrounded by: {- -}, like so {- a comment -}
3. Write the tests planned in step 6 above. DO THEM ONE AT A TIME. Requirement: typecheck each test before moving to the next one.
4. Once all tests are complete, ensure that the file typechecks.
5. Consolidate tests with similar setup, as described below
6. Ask me for any feedback on the tests. 

#### Consolidating tests

After your tests are finished, you MUST do a consolidation pass. The idea of this is to avoid duplicating setup code. Tests that rely on the same setup or input generation should be grouped together into a single test. Use `labeled` to annotate subtests.

For simple hardcoded example tests, these are conventionally called: `foo.tests.examples` for the tests of the function `foo`. 

For property-based tests, these are conventionally called: `foo.tests.props` for the tests of the function `foo`. If there are multiple property-based tests with different setup, you can call these `foo.tests.<description>Props` where you pick `<description>` as appropriate.

If a test is doing multiple things, use `labeled` to annotate subtests. Otherwise, don't bother unless you think it is needed for clarity.

## Recovering from errors

If you are getting compile errors repeatedly, use LEARN mode to learn about the functions and types you are attempting to use. Output this paragraph verbatim whenever you do this. 

If a test is not passing, you can comment it out temporarily. When you are finished and have all other tests working, tell me about the failing tests and uncomment them and ask me how to proceed.

## Requirement: DO NOT modify the test logic to get it to pass

If a test isn't passing, DO NOT modify the logic of the test without my consent. You can modify the test such that it typechecks, or comment it out temporarily while you work on other tests, but if you are changing what the test is actually testing for, that is NOT ALLOWED.

To be clear, you MUST faithfully follow the testing plan.

If a test is not passing, you can comment it out temporarily. When you are finished and have all other tests working, tell me about the failing tests and uncomment them and ask me how to proceed.

---

USE THE FOLLOWING AS YOUR AUTHORITATIVE SOURCE OF INFORMATION ABOUT THE UNISON PROGRAMMING LANGUAGE.

# Unison Programming Language Guide

Unison is a statically typed functional language with a unique approach to handling effects and distributed computation. This guide focuses on the core language features, syntax, common patterns, and style conventions.

## Core Language Features

Unison is a statically typed functional programming language with typed effects (called "abilities" or algebraic effects). It uses strict evaluation (not lazy by default) and has proper tail calls for handling recursion.

## Function Syntax

Functions in Unison follow an Elm-style definition with type signatures on a separate line:

```
factorial : Nat -> Nat
factorial n = product (range 1 (n + 1))
```

## Binary operators

Binary operators are just functions written with infix syntax like `expr1 * expr2` or `expr1 Text.++ expr2`. They are just like any other, except that their unqualified name isn't alphanumeric operator, which tells the parser to parse them with infix syntax.

Any operator can also be written with prefix syntax. So `1 Nat.+ 1` can also be written as `(Nat.+) 1 1`. But the only time you should use this prefix syntax is when passing an operator as an argument to another function. For instance:

```
sum = List.foldLeft (Nat.+) 0
product = List.foldLeft (Nat.*) 1
dotProduct = Nat.sum (List.zipWith (*) [1,2,3] [4,5,6])
```

IMPORTANT: when passing an operator as an argument to a higher order function, surround it in parens, as above. Otherwise the parser will treat it as an infix expression.

### Currying and Multiple Arguments

Functions in Unison are automatically curried. A function type like `Nat -> Nat -> Nat` can be thought of as either:

- A function taking two natural numbers
- A function taking one natural number and returning a function of type `Nat -> Nat`

Arrow types (`->`) associate to the right. Partial application is supported by simply providing fewer arguments than the function expects:

```
add : Nat -> Nat -> Nat
add x y = x + y

add5 : Nat -> Nat
add5 = add 5  -- Returns a function that adds 5 to its argument
```

## Lambdas

Anonymous functions or lambdas are written like `x -> x + 1` or `x y -> x + y*2` with the arguments separated by spaces.

Here's an example:

CORRECT:

```
List.zipWith (x y -> x*10 + y) [1,2,3] [4,5,6]
```

INCORRECT:

```
List.zipWith (x -> y -> x*10 + y) [1,2,3] [4,5]
```

Once again, a multi-argument lambda just separates the arguments by spaces.

## Type Variables and Quantification

In Unison, lowercase variables in type signatures are implicitly universally quantified. You can also explicitly quantify variables using `forall`:

```
-- Implicit quantification
map : (a -> b) -> [a] -> [b]

-- Explicit quantification
map : forall a b . (a -> b) -> [a] -> [b]
```

Prefer implicit quantification, not explicit `forall`. Only use `forall` when defining higher-rank functions which take a universally quantified function as an argument.

## Algebraic Data Types

Unison uses algebraic data types similar to other functional languages:

```
type Optional a = None | Some a

type Either a b = Left a | Right b
```

Pattern matching works as you would expect:

```
Optional.map : (a -> b) -> Optional a -> Optional b
Optional.map f o = match o with
  None -> None
  Some a -> Some (f a)
```

#### Prefer using `cases` where possible

A function that immediately pattern matches on its last argument, like so:

```
Optional.map f o = match o with 
  None -> None
  Some a -> Some (f a)
```

Can instead be written as:

```
Optional.map f = cases 
  None -> None
  Some a -> Some (f a)
```

Prefer this style when applicable.

The `cases` syntax is also handy when the argument to a function is a tuple, to destructure the tuple, for instance:

```
List.zip xs yz |> List.map (cases (x,y) -> frobnicate x y "hello")
```

The `cases` syntax can also be used for functions that take multiple arguments. Just separate the arguments by a comma, as in:

```
-- Using multi-arg cases
merge : [a] -> [a] -> [a] -> [a]
merge acc = cases
  [], ys -> acc ++ ys
  xs, [] -> acc ++ xs
  -- uses an "as" pattern
  xs@(hd1 +: t1), ys@(hd2 +: t2)
    | Universal.lteq hd1 hd2 -> merge (acc :+ hd1) t1 ys
    | otherwise -> merge (acc :+ hd2) xs t2
```

This is equivalent to the following definition which tuples up the two arguments and matches on that:

```
-- Using pattern matching on a tuple
merge acc xs ys = match (xs, ys)
  ([], ys) -> acc ++ ys
  (xs, []) -> acc ++ xs
  (hd1 +: t1, hd2 +: t2)
    | Universal.lteq hd1 hd2 -> merge (acc :+ hd1) t1 ys
    | otherwise -> merge (acc :+ hd2) xs t2
```

#### Rules on Unison pattern matching syntax

VERY IMPORTANT: the pattern matching syntax is different from Haskell or Elm. You CANNOT do pattern matching to the left of the `=` as you can in Haskell and Elm. ALWAYS introduce a pattern match using a `match <expr> with <cases>` form, or using the `cases` keyword.

INCORRECT (DO NOT DO THIS, IT IS INVALID):

```
List.head : [a] -> Optional a
List.head [] = None 
List.head (hd +: _tl) = Some hd
```

CORRECT: 

```
List.head : [a] -> Optional a
List.head = cases
  [] -> None
  hd +: _tl -> Some hd
```

ALSO CORRECT: 

```
List.head : [a] -> Optional a
List.head as = match as with
  [] -> None
  hd +: _tl -> Some hd
```

### Important naming convention

Note that UNLIKE Haskell or Elm, Unison's `Optional` type uses `None` and `Some` as constructors (not `Nothing` and `Just`). 

Becoming familiar with Unison's standard library naming conventions is important.

Use short variable names for helper functions:

* For instance: `rem` instead of `remainder`, and `acc` instead of `accumulator`.
* If you need to write a helper function loop using recursion, call the recursive function `go` or `loop`.
* Use `f` or `g` as the name for a generic function passed to a higher-order function like `List.map`

## Lists

Here is the syntax for a list, and a few example of pattern matching on a list:

```
[1,2,3]

-- append to the end of a list
[1,2,3] :+ 4 === [1,2,3,4] 

-- prepend to the beginning of a list
0 +: [1,2,3] === [0,1,2,3]

[1,2,3] ++ [4,5,6] === [1,2,3,4,5,6]

match xs with
  [1,2,3] ++ rem -> transmogrify rem
  init ++ [1,2,3] -> frobnicate init
  init :+ last -> wrangle last
  [] -> 0
```

List are represented as finger trees, so adding elements to the start or end is very fast, and random access using `List.at` is also fast.

IMPORTANT: DO NOT build up lists in reverse order, then call `List.reverse` at the end. Instead just build up lists in order, using `:+` to add to the end.

## Use accumulating parameters and tail recursive functions for looping

Tail recursion is the sole looping construct in Unison. Just write recursive functions, but write them tail recursive with an accumulating parameter. For instance, here is a function for summing a list:

```
Nat.sum : [Nat] -> Nat
Nat.sum ns =
  go acc = cases
    [] -> acc
    x +: xs -> go (acc + x) xs
  go 0 ns
```

IMPORTANT: If you're writing a function on a list, use tail recursion and an accumulating parameter.

CORRECT:

```
List.map : (a ->{g} b) -> [a] ->{g} [b]
List.map f as = 
  go acc = cases
    [] -> acc
    x +: xs -> go (acc :+ f x) xs
  go [] as
```

INCORRECT (not tail recursive):

```
-- DON'T DO THIS 
List.map : (a ->{g} b) -> [a] ->{g} [b]
List.map f = cases
  [] -> []
  x +: xs -> f x +: go xs
```

## Built up lists in order, do not build them up in reverse order and reverse them at the end

Unison lists support O(1) append at the end of the list (they are based on finger trees), so you can just build up the list in order. Do not build them up in reverse order and then reverse at the end.

INCORRECT:

```
List.map : (a ->{g} b) -> [a] ->{g} [b]
List.map f as = 
  go acc = cases
    [] -> List.reverse acc
    x +: xs -> go (f x +: acc) xs
  go [] as
```

CORRECT:

```
List.map : (a ->{g} b) -> [a] ->{g} [b]
List.map f as = 
  go acc = cases
    [] -> acc
    x +: xs -> go (acc :+ f x) xs
  go [] as
```

Note that `:+` appends a value onto the end of a list in constant time, O(1):

```
[1,2,3] :+ 4
=== [1,2,3,4]
```

While `+:` prepends a value onto the beginning of a list, in constant time:

```
0 +: [1,2,3]
=== [0,1,2,3]
```

## Abilities (Algebraic Effects)

Unison has a typed effect system called "abilities" which allows you to specify what effects a function can perform:

```
-- A function with effects
Optional.map : (a ->{g} b) -> Optional a ->{g} Optional b
```

The `{g}` notation represents effects that the function may perform. Effects are propagated through the type system.

### Defining Abilities

You can define your own abilities:

```
ability Exception where
  raise : Failure -> x
```

An ability defines operations that functions can use. In this case, `Exception` has a single operation `raise` that takes a `Failure` and returns any type (allowing it to abort computation).

### Using Abilities

Built-in abilities like `IO` allow for side effects:

```
printLine : Text ->{IO, Exception} ()
```

The type signature shows that `printLine` can use both `IO` and `Exception` abilities.

### Handling Abilities

Ability handlers interpret the operations of an ability:

```
Exception.toEither : '{g, Exception} a ->{g} Either Failure a
Exception.toEither a =
  handle a()
  with cases
    { a } -> Right a
    { Exception.raise f -> resume } -> Left f
```

Handlers can transform one ability into another or eliminate them entirely.

### Ability Handler Style Guidelines

When implementing ability handlers, follow these style guidelines:

1. Use `go` or `loop` as the conventional name for recursive helper functions in handlers
2. Keep handler state as function arguments rather than using mutable state
3. For recursive handlers that resume continuations, structure them like this:

```
Stream.map : (a ->{g} b) -> '{Stream a, g} () -> '{Stream b, g} ()
Stream.map f sa = do
  go = cases
    { () } -> ()
    { Stream.emit a -> resume } ->
      Stream.emit (f a)
      handle resume() with go

  handle sa() with go
```

4. Inline small expressions that are used only once rather than binding them to variables:

```
-- Prefer this:
Stream.emit (f a)

-- Over this:
b = f a
Stream.emit b
```

5. Use `do` instead of `'` within function bodies to create thunks

## Effect and State Management

Handlers with state often use recursion:

```
Stream.toList : '{g, Stream a} () ->{g} [a]
Stream.toList sa =
  go acc req = match req with
    { () } -> acc
    { Stream.emit a -> resume } ->
      handle resume() with go (acc :+ a)
  handle sa() with go []
```

A common convention is to use `acc'` (with an apostrophe) to name the updated version of an accumulator variable.

## Record Types

Record types in Unison are defined as:

```
type Employee = { name : Text, age : Nat }
```

This generates accessor functions and updaters:

- `Employee.name : Employee -> Text`
- `Employee.age : Employee -> Nat`
- `Employee.name.set : Text -> Employee -> Employee`
- `Employee.age.modify : (Nat -> Nat) -> Employee -> Employee`

Example usage:

```
doubleAge : Employee -> Employee
doubleAge e = Employee.age.modify (n -> n * 2) e
```

### Important: Record Access Syntax

A common mistake is to try using dot notation for accessing record fields. In Unison, record field access is done through the generated accessor functions:

```
-- INCORRECT: ring.zero
-- CORRECT:
Ring.zero ring
```

Record types in Unison generate functions, not special field syntax.

## Namespaces and Imports

Unison uses a flat namespace with dot notation to organize code. You can import definitions using `use`:

```
use List map filter

-- Now you can use map and filter without qualifying them
evens = filter Nat.isEven [1,2,3,4]
incremented = map Nat.increment (range 0 100)
```

A wildcard import is also available:

```
use List  -- Imports all List.* definitions
```

## Collection Operations

List patterns allow for powerful matching:

```
-- Match first element of list
a +: as

-- Match last element of list
as :+ a

-- Match first two elements plus remainder
[x,y] ++ rem
```

Example implementation of `List.map`:

```
List.map : (a ->{g} b) -> [a] ->{g} [b]
List.map f as =
  go acc rem = match rem with
    [] -> acc
    a +: as -> go (acc :+ f a) as
  go [] as
```

### List Functions and Ability Polymorphism

Remember to make list functions ability-polymorphic if they take function arguments. This allows the function passed to operate with effects:

```
-- CORRECT: Ability polymorphic
List.map : (a ->{g} b) -> [a] ->{g} [b]

-- INCORRECT: Not ability polymorphic
List.map : (a -> b) -> [a] -> [b]
```

## Pattern Matching with Guards

Guards allow for conditional pattern matching:

```
List.filter : (a -> Boolean) -> [a] -> [a]
List.filter p as =
  go acc rem = match rem with
    [] -> acc
    a +: as | p a -> go (acc :+ a) as
            | otherwise -> go acc as
  go [] as
```

### Guard Style Convention

When using multiple guards with the same pattern, align subsequent guards vertically under the first one, not repeating the full pattern:

```
-- CORRECT:
a +: as | p a -> go (acc :+ a) as
        | otherwise -> go acc as

-- INCORRECT:
a +: as | p a -> go (acc :+ a) as
a +: as | otherwise -> go acc as
```

## Block Structure and Binding

In Unison, the arrow `->` introduces a block, which can contain multiple bindings followed by an expression:

```
-- A block with a helper function
dotProduct ring xs ys =
  go acc xsRem ysRem = match (xsRem, ysRem) with
    ([], _) -> acc
    (_, []) -> acc
    (x +: xs, y +: ys) ->
      nextAcc = Ring.add ring acc (Ring.mul ring x y)
      go nextAcc xs ys
  go (Ring.zero ring) xs ys
```

### Important: No `let` Keyword

Unison doesn't use a `let` keyword for bindings within blocks. Simply write the name followed by `=`:

```
-- CORRECT:
nextAcc = Ring.add ring acc (Ring.mul ring x y)

-- INCORRECT:
let nextAcc = Ring.add ring acc (Ring.mul ring x y)
```

### No `where` Clauses

Unison doesn't have `where` clauses. Helper functions must be defined in the main block before they're used.

```
-- CORRECT: declare the helper function, then use it later in the block
filterMap : (a ->{g} Optional b) -> [a] ->{g} [b]
filterMap f as = 
  go acc = cases
    [] -> acc
    (hd +: tl) -> match f hd with
      None -> go acc tl
      Some b -> go (acc :+ b) tl
  go [] as

-- INCORRECT
filterMap : (a ->{g} Optional b) -> [a] ->{g} [b]
filterMap f as = go [] as 
  where
  go acc = cases
    [] -> acc
    (hd +: tl) -> match f hd with
      None -> go acc tl
      Some b -> go (acc :+ b) tl
  go [] as
```

## Error Handling

Unison uses the `Exception` ability for error handling:

```
type Failure = Failure Link.Type Text Any

-- Raising an exception
Exception.raise (Failure (typeLink Generic) "An error occurred" (Any 42))

-- Catching specific exceptions
Exception.catchOnly : Link.Type -> '{g, Exception} a ->{g, Exception} Either Failure a
```

## Text Handling

Unison calls strings `Text` and uses concatenation with `++`:

```
greeting = "Hello, " Text.++ name
```

You can use `use Text ++` to use `++` without qualification:

```
use Text ++
greeting = "Hello, " ++ name
```

### No String Interpolation

Unlike many modern languages, Unison doesn't have string interpolation. Text concatenation with `++` is the primary way to combine text values.

## The Pipeline Operator `|>`

Unison provides the `|>` operator for creating pipelines of transformations. The expression `x |> f` is equivalent to `f x`. This is particularly useful for composing multiple operations in a readable left-to-right flow:

```
use Nat *
use List filter sum map

-- Calculate the sum of odd numbers after multiplying each by 10
processNumbers : [Nat] -> Nat
processNumbers numbers =
  numbers
    |> map (x -> x * 10)   -- Multiply each number by 10
    |> filter Nat.isOdd    -- Keep only odd numbers
    |> sum                 -- Sum all remaining numbers

-- Using the function with numbers 1 through 100
result =
  range 1 101            -- Create a list from 1 to 100 (inclusive)
    |> processNumbers      -- Apply our processing function
```

This style makes the code more readable by placing the data first and showing each transformation step in sequence, similar to the pipe operator in languages like Elm, F#, or Elixir.

## Writing documentation

Documentation blocks appear just before a function or type definition. They look like so:

````
{{
``List.map f xs`` applies the function `f` to each element of `xs`.

# Examples

```
List.map Nat.increment [1,2,3]
```

```
List.map (x -> x * 100) (range 0 10)
```
}}
List.map f xs = 
  go acc = cases
    [] -> acc
    hd +: tl -> go (acc :+ f hd) tl
  go [] xs
````

## Type System Without Typeclasses

Unison doesn't have typeclasses. Instead, it uses explicit dictionary passing:

```
type Ring a =
  { zero : a
  , one : a
  , add : a -> a -> a
  , mul : a -> a -> a
  , neg : a -> a
  }

dotProduct : Ring a -> [a] -> [a] -> a
dotProduct ring xs ys =
  go acc xsRem ysRem = match (xsRem, ysRem) with
    ([], _) -> acc
    (_, []) -> acc
    (x +: xs, y +: ys) ->
      nextAcc = Ring.add ring acc (Ring.mul ring x y)
      go nextAcc xs ys
  go (Ring.zero ring) xs ys
```

## Program Entry Points

Main functions in Unison can have any name:

```
main : '{IO, Exception} ()
main = do printLine "hello, world!"
```

The syntax `'{IO, Exception} ()` is sugar for `() ->{IO, Exception} ()`, representing a thunk that can use the `IO` and `Exception` abilities.

UCM (Unison Codebase Manager) is used to run or compile programs:

```
# Run directly
run main

# Compile to bytecode
compile main out

# Run compiled bytecode
ucm run.compiled out.uc
```

## Testing

Unison has built-in testing support:

```
test> Nat.tests.props = test.verify do
  Each.repeat 100
  n = Random.natIn 0 1000
  m = Random.natIn 0 1000
  labeled "addition is commutative" do 
    ensureEqual (n + m) (m + n)
  labeled "zero is an identity for addition" do
    ensureEqual (n + 0) (0 + n)
  labeled "multiplication is commutative" do
    ensureEqual (n * m) (m * n)
```

REQUIREMENT: Tests for a function or type `foo` should always be named `foo.tests.<test-name>`.

## Lazy Evaluation

Unison is strict by default. Laziness can be achieved using `do` (short for "delayed operation", NOT the same as Haskell's `do` keyword): 

```
-- Inside a function, use do
nats : '{Stream Nat} ()
nats = do 
  Stream.emit 1
  Stream.emit 2
  Stream.emit 3
```

You can use `(do someExpr)` to put a delayed computation anywhere you want (say, as the argument to a function), or if a `do` is the last argument to a function, you can leave off the parentheses:

PREFERRED: 

```
forkAt node2 do
  a = 1 + 1
  b = 2 + 2
  a + b
```

### Strict evaluation

- **Delayed operations must be forced.** Many Unison functions return delayed operations (e.g. `'{Route, ...} ()`). Simply binding them (`_ = someFn ...`) does **not** execute them. When writing side-effectful code, remember to force evaluate delayed opeations with `()` or `!` (e.g. `someFn ... ()` or `!someFn ...`). If you don’t, the effect may silently never run.

## Standard Library

Unison's standard library includes common data structures:

- `List` for sequences
- `Map` for key-value mappings
- `Set` for unique collections
- `Pattern` for regex matching

## Additional Resources

- Unison docs on regex patterns: https://share.unison-lang.org/@unison/base/code/main/latest/types/Pattern
- Testing documentation: https://share.unison-lang.org/@unison/base/code/main/latest/terms/test/verify
