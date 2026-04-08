# Unison documentation notes (project summary)

This file summarizes the documentation conventions used in this codebase.

## General rules

- Documentation is a `Doc` term named `foo.doc` placed immediately before `foo`.
- Use proper term/type links: `{Foo.bar}` or `{type Foo}` (not backticks).
- Provide short, practical examples. Let examples stand on their own.
- Include a brief *Also see:* list linking to related definitions.
- Add implementation notes only if they clarify performance or behavior.

## Pure functions

Use a `{{ ... }}` doc block with:

1. A short description using inline example, e.g. ``foo x``.
2. One or more examples (including edge cases if relevant).
3. *Also see:* links.
4. Optional `# Implementation notes`.

## I/O functions (simple usage)

Use `@typecheck` blocks for examples:

```
@typecheck ```
example : ...
example = foo ...
```
```

## I/O functions (complex usage)

For longer examples:

- Define `foo.doc.example` with the I/O workflow.
- Use `@source{foo.doc.example}` or `@foldedSource{...}`.
- Show how to run and the output.

## Common gotchas

- Avoid ambiguous short names in docs; qualify when needed
  (e.g., `cuts.store.userPlanState.put`).
- Avoid backticked identifiers for links; use `{}` links instead.
- If an example is in a doc block, ensure it typechecks.

