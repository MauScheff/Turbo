## Atomic References

Unison provides atomic references for safe concurrent state manipulation:

```
-- Create a new reference
ref = Remote.Ref.new initialValue

-- Read a reference
value = Remote.Ref.read ref

-- Compare and Swap (CAS) for atomic updates
(token, currentValue) = Remote.Ref.readForCas ref
success = Remote.Ref.cas ref token currentValue newValue
```

Here's an atomic modify function using CAS:

```
Remote.Ref.atomicModify : Remote.Ref a ->{Remote} (a -> a) -> a
Remote.Ref.atomicModify ref updateFn =
  go = do
    (token, currentValue) = Remote.Ref.readForCas ref
    newValue = updateFn currentValue
    success = Remote.Ref.cas ref token currentValue newValue
    if success then newValue
    else go()

  go()
```

Here are the API functions used for working with `Remote.Ref`:

```
type Remote.Ref a
Remote.Ref.cas : Remote.Ref a -> Ref.Ticket a -> a ->{Remote} Boolean
Remote.Ref.delete : Remote.Ref a ->{Remote} ()
Remote.Ref.getThenUpdate : Remote.Ref a -> (a -> a) ->{Remote} a
Remote.Ref.modify : Remote.Ref a -> (a -> (a, b)) ->{Remote} b
Remote.Ref.new : a ->{Remote} Remote.Ref a
Remote.Ref.new.detached : a ->{Remote} Remote.Ref a
Remote.Ref.read : Remote.Ref a ->{Remote} a
Remote.Ref.readForCas : Remote.Ref a ->{Remote} (Ref.Ticket a, a)
Remote.Ref.Ref : Ref.Id -> Location.Id -> Remote.Ref a

type Remote.Ref.Ticket a
Remote.Ref.Ticket.Ticket : Nat -> Ref.Ticket a
Remote.Ref.tryCas : Remote.Ref a -> Ref.Ticket a -> a ->{Remote} Either Failure Boolean
Remote.Ref.tryDelete : Remote.Ref a ->{Remote} Either Failure ()
Remote.Ref.tryReadForCas : Remote.Ref a ->{Remote} Either Failure (Ref.Ticket a, a)
Remote.Ref.tryWrite : Remote.Ref a -> a ->{Remote} Either Failure ()
Remote.Ref.update : Remote.Ref a -> (a -> a) ->{Remote} ()
Remote.Ref.updateThenGet : Remote.Ref a -> (a -> a) ->{Remote} a
Remote.Ref.write : Remote.Ref a -> a ->{Remote} ()
```

## Promises

Promises provide synchronization between concurrent tasks:

```
-- Create an empty promise
promise = Remote.Promise.empty()

-- Write to a promise (returns true if it was empty, false if already filled)
success = Remote.Promise.write promise value

-- Blocking read from a promise
value = Remote.Promise.read promise

-- Non-blocking read (returns Optional a)
maybeValue = Remote.Promise.readNow promise
```

Promises are useful for building higher-level concurrency patterns, such as a race function:

```
Remote.race : '{Remote, Exception} a -> '{Remote, Exception} a ->{Remote, Exception} a
Remote.race computation1 computation2 =
  promise = Remote.Promise.empty()

  Remote.forkAt pool() do
    result = computation1()
    _ = Remote.Promise.write promise result
    ()

  Remote.forkAt pool() do
    result = computation2()
    _ = Remote.Promise.write promise result
    ()

  Remote.Promise.read promise
```

Here are the API functions for working with promises:

```
type Remote.Promise a

Remote.Promise.delete : Remote.Promise a ->{Remote} ()
Remote.Promise.empty : '{Remote} Remote.Promise a
Remote.Promise.empty.detached! : {Remote} (Remote.Promise a)

Remote.Promise.read : Remote.Promise a ->{Remote} a
Remote.Promise.readNow : Remote.Promise a ->{Remote} Optional a
Remote.Promise.tryDelete : Remote.Promise a ->{Remote} Either Failure ()
Remote.Promise.tryRead : Remote.Promise a ->{Remote} Either Failure a
Remote.Promise.tryReadNow : Remote.Promise a ->{Remote} Either Failure (Optional a)
Remote.Promise.tryWrite : Remote.Promise a -> a ->{Remote} Either Failure Boolean
Remote.Promise.write : Remote.Promise a -> a ->{Remote} Boolean
Remote.Promise.write_ : Remote.Promise a -> a ->{Remote} ()
```

## Structured Concurrency

Unison's `Remote` ability supports structured concurrency, ensuring that child tasks don't outlive their parent context:

- By default, a forked task, promise, or ref will be cleaned up when the parent task completes
- For detached resources that persist beyond their parent's lifetime, use:
  - `Remote.Ref.new.detached` (for refs)
  - `Promise.empty.detached!` (for promises)
  - `Remote.detach pool() r` (for tasks)

When using detached resources, you're responsible for cleanup:
- `Remote.Ref.delete` (for refs)
- `Remote.Promise.delete` (for promises)
- `Remote.cancel` (for tasks)

## Finalizers

