Unison Project Name: `turbo`
Reference Unison Project (read-only): `cuts`

# Purpose

This file contains the Unison-specific workflow and process rules for this repo.

For the Unison language guide and syntax reference, use:

- [`UNISON_LANGUAGE.md`](/Users/mau/Development/Turbo/UNISON_LANGUAGE.md)

# Workflow

IMPORTANT: For Unison syntax and semantics, treat [`UNISON_LANGUAGE.md`](/Users/mau/Development/Turbo/UNISON_LANGUAGE.md) as authoritative.

## WHERE TO PUT CODE and how to typecheck it

Any time you are writing code, place it in a scratch file, `foo.u` (pick an appropriate file name based on the task).

As you are iterating, directly edit the file you've created. Use the MCP server to typecheck the file and run test> watch expressions. Do not pass large strings to the Unison MCP typechecking command.

You can show excerpts of the scratch file as needed when asking for help or review.

You are not finished with a task until the scratch file you are working on compiles.

## Design maxims (Functional Programming)

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

# Modes

## DISCOVERY mode instructions

1. Search for relevant libraries on Unison Share using the share-project-search MCP command.
2. For each promising library, you may read its README with the share-project-readme MCP command.
3. If it seems relevant, provide the link and ask whether to install it.

After installing it, ask whether to enter LEARN mode for that library.

## LEARNING mode instructions

### LEARNING (the current library)

1. Say that you're learning about the current library.
2. Use `docs` to view the current library README. It may be called `Readme` instead of `README`.
3. Use `list-project-definitions` to inspect function signatures.
4. Use LEARNING (single definition) as needed.

Work breadth-first, and do not invoke LEARNING (single definition) more than 30 times in one pass.

### LEARNING (another library)

1. Confirm the project branch you are checking.
2. Use `list-project-libraries` to see installed libraries.
3. Use `docs` to read the library README by fully qualified name.
4. Use `list-library-definitions` to inspect function signatures.
5. Use LEARNING (single definition) as needed.

Work breadth-first, and do not invoke LEARNING (single definition) more than 30 times in one pass.

### LEARNING (single definition)

1. Say that you are reading its docs, source, and dependency/dependent graph as needed.
2. Use `docs` to read documentation.
3. Optionally use `view-definitions` to inspect source.
4. Optionally use `list-definition-dependencies`.
5. Optionally use `list-definition-dependents`.

## BASIC mode instructions

### BASIC mode, step 1: before writing any code

1. If code involves new data types or abilities, confirm the data declarations first.
2. Confirm type signatures before generating any code.
3. If possible, suggest a few simple input/output examples and add them as commented-out `test>` watch expressions once confirmed.

Do not proceed until the declarations and signatures are confirmed unless explicitly told to skip that step.

### BASIC mode, step 2: see if similar functions exist

If the function may already exist, you may search locally or on Unison Share after the signature is confirmed.

If you find a similar function, show it and ask whether to use it or continue with a new implementation.

### BASIC mode, step 3: implementation

Implement using either:

- `1-SHOT`
- `USER-GUIDED`

Code must typecheck before it is shown.

#### BASIC mode: the 1-SHOT strategy

If the task looks simple, implement it directly, typecheck it, and make sure tests pass.

Then ask for feedback.

If repeated attempts fail, restart with the USER-GUIDED strategy.

#### BASIC mode: the USER-GUIDED strategy

Keep tests commented out while scaffolding:

1. Write a skeleton implementation with shallow pattern matching and `todo 1`, `todo 2`, etc.
2. Show only code that typechecks.
3. Ask which `todo` to fill next.
4. If stuck after several attempts, stop and show the previous typechecking version.
5. When the implementation is complete, ask for feedback.
6. After approval, uncomment tests and make them pass.

## DEEP WORK mode

Use this mode for larger or underspecified tasks. Do not plow ahead. First agree on design, signatures, tests, and implementation strategy.

### DEEP WORK, step 1: gather requirements

Produce:

- data declarations
- ability declarations
- function signatures
- test cases where applicable
- brief implementation notes

Ask focused questions one at a time. Prefer yes/no questions. Keep iterating until the requirements set is complete, then summarize and ask for approval.

### DEEP WORK, mandatory checkpoint

After requirements gathering, you MUST:

1. State `DEEP WORK Step 1 complete`
2. Present the requirements summary
3. Ask: `Do you approve this design? Should I proceed to Step 2: Implementation?`
4. Wait for explicit approval before continuing

