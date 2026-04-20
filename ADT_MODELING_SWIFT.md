# Modeling Algebraic Data Types (ADTs) in Swift

This guide defines clear rules and patterns for representing Algebraic
Data Types (ADTs) in Swift in a consistent, idiomatic way.

------------------------------------------------------------------------

1. Core Concepts

ADTs are composed of:

-   Sum types → “one of many”
-   Product types → “combination of values”

Swift maps these concepts to:

  ADT Concept    Swift Construct
  -------------- -----------------
  Sum Type       enum
  Product Type   struct

------------------------------------------------------------------------

2. Sum Types (Enums with Associated Values)

Rule: Use enum with associated values for any type that can be one of
several variants.

Example:

enum Result { case success(Value) case failure(Error) }

Always handle with exhaustive switch:

switch result { case .success(let value): // handle success case
.failure(let error): // handle error }

Guidelines: - Prefer enums over class hierarchies for closed sets -
Model invalid states as impossible - Use associated values instead of
optional fields

------------------------------------------------------------------------

3. Product Types (Structs)

Rule: Use struct to combine multiple values.

Example:

struct User { let id: Int let name: String }

Guidelines: - Prefer struct over class - Keep properties immutable
(let) - Use clear naming

------------------------------------------------------------------------

4. Recursive Types

Use indirect enum:

indirect enum Tree { case empty case node(left: Tree, value: T, right:
Tree) }

------------------------------------------------------------------------

5. Composition

Example:

indirect enum Expr { case number(Int) case add(Expr, Expr) case
multiply(Expr, Expr) }

------------------------------------------------------------------------

6. Optional (Built-in ADT)

enum Optional { case none case some(Wrapped) }

------------------------------------------------------------------------

7. When NOT to Use Enums

Use protocols if you need extensibility:

protocol Shape { func area() -> Double }

------------------------------------------------------------------------

8. Enum vs Protocol

Enum: - Exhaustive - Closed

Protocol: - Extensible - Open

------------------------------------------------------------------------

9. Design Principles

Make invalid states unrepresentable:

Good:

enum Payment { case cash case card(number: String) }

Bad:

struct Payment { let isCash: Bool let cardNumber: String? }

------------------------------------------------------------------------

10. Checklist

-   One of many → enum
-   Combination → struct
-   Recursive → indirect enum
-   Extensible → protocol

------------------------------------------------------------------------

11. Mental Model

AND → struct
OR → enum

------------------------------------------------------------------------

12. Summary

-   enum = Sum type
-   struct = Product type
-   indirect enum = Recursive
-   protocol = Extensible fallback