You can use `Remote.addFinalizer : (Outcome ->{Remote} ()) ->{Remote} ()` to add logic that should be run when a block completes, either due to success, failure, or cancellation. Here's an example:

```
addFinalizer do someCleanupFunction xyz 
```

If you need to do something different you can pattern match on the `Outcome`:

```
type Remote.Outcome = Completed | Cancelled | Failed Failure
```

```
addFinalizer cases
  Completed -> -- the success case
  Cancelled -> -- if the parent task was cancelled 
  Failed err -> -- if the task failed with some error
```

### Concurrent Queue

Here's an implementation of a concurrent queue using `Remote` primitives:

```
type Queue a = Queue (Remote.Ref ([a], Optional (Remote.Promise ())))

Queue.underlying = cases Queue r -> r

Queue.new : '{Remote} Queue a
Queue.new =
  ref = Remote.Ref.new ([], None)
  Queue ref

Queue.enqueue : Queue a -> a ->{Remote} ()
Queue.enqueue q item =
  (token, (items, waiter)) = Remote.Ref.readForCas (Queue.underlying ref)

  match waiter with
    None ->
      success = Remote.Ref.cas ref token (items, None) (items :+ item, None)
      if success then () else Queue.enqueue (Queue ref) item

    Some promise ->
      success = Remote.Ref.cas ref token (items, Some promise) (items :+ item, None)
      if success then
        _ = Remote.Promise.write promise ()
        ()
      else Queue.enqueue (Queue ref) item

Queue.dequeue : Queue a ->{Remote} a
Queue.dequeue q =
  (token, (items, _)) = Remote.Ref.readForCas (Queue.underlying q)

  match items with
    [] ->
      promise = Remote.Promise.empty()
      success = Remote.Ref.cas ref token ([], None) ([], Some promise)
      if success then
        Remote.Promise.read promise
        Queue.dequeue (Queue ref)
      else Queue.dequeue (Queue ref)

    item +: rest ->
      success = Remote.Ref.cas ref token (items, _) (rest, None)
      if success then item else Queue.dequeue (Queue ref)

Queue.size : Queue a ->{Remote} Nat
Queue.size q =
  (items, _) = Remote.Ref.read (Queue.underlying ref)
  List.size items
```

### Bounded Parallel Map with Retry

This function processes a list in parallel with bounded concurrency and retries failed tasks:

```
Remote.boundedParMapWithRetry : Nat -> [b] -> (b ->{Remote, Exception} a) ->{Remote, Exception} [a]
Remote.boundedParMapWithRetry maxConcurrent inputs fn =
  processChunk : [b] ->{Remote, Exception} [a]
  processChunk chunk =
    processWithRetry : b ->{Remote, Exception} a
    processWithRetry input =
      retry : Nat ->{Remote, Exception} a
      retry attemptsLeft =
        if attemptsLeft == 0 then fn input
        else
          task = Remote.forkAt pool() do fn input
          result = Remote.tryAwait task

          match result with
            Right success -> success
            Left failure -> retry (attemptsLeft - 1)

      retry 2

    go : [b] -> [a] ->{Remote, Exception} [a]
    go remaining acc =
      match remaining with
        [] -> acc
        input +: rest ->
          result = processWithRetry input
          go rest (acc :+ result)

    go chunk []

  chunks = List.chunk maxConcurrent inputs

  tasks = List.map (chunk ->
    Remote.forkAt pool() do processChunk chunk
  ) chunks

  results = List.map Remote.await tasks
  List.flatten results
```

## Distributed Computing Considerations

When using `Remote` with Unison Cloud, additional considerations come into play:

- Tasks may fail due to node failures or network issues, even if the computation itself is correct
- You can control task placement using location functions:
  - `pool()` - Pick a random available node
  - `Remote.near pool() (workLocation t)` - Fork at the same location as task `t`
  - `Remote.far pool() loc` - Pick a location different from `loc`


# Timing and Timeouts

The `Remote` ability provides functions for introducing delays and implementing timeouts in concurrent operations:

### Sleep

You can pause execution of a task using:

```
Remote.sleepMicroseconds : Nat ->{Remote} ()
```

This is useful for implementing retry with backoff, polling intervals, or simply delaying operations:

```
-- Sleep for 1 second (1,000,000 microseconds)
Remote.sleepMicroseconds 1000000
```

### Timeouts

Timeouts are essential for preventing operations from blocking indefinitely. Unison provides:

```
Remote.timeout : Nat -> '{Remote, g} a ->{Remote, g} Optional a
```

This function runs a computation and returns `None` if the computation doesn't complete within the specified microseconds:

```
-- Try to run a computation with a 5-second timeout
result = Remote.timeout 5000000 do
  expensiveOperation()

match result with
  Some value -> use the value
  None -> handle the timeout case
```

You can combine timeout with race patterns for more complex scenarios:

```
withTimeout : Nat -> '{Remote, g} a ->{Remote, g} Either Text a
withTimeout microseconds computation =
  Remote.race
    (do
      Remote.sleepMicroseconds microseconds
      Remote.pure (Left "Operation timed out"))
    (do
      result = computation()
      Remote.pure (Right result))
```