### DEEP WORK, step 2: implementation

1. Write and typecheck data declarations and ability declarations first.
2. Add agreed signatures with `todo` implementations.
3. Fill in one definition at a time.
4. Do not start the next definition until the current one typechecks.
5. End with no todos, typechecking code, and passing tests.

Use helper functions when needed. Put helpers for `foo` under `foo.internal.*` by default. Put generic utilities in `util`.

If requirements become unclear, return to step 1.

## DOCUMENTING mode

Use this mode to add documentation for definitions. Do not enter it without consent.

Follow:
- Always add `.doc` definitions explaining in advanced engineering speak what the function does, keep it short, descriptive, and concise (high information density OK).
- The documentation guidance in `.agents/writing-unison-documentation.md`
- For all functions and stateful/domain types, explicitly document:
  - preconditions (with tests)
  - postconditions (with tests)
  - invariants (with tests)
  - important edge cases and failure modes

### DOCUMENTATION RULES

* Use term links like {List.map} for definitions.
* Use type links like {type Map} for data types and abilities.
* Only reference real definitions that exist.
* Prefer making behavioral contracts explicit in docs instead of relying on callers to infer them from implementation details.

### Documentation and testing expectations


## TESTING mode

Read `.agents/testing.md` and follow it.

Tests for a function or type `foo` should be named `foo.tests.<test-name>`.

Always use the built-in Unison testing style, not ad hoc checks.
Always include example tests and property-based tests for core pure logic where appropriate.

Prefer:
- example tests for concrete behavior
- property-based tests for core pure logic
- `test.verify` with `Each`, `Random`, and labeled subtests
- properties that exercise documented preconditions, postconditions, and invariants when those contracts are part of the behavior

When a function is too stateful or effectful for property tests, say so and add the strongest example or I/O tests that fit.

# Implementation Rules

## Important rules

- NEVER generate code before confirming the type signature.
- NEVER start searching for definitions before the signature is confirmed.
- When showing code with todos, show it in a markdown block or article form.
- When asking a question, preface it with *Question:* and put it at the bottom.

## Tips and tricks during implementation

### Looking up documentation and source code

Use MCP docs/source queries when you are unsure about a function, type, or API.

### Using watch expressions effectively

Use `>` watch expressions to explore behavior.

Do NOT use them for tests. Tests should always be `test>` watch expressions.

## REQUIREMENT: do a code cleanup pass

After code typechecks:

- remove needless `use` clauses
- prefer shorter unique names when they are clear
- consider eta reduction when it improves clarity

## REQUIREMENTS: code you write must typecheck

Any code written on the user's behalf must live in a scratch file and be typechecked with the Unison MCP server.

You are not done until the scratch file typechecks.

# References

## Looking up documentation

When unsure about Unison 1.0.0 behavior, prefer official documentation over repeated trial-and-error.

Official sources:

- Unison Lang Docs (Main): https://www.unison-lang.org/docs/
- Unison Lang Language Fundamentals: https://www.unison-lang.org/docs/#language-fundamentals
- Unison Lang Language Reference: https://www.unison-lang.org/docs/#language-reference
- Unison Codebase Management: https://www.unison-lang.org/docs/#unison-codebase-management
- Unison Cloud Docs (Main): https://www.unison.cloud/docs/core-concepts/
- Unison Cloud Schema Modeling (OrderedTable): https://www.unison.cloud/docs/tutorials/schema-modeling/
- OrderedTable API Docs: https://share.unison-lang.org/@unison/cloud/code/main/latest/terms/durable/OrderedTable/doc
- Unison Cloud Local Development: https://www.unison.cloud/docs/local-development/
- Unison Share Package repository: https://share.unison-lang.org/
- Unison Transcripts: https://www.unison-lang.org/docs/tooling/transcripts/

Offline sources:

- `.agents/unison-abilities-guide.md`
- `.agents/unison-cloud-guide.md`
- `.agents/unison-concurrency-guide.md`
- `.agents/unison-context.md`
- `.agents/writing-unison-documentation.md`

## Transcripts (when and how to use)

Use transcripts to capture repeatable UCM workflows when the steps are destructive, multi-step, or likely to be reused.

Guidelines:

- Put transcript files at repo root.
- Include a short header explaining what the transcript does.
- Keep each UCM block minimal.
- Run transcripts via the Unison tooling.
