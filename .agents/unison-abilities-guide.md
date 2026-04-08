## Unison Abilities Guide

This guide covers Unison's typed effect system called "abilities" (also known as algebraic effects). Abilities allow you to specify and handle computational effects in a type-safe way.

## What are Abilities?

Unison has a typed effect system called "abilities" which allows you to specify what effects a function can perform:

```
-- A function with effects
Optional.map : (a ->{g} b) -> Optional a ->{g} Optional b
```

The `{g}` notation represents effects that the function may perform. Effects are propagated through the type system. This means if a function calls another function with effects, those effects must appear in the calling function's type signature.

## Defining Abilities

You can define your own abilities:

```
ability Exception where
  raise : Failure -> x
```

An ability defines operations that functions can use. In this case, `Exception` has a single operation `raise` that takes a `Failure` and returns any type (allowing it to abort computation).

### Multiple Operations

An ability can define multiple operations:

```
ability State s where
  get : s
  put : s -> ()
```

This `State` ability provides two operations: `get` to retrieve the current state, and `put` to update it.

## Using Abilities

Built-in abilities like `IO` allow for side effects:

```
printLine : Text ->{IO, Exception} ()
```

The type signature shows that `printLine` can use both `IO` and `Exception` abilities.

### Ability Polymorphism

Functions can be polymorphic over abilities using ability variables:

```
-- This function works with any abilities g
List.map : (a ->{g} b) -> [a] ->{g} [b]
```

The `{g}` means the function can have any effects that the argument function `f` has. This is crucial for higher-order functions.

## Handling Abilities

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

### How Handlers Work

When you use `handle ... with cases`, you're pattern matching on the different ways a computation can proceed:

1. **Pure case** `{ a }` - the computation completed successfully with value `a`
2. **Effect case** `{ AbilityOp args -> resume }` - the computation called an ability operation

The `resume` continuation represents "the rest of the computation" after the ability operation.

## Ability Handler Style Guidelines

When implementing ability handlers, follow these style guidelines:

### 1. Use Conventional Names

Use `go` or `loop` as the conventional name for recursive helper functions in handlers:

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

### 2. Keep Handler State as Function Arguments

Rather than using mutable state, pass state as function arguments:

```
Stream.toList : '{g, Stream a} () ->{g} [a]
Stream.toList sa =
  go acc req = match req with
    { () } -> acc
    { Stream.emit a -> resume } ->
      handle resume() with go (acc :+ a)
  handle sa() with go []
```

### 3. Structure for Recursive Handlers

For recursive handlers that resume continuations, structure them like this:

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

### 4. Inline Small Expressions

Inline small expressions that are used only once rather than binding them to variables:

```
-- Prefer this:
Stream.emit (f a)

-- Over this:
b = f a
Stream.emit b
```

### 5. Use `do` for Thunks in Function Bodies

Use `do` instead of `'` within function bodies to create thunks:

```
-- In function bodies, use do:
Stream.map f sa = do
  go = cases
    ...
```

## Effect and State Management

Handlers with state often use recursion to thread state through the computation:

```
Stream.toList : '{g, Stream a} () ->{g} [a]
Stream.toList sa =
  go acc req = match req with
    { () } -> acc
    { Stream.emit a -> resume } ->
      handle resume() with go (acc :+ a)
  handle sa() with go []
```

### Naming Convention for Accumulators

A common convention is to use `acc'` (with an apostrophe) to name the updated version of an accumulator variable:

```
go acc = cases
  { () } -> acc
  { SomeOp x -> resume } ->
    acc' = updateAccumulator acc x
    handle resume() with go acc'
```

## Common Ability Patterns

### The Exception Ability

Used for error handling:

```
ability Exception where
  raise : Failure -> x

-- Using it:
safeDivide : Nat -> Nat ->{Exception} Nat
safeDivide n m =
  if m == 0 then
    Exception.raise (Failure (typeLink Generic) "Division by zero" (Any ()))
  else
    n / m

-- Handling it:
Exception.toEither : '{g, Exception} a ->{g} Either Failure a
```

### The State Ability

For stateful computations:

```
ability State s where
  get : s
  put : s -> ()

-- Example: counting
countEvens : [Nat] ->{State Nat} ()
countEvens = cases
  [] -> ()
  x +: xs ->
    if Nat.isEven x then
      count = State.get
      State.put (count + 1)
    else ()
    countEvens xs
```

### Stream-like Abilities

For producer/consumer patterns:

```
ability Stream a where
  emit : a -> ()

-- Transforming streams:
Stream.map : (a ->{g} b) -> '{Stream a, g} () -> '{Stream b, g} ()
Stream.map f sa = do
  go = cases
    { () } -> ()
    { Stream.emit a -> resume } ->
      Stream.emit (f a)
      handle resume() with go
  handle sa() with go

-- Collecting streams:
Stream.toList : '{g, Stream a} () ->{g} [a]
Stream.toList sa =
  go acc = cases
    { () } -> acc
    { Stream.emit a -> resume } ->
      handle resume() with go (acc :+ a)
  handle sa() with go []
```

## Key Takeaways

1. **Abilities are types** - They appear in type signatures with `{AbilityName}`
2. **Abilities are polymorphic** - Use `{g}` for ability-polymorphic functions
3. **Handlers eliminate abilities** - Transform effectful code to pure code
4. **Resume is a continuation** - It represents "the rest of the computation"
5. **State via recursion** - Thread state through recursive handler calls
6. **Use conventional names** - `go` for recursive helpers, `acc` for accumulators

## Further Reading

For more advanced topics and edge cases, consult the authoritative language reference via MCP:
- Use `unison-context.md` to find the relevant docs
- Query `@unison/website` project's `docs.languageReference.abilitiesAndAbilityHandlers`

