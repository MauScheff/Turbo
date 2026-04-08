# General guidelines
- Don't write tests that reassert the obvious, think edge cases and funcion solution space coverage.
  For example, for a sum function, don't write 1 + 1 == 2. 
  Instead use fuzzy testing (Uxnison), test business logic, or don't write a test when it's obvious.

# Unison Testing guidelines

- Tests are just regular terms. Convention is to place tests under
  `foo.tests.*` so you can run `test foo.tests` and keep tests next to
  what they exercise.
- Pure tests are `test>` watch expressions. I/O tests are normal terms
  that start with `do` and call `test.verify` inside.
- Naming convention: tests for a definition `foo` should be named
  `foo.tests.<test-name>`.

### Key functions and abilities

- `test.verify` — runs a test and returns `[test.Result]`.
- `ensureEqual` — asserts equality.
- `ensure` — asserts a `Boolean`.
- `ensuring` — lazily asserts a `Boolean`.
- `labeled` — adds a label to a test.
- `Each` — used to repeat randomized test cases.
- `Random` — used to generate random inputs.
- `test.arbitrary.nats` — provides random nats.
- `Random.natIn` — random Nat in a range.
- `Random.listOf` — random list of elements.

### Property-based testing pattern

```
 test> foo.tests.someProperty =
   test.verify do
     Each.repeat 200
     n = Random.natIn 0 100
     ensureEqual true (foo n)
```

### Practical guidance

- Prefer pure tests unless the function requires `IO`.
- Typecheck each test as it’s written.
- Keep tests small and focused; use `labeled` for multi-assertion tests.

## Flutter testing guidelines

- We do not test UI widgets or visual layout in this project.
- Prefer unit tests for pure helpers, DTO parsing, and business rules.
- Avoid golden tests and widget tests unless explicitly requested.
- Keep tests fast and deterministic.

