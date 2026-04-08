USE THIS FILE AS A MAP FOR FINDING UNISON LANGUAGE DOCS VIA MCP.

# Unison Context (Authoritative Docs via MCP)

## Source of Truth
- The Unison MCP server is authoritative for language details.
- The language reference lives in the Unison codebase project `@unison/website`,
  under the `docs.languageReference.*` namespace.
- This file is only a quick index on how to fetch those docs.

## Project Context
- Project: `@unison/website`
- Branch: `main`
- Language reference namespace: `docs.languageReference.*`

## How to Read the Language Reference (MCP)
1. Use `mcp__unison__search-definitions-by-name` with query `docs.languageReference`.
2. Choose the specific doc term you need.
3. Use `mcp__unison__view-definitions` to read it.

## Language Reference Index (from `docs.languageReference._sidebar`)
This list is a map of where to look. The content lives in the doc terms.

- `docs.languageReference.topLevelDeclaration`
- `docs.languageReference.termDeclarations`
- `docs.languageReference.typeSignatures`
- `docs.languageReference.termDefinition`
- `docs.languageReference.operatorDefinitions`
- `docs.languageReference.abilityDeclaration`
- `docs.languageReference.userDefinedDataTypes`
- `docs.languageReference.structuralTypes`
- `docs.languageReference.uniqueTypes`
- `docs.languageReference.recordType`
- `docs.languageReference.expressions`
- `docs.languageReference.basicLexicalForms`
- `docs.languageReference.identifiers`
- `docs.languageReference.nameResolutionAndTheEnvironment`
- `docs.languageReference.blocksAndStatements`
- `docs.languageReference.literals`
- `docs.languageReference.documentationLiterals`
- `docs.languageReference.escapeSequences`
- `docs.languageReference.comments`
- `docs.languageReference.typeAnnotations`
- `docs.languageReference.parenthesizedExpressions`
- `docs.languageReference.functionApplication`
- `docs.languageReference.syntacticPrecedenceOperatorsPrefixFunctionApplication`
- `docs.languageReference.booleanExpressions`
- `docs.languageReference.delayedComputations`
- `docs.languageReference.syntacticPrecedence`
- `docs.languageReference.destructuringBinds`
- `docs.languageReference.matchExpressionsAndPatternMatching`
- `docs.languageReference.blankPatterns`
- `docs.languageReference.literalPatterns`
- `docs.languageReference.variablePatterns`
- `docs.languageReference.asPatterns`
- `docs.languageReference.constructorPatterns`
- `docs.languageReference.listPatterns`
- `docs.languageReference.tuplePatterns`
- `docs.languageReference.abilityPatterns`
- `docs.languageReference.guardPatterns`
- `docs.languageReference.hashes`
- `docs.languageReference.types`
- `docs.languageReference.typeVariables`
- `docs.languageReference.polymorphicTypes`
- `docs.languageReference.scopedTypeVariables`
- `docs.languageReference.typeConstructors`
- `docs.languageReference.kindsOfTypes`
- `docs.languageReference.typeApplication`
- `docs.languageReference.functionTypes`
- `docs.languageReference.tupleTypes`
- `docs.languageReference.builtInTypes`
- `docs.languageReference.builtInTypeConstructors`
- `docs.languageReference.userDefinedTypes`
- `docs.languageReference.unit`
- `docs.languageReference.abilitiesAndAbilityHandlers`
- `docs.languageReference.abilitiesInFunctionTypes`
- `docs.languageReference.theTypecheckingRuleForAbilities`
- `docs.languageReference.userDefinedAbilities`
- `docs.languageReference.abilityHandlers`
- `docs.languageReference.patternMatchingOnAbilityConstructors`
- `docs.languageReference.useClauses`

## Notes
- If you need facts about Unison syntax, semantics, or typing rules, always
  fetch them from `docs.languageReference.*` via MCP.
- This file intentionally avoids duplicating language rules.
