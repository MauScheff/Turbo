# Writing Unison Documentation

This guide covers how to write documentation for Unison code using Unison's unique documentation syntax.

## Documentation Block Syntax

Unison uses `{{ }}` for documentation blocks that appear **BEFORE** the definition:

````
{{
``List.map f xs`` applies the function `f` to each element of `xs`.

# Examples

```
List.map Nat.increment [1,2,3]
==> [2,3,4]
```

```
List.map (x -> x * 100) (range 0 10)
```
}}
List.map : (a ->{g} b) -> [a] ->{g} [b]
List.map f xs =
  go acc = cases
    [] -> acc
    hd +: tl -> go (acc :+ f hd) tl
  go [] xs
````

## Documentation Features

### Inline Code
Use single backticks for inline code references:
- `` `List.map` `` - references a function name
- `` `xs` `` - references a parameter

### Function Signatures in Examples
Use double backticks to show function application examples:
- ``` ``List.map f xs`` ``` - shows example usage with arguments

### Markdown Support
Documentation blocks support standard markdown:
- `# Headers` for sections (use `#` for main sections, `##` for subsections)
- `*` or `-` for bullet lists
- `**bold**` and `*italic*` text
- Code blocks with triple backticks

### Code Examples
Use triple backticks for code examples:

````
```
List.filter Nat.isEven [1,2,3,4,5,6]
==> [2,4,6]
```
````

You can show expected results using `==>`:

````
```
1 + 1
==> 2
```
````

## Documentation Structure

### Minimal Documentation (One-liner)
For simple, obvious functions:

```
{{
``List.reverse xs`` returns a new list with elements in reverse order.
}}
List.reverse : [a] -> [a]
List.reverse xs = ...
```

### Full Documentation (With Examples)
For more complex or non-obvious functions:

````
{{
``List.foldLeft f acc xs`` reduces the list `xs` from left to right using the function `f` and initial accumulator `acc`.

The function `f` takes the current accumulator and the next element, producing a new accumulator value.

# Examples

```
List.foldLeft (Nat.+) 0 [1,2,3,4]
==> 10
```

```
List.foldLeft (acc elem -> acc :+ elem * 2) [] [1,2,3]
==> [2,4,6]
```

# Performance

This function is tail recursive and processes the list in a single pass.
}}
List.foldLeft : (acc -> a ->{g} acc) -> acc -> [a] ->{g} acc
List.foldLeft f acc xs = ...
````

### Documenting Types

For type definitions, explain what the type represents and how to use it:

````
{{
An `Optional` value represents a computation that might fail or a value that might be absent.

# Constructors

- `None` - represents absence of a value
- `Some a` - wraps a value of type `a`

# Examples

```
safeDivide : Nat -> Nat -> Optional Nat
safeDivide n m =
  if m == 0 then None
  else Some (n / m)
```
}}
type Optional a = None | Some a
````

### Documenting Abilities

Document abilities by explaining what operations they provide:

````
{{
The `Exception` ability allows functions to raise failures that can be caught and handled by ability handlers.

# Operations

- ``Exception.raise failure`` - raises a failure and aborts the current computation

# Example

```
parseNat : Text ->{Exception} Nat
parseNat txt =
  match Nat.fromText txt with
    None -> Exception.raise (Failure (typeLink Generic) "Invalid number" (Any txt))
    Some n -> n
```
}}
ability Exception where
  raise : Failure -> x
````

## When to Write Documentation

### Always Document
- Public API functions
- Type definitions (especially abilities)
- Ability handlers
- Complex algorithms with non-obvious behavior

### Optional Documentation
- Simple, self-explanatory helper functions
- Internal implementation details
- Functions with very obvious behavior from their name and type

## Doc Style Guidelines

### Start with a Summary
Begin with a one-line summary that uses backticks for the function signature:

```
``List.map f xs`` applies the function `f` to each element of `xs`.
```

### Use Active Voice
❌ "Elements are transformed by the function"
✅ "Transforms each element using the function"

### Describe Parameters When Non-Obvious
If parameter names or purpose aren't clear from the type signature:

```
{{
``findIndex predicate xs`` returns the index of the first element satisfying `predicate`.

Returns `None` if no element matches.

# Parameters
- `predicate` - a function that returns `true` for the desired element
- `xs` - the list to search

# Examples
...
}}
```

### Note Edge Cases
Document special behavior or edge conditions:

```
{{
``List.head xs`` returns the first element of the list.

Returns `None` if the list is empty.
}}
```

### Include Performance Notes When Relevant
For functions where performance characteristics matter:

```
{{
``List.at index xs`` returns the element at the given index.

# Performance
Random access is O(log n) due to the finger tree implementation.
}}
```

## Common Patterns

### Documenting Operators

```
{{
``xs ++ ys`` concatenates two lists.

# Examples

```
[1,2,3] ++ [4,5,6]
==> [1,2,3,4,5,6]
```
}}
(++) : [a] -> [a] -> [a]
```

### Documenting Higher-Order Functions

```
{{
``List.filter predicate xs`` returns a new list containing only elements that satisfy `predicate`.

# Examples

```
List.filter Nat.isEven [1,2,3,4,5,6]
==> [2,4,6]
```

```
List.filter (x -> x > 10) [5,10,15,20]
==> [15,20]
```
}}
```

### Documenting Effectful Functions

```
{{
``printLine text`` prints the text to standard output followed by a newline.

This function requires the `IO` ability.
}}
printLine : Text ->{IO, Exception} ()
```

## Viewing Documentation

You can view documentation using the Unison MCP server:
- `mcp__unison__docs` with the function name to fetch documentation

Or in UCM (Unison Codebase Manager):
```
.> docs List.map
```

## Tips

1. Write docs as you write code - it's easier than retrofitting later
2. Good examples are worth more than lengthy prose
3. Keep examples realistic and runnable
4. Update docs when you change function behavior
5. Use the documentation to think through edge cases
