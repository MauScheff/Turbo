# Unison Cloud Guide

This guide covers how to write code for Unison Cloud using the `@unison/cloud` library. Use this when you need to deploy services, create databases, run daemons, or perform distributed computations.

**Authoritative Source**: `@unison/cloud` project in the Unison codebase

## Prerequisites

Before using Unison Cloud:
- You need a [Unison account](https://share.unison-lang.org)
- You need [Cloud access](https://unison.cloud/signup/?plan=Free) for your account
- After getting access, run `auth.login` in UCM

## Running Cloud Code

### Cloud.main - For Production

```unison
myProgram : '{IO, Exception, Cloud} ServiceHash HttpRequest HttpResponse
myProgram = Cloud.main do
  -- Your cloud operations here
  deployHttp Environment.default() myHandler
```

`Cloud.main` runs your code against the real Unison Cloud.

### Cloud.run.local - For Local Development

```unison
myProgram : '{IO, Exception, Cloud} ServiceHash HttpRequest HttpResponse
myProgram = Cloud.run.local do
  -- Test your cloud code locally
  deployHttp Environment.default() myHandler
```

Use `Cloud.run.local` or `Cloud.run.local.serve` for local testing without deploying to the cloud.

## Environments

An `Environment` provides runtime access to configuration (including secrets) and controls which storage resources a service can access.

### Creating Environments

```unison
-- Create or get an environment by name (idempotent)
env = Environment.named "production"

-- Or use the default environment
env = Environment.default()
```

### Managing Configuration

```unison
-- Set configuration values (including secrets)
Environment.setValue env "api-key" "secret-value-123"
Environment.setValue env "database-url" "postgres://..."

-- Delete configuration values
Environment.deleteValue env "api-key"
```

**Note**: To access config values in your deployed code, you'll need to use the `Environment.Config` ability (details below).

## Databases and Storage

### Creating Databases

```unison
-- Create a database (idempotent - safe to call multiple times)
database = Database.named "myDatabase"

-- Assign database to an environment (access control)
Database.assign database environment

-- Later, you can unassign or delete
Database.unassign database environment
Database.delete database
```

**Key Concept**: Only services deployed with the same `Environment` as a `Database` can access that database's data.

### Tables

A `Table` is a typed key-value store. Tables are lightweight and don't need to be created ahead of time.

```unison
-- Declare a table with specific types
userTable : Table Text UserRecord
userTable = Table "users"

activityTable : Table URI Nat
activityTable = Table "activity"
```

**Important**: Tables can store ANY Unison value, including functions or other tables. No serialization code needed!

### Transactions

Use `transact` to read/write data transactionally:

```unison
Storage.transact : Database -> '{Transaction, Exception, Random, Batch} a
                   ->{Exception, Storage} a
```

Transaction operations:
- `Transaction.tryRead.tx : Table k v -> k ->{Transaction} Optional v`
- `Transaction.write.tx : Table k v -> k -> v ->{Transaction} ()`
- `Transaction.delete.tx : Table k v -> k ->{Transaction} ()`

**Transaction Guarantees**:
- Reads get a consistent snapshot view
- If an exception occurs, database remains in original state
- Atomic: all writes succeed or all fail

Example:

```unison
updateUser : Database -> '{Exception, Storage} ()
updateUser database = do
  table : Table Text Boolean
  table = Table "activeUsers"
  transact database do
    active = Transaction.tryRead.tx table "alice"
    match active with
      None -> Transaction.write.tx table "alice" true
      Some isActive -> Transaction.write.tx table "alice" (Boolean.not isActive)
```

**Limits**:
- Individual table entries: ~350 KB compressed
- Large transactions (many entries) are slower and may hit size limits
- Break large workloads into multiple smaller transactions

### Batched Reads

Use `Batch` ability for bulk reads to avoid round-trip overhead:

```unison
batchRead : Database -> '{Exception, Batch} a ->{Exception, Storage} a
```

Fork-await pattern:

```unison
batchExample : Database -> '{Exception, Storage} (Text, Text, Boolean)
batchExample db = do
  table1 : Table Nat Text
  table1 = Table "table1"
  table2 : Table Text Boolean
  table2 = Table "table2"

  batchRead db do
    read1 = forkRead table1 1
    read2 = forkRead table1 2
    read3 = forkRead table2 "key"
    (awaitRead read1, awaitRead read2, awaitRead read3)
```

Batched reads also work inside `transact` for transactional consistency.

### Blobs Storage

For binary data (images, files), use the `Blobs` ability:

```unison
-- Write bytes
Blobs.bytes.write : Database -> Key -> Bytes ->{Exception, Blobs} ETag

-- Read bytes
Blobs.bytes.read : Database -> Key ->{Exception, Blobs} Optional (Bytes, Metadata)

-- Typed blobs (auto-serialized)
Blobs.typed.write : Database -> Key -> a ->{Exception, Blobs} ETag
Blobs.typed.read : Database -> Key ->{Exception, Blobs} Optional (a, Metadata)
```

Example:

```unison
storeBlobExample : Database -> '{Exception, Blobs} ()
storeBlobExample db = do
  bytes = Text.toUtf8 "hello, world!"
  key = Blob.Key.Key "data/greeting.txt"
  etag = Blobs.bytes.write db key bytes
  result = Blobs.bytes.read db key
  -- result is Optional (Bytes, Metadata)
```

## Deploying HTTP Services

### Basic HTTP Service

```unison
Cloud.deployHttp : Environment
                 -> (HttpRequest ->{Environment.Config, Exception, Http,
                                     Blobs, Services, Storage, Remote,
                                     Random, Log, Scratch} HttpResponse)
                 ->{Exception, Cloud} ServiceHash HttpRequest HttpResponse
```

Example:

```unison
simpleHttp.main : '{IO, Exception} ServiceHash HttpRequest HttpResponse
simpleHttp.main = Cloud.main do
  helloService : HttpRequest -> HttpResponse
  helloService request = ok (Body (Text.toUtf8 "Hello world"))
  deployHttp Environment.default() helloService
```

Run with: `run simpleHttp.main`

The service will be deployed and you'll get:
- A `ServiceHash` (content-addressed identifier)
- A URI like: `https://<username>.services.unison.cloud/h/<hash>`

### Exposing HTTP Services

```unison
-- Make a service publicly accessible
Cloud.exposeHttp : ServiceHash HttpRequest HttpResponse
                 ->{Exception, Cloud} URI
```

### Service Names

ServiceHash is immutable (content-addressed). For stable, human-friendly names:

```unison
simpleHttpNamed.main : '{IO, Exception} URI
simpleHttpNamed.main = Cloud.main do
  serviceHash = deployHttp Environment.default() myHandler
  serviceName = ServiceName.named "my-api-v1"
  ServiceName.assign serviceName serviceHash
```

URI format: `https://<username>.services.unison.cloud/s/<serviceName>`

- `ServiceName.assign` - Point name to a service hash (can update later)
- `ServiceName.unassign` - Remove the backing implementation
- `ServiceName.delete` - Delete the service name

**Analogy**: `ServiceHash` is like a git commit, `ServiceName` is like a branch name.

### Stateful HTTP Service

```unison
statefulService : Database -> Table URI Nat
                -> HttpRequest ->{Exception, Storage, Log} HttpResponse
statefulService database table request =
  uri = HttpRequest.uri request
  info "Received request" [("uri", URI.toText uri)]
  transact database do
    count = Transaction.tryRead.tx table uri
    newCount = Optional.getOrElse 0 count + 1
    Transaction.write.tx table uri newCount
  ok (Body (Text.toUtf8 "Request counted"))

main = Cloud.main do
  environment = Environment.default()
  database = Database.named "myDatabase"
  Database.assign database environment
  table = Table "requestCounter"
  deployHttp environment (statefulService database table)
```

### Undeploying Services

```unison
Cloud.undeploy : ServiceHash a b ->{Exception, Cloud} ()
Cloud.unexposeHttp : ServiceHash HttpRequest HttpResponse ->{Exception, Cloud} ()
```

## Deploying WebSocket Services

### HTTP + WebSocket Service

```unison
Cloud.deployHttpWebSocket :
  Environment
  -> (HttpRequest ->{...} Either HttpResponse
                           (websockets.WebSocket ->{Exception, Remote, WebSockets} ()))
  ->{Exception, Cloud} ServiceHash HttpRequest (Either HttpResponse (...))
```

Example:

```unison
webSocketEcho.deploy : '{IO, Exception} URI
webSocketEcho.deploy = Cloud.main do
  handler ws =
    msg = WebSockets.receive ws
    WebSockets.send ws msg
    WebSockets.close ws

  service request = Right handler

  serviceName = ServiceName.named "echo-service"
  hash = deployHttpWebSocket Environment.default() service
  ServiceName.assign serviceName hash
```

### WebSocket-only Service

```unison
Cloud.deployWebSocket :
  Environment
  -> (websockets.WebSocket ->{Exception, Remote, WebSockets} ())
  ->{Exception, Cloud} ServiceHash HttpRequest (Either HttpResponse (...))
```

### WebSocket Cleanup

Use `addFinalizer` for cleanup when connection closes:

```unison
handler : WebSocket ->{Exception, Remote, WebSockets} ()
handler ws =
  addFinalizer (result -> toRemote do
    info "WebSocket closed" []
  )
  msg = WebSockets.receive ws
  WebSockets.send ws msg
  WebSockets.close ws
```

## Deploying Daemons

Daemons are long-running background processes.

```unison
Cloud.Daemon.deploy : Daemon -> Environment
                    -> '{Environment.Config, Exception, Http, Blobs,
                         Services, Storage, Remote, websockets.HttpWebSocket,
                         WebSockets, Random, Log, Scratch} ()
                    ->{Exception, Cloud} DaemonHash
```

### Creating and Deploying a Daemon

```unison
myDaemon.main : '{IO, Exception} DaemonHash
myDaemon.main = Cloud.main do
  daemon = Cloud.Daemon.named "my-background-worker"
  environment = Environment.default()

  daemonLogic = do
    -- Long-running process
    forever do
      info "Daemon heartbeat" []
      sleepSeconds 60

  Cloud.Daemon.deploy daemon environment daemonLogic
```

### Managing Daemons

```unison
-- Create daemon identifier (idempotent)
daemon = Cloud.Daemon.named "worker-1"

-- Assign a daemon hash to run (replaces existing if any)
Cloud.Daemon.assign daemon daemonHash

-- Stop the daemon
Cloud.Daemon.unassign daemon

-- Delete the daemon identifier
Cloud.Daemon.delete daemon
```

### Daemon Logs

```unison
-- Tail daemon logs to console
Cloud.Daemon.logs.tail.console : Daemon ->{IO, Exception, Cloud, Threads} Void
Cloud.DaemonHash.logs.tail.console : DaemonHash ->{IO, Exception, Cloud, Threads} Void
```

## Submitting Distributed Jobs

Use `Cloud.submit` to run one-off distributed computations:

```unison
Cloud.submit : Environment
             -> '{Environment.Config, Exception, Http, Blobs, Services,
                  Storage, Remote, websockets.HttpWebSocket, WebSockets,
                  Random, Log, Scratch} a
             ->{Exception, Cloud} a
```

Example:

```unison
simpleBatch.main : '{IO, Exception} Nat
simpleBatch.main = Cloud.main do
  environment = Environment.default()
  Cloud.submit environment do
    result = parMap (n -> n + 1) (Nat.range 0 1000)
    Nat.sum result
```

The computation runs on the cloud and returns the result to your local machine.

**Tip**: Save results back to your codebase with `add.run <program>` in UCM.

## Logging

Use the `Log` ability anywhere in your cloud code:

```unison
Log.info : Text -> [(Text, Text)] ->{Log} ()
Log.debug : Text -> [(Text, Text)] ->{Log} ()
Log.error : Text -> [(Text, Text)] ->{Log} ()
```

Example:

```unison
myHandler : HttpRequest ->{Log, Exception} HttpResponse
myHandler request =
  info "Processing request"
       [("method", HttpRequest.method request |> toText),
        ("path", HttpRequest.path request)]
  -- ... handle request
  ok (Body (Text.toUtf8 "OK"))
```

Logs are automatically:
- Associated with the service that generated them
- Timestamped
- Tagged with log level

### Viewing Logs

View logs in the [Unison Cloud UI](https://app.unison.cloud) or stream to console:

```unison
-- Stream logs for a service
Cloud.logs.service.tail.console : ServiceHash a b ->{IO, Exception} Void

-- Query logs with options
Cloud.logs.service : ServiceHash a b -> QueryOptions ->{IO, Exception} [Json]

-- Default log tail
Cloud.logs.tail.console.default : '{IO, Exception} Void
```

## Calling Services from Services

Use the `Services` ability to make service-to-service calls:

```unison
Services.call : ServiceHash a b -> a ->{Services, Remote} b
```

Example:

```unison
callingService : ServiceHash Text Json -> HttpRequest
               ->{Services, Remote, Exception} HttpResponse
callingService otherService request =
  result = Services.call otherService "some input"
  ok (Body (Json.toBytes result))
```

## Working with Remote Ability

The `Remote` ability enables distributed computing. All cloud deployments use it internally.

### Embedding Full Abilities in Remote Code

Use `toRemote` to embed abilities like `Log`, `Storage`, etc. in `Remote` code:

```unison
toRemote : '{Environment.Config, Exception, Http, Blobs, Services, Storage,
             Remote, websockets.HttpWebSocket, WebSockets, Random, Log,
             Scratch, Tcp, TcpConnect Remote} a
         ->{Remote} a
```

Example:

```unison
runBothLogged : '{Remote} (Nat, Nat)
runBothLogged = do
  add1 n1 = toRemote do
    result = n1 + 1
    info "add1" [("input", Nat.toText n1), ("result", Nat.toText result)]
    result

  add2 n2 = toRemote do
    result = n2 + 2
    info "add2" [("input", Nat.toText n2), ("result", Nat.toText result)]
    result

  both (do add1 1) (do add2 2)
```

## Common Patterns

### Initialize Storage for a Service

```unison
initializeService : '{IO, Exception} ServiceHash HttpRequest HttpResponse
initializeService = Cloud.main do
  -- Create environment
  environment = Environment.named "production"

  -- Set up database
  database = Database.named "myAppData"
  Database.assign database environment

  -- Define tables (lightweight, no pre-creation needed)
  usersTable : Table Text UserRecord
  usersTable = Table "users"

  sessionsTable : Table Text Session
  sessionsTable = Table "sessions"

  -- Deploy service with access to database
  deployHttp environment (myHandler database usersTable sessionsTable)
```

### Development Workflow

```unison
-- For local testing
myService.test = Cloud.run.local do
  deployHttp Environment.default() myHandler

-- For production deployment
myService.prod = Cloud.main do
  deployHttp Environment.default() myHandler
```

Run locally: `run myService.test`
Deploy to cloud: `run myService.prod`

### Higher-Level HTTP Routing

For complex HTTP services, use the `@unison/routes` library rather than writing raw `HttpRequest -> HttpResponse` handlers.

## Important Notes

### Content-Addressed Deployments

- `ServiceHash` and `DaemonHash` are content-addressed (based on code hash)
- Deploying the same code multiple times is idempotent
- Changing code creates a new hash
- Use `ServiceName` for stable, updatable endpoints

### Security & Privacy

- Free tier runs on shared infrastructure
- Not recommended for high-security production workloads
- For production use cases, contact Unison via [unison.cloud](https://www.unison.cloud)

### Access Control

- `Environment` assignment controls database access
- Only services/jobs with matching environment can access databases/blobs
- This provides isolation between different deployments

## Quick Reference

### Database Operations
- `Database.named : Text ->{Exception, Cloud} Database`
- `Database.assign : Database -> Environment ->{Exception, Cloud} ()`
- `Database.unassign : Database -> Environment ->{Exception, Cloud} ()`
- `Database.delete : Database ->{Exception, Cloud} ()`

### Environment Operations
- `Environment.named : Text ->{Exception, Cloud} Environment`
- `Environment.default : '{Exception, Cloud} Environment`
- `Environment.setValue : Environment -> Text -> Text ->{Exception, Cloud} ()`
- `Environment.deleteValue : Environment -> Text ->{Exception, Cloud} ()`

### Service Deployment
- `Cloud.deployHttp` - Deploy HTTP service
- `Cloud.deployHttpWebSocket` - Deploy HTTP + WebSocket service
- `Cloud.deployWebSocket` - Deploy WebSocket-only service
- `Cloud.exposeHttp` - Make service publicly accessible
- `Cloud.undeploy` - Undeploy a service

### Service Names
- `ServiceName.named : Text ->{Exception, Cloud} ServiceName a b`
- `ServiceName.assign : ServiceName a b -> ServiceHash a b ->{Exception, Cloud} URI`
- `ServiceName.unassign : ServiceName a b ->{Exception, Cloud} ()`
- `ServiceName.delete : ServiceName a b ->{Exception, Cloud} ()`

### Daemon Operations
- `Cloud.Daemon.named : Text ->{Exception, Cloud} Daemon`
- `Cloud.Daemon.deploy : Daemon -> Environment -> '{...} () ->{Exception, Cloud} DaemonHash`
- `Cloud.Daemon.assign : Daemon -> DaemonHash ->{Exception, Cloud} ()`
- `Cloud.Daemon.unassign : Daemon ->{Exception, Cloud} ()`
- `Cloud.Daemon.delete : Daemon ->{Exception, Cloud} ()`

### Storage Operations
- `transact : Database -> '{Transaction, Exception, Random, Batch} a ->{Exception, Storage} a`
- `Transaction.tryRead.tx : Table k v -> k ->{Transaction} Optional v`
- `Transaction.write.tx : Table k v -> k -> v ->{Transaction} ()`
- `Transaction.delete.tx : Table k v -> k ->{Transaction} ()`
- `batchRead : Database -> '{Exception, Batch} a ->{Exception, Storage} a`
- `forkRead : Table k v -> k ->{Batch} Read v`
- `awaitRead : Read v ->{Exception, Batch} v`

### Blobs Operations
- `Blobs.bytes.write : Database -> Key -> Bytes ->{Exception, Blobs} ETag`
- `Blobs.bytes.read : Database -> Key ->{Exception, Blobs} Optional (Bytes, Metadata)`
- `Blobs.typed.write : Database -> Key -> a ->{Exception, Blobs} ETag`
- `Blobs.typed.read : Database -> Key ->{Exception, Blobs} Optional (a, Metadata)`

### Batch Jobs
- `Cloud.submit : Environment -> '{...} a ->{Exception, Cloud} a`

### Logging
- `Log.info : Text -> [(Text, Text)] ->{Log} ()`
- `Log.debug : Text -> [(Text, Text)] ->{Log} ()`
- `Log.error : Text -> [(Text, Text)] ->{Log} ()`
- `Cloud.logs.service.tail.console : ServiceHash a b ->{IO, Exception} Void`

### Service Calls
- `Services.call : ServiceHash a b -> a ->{Services, Remote} b`

### Utilities
- `toRemote : '{...} a ->{Remote} a` - Embed full abilities in Remote code

## Related Resources

- [@unison/cloud-start](https://share.unison-lang.org/@unison/cloud-start) - Examples and templates
- [@unison/routes](https://share.unison-lang.org/@unison/routes) - HTTP routing library
- [@unison/httpclient](https://share.unison-lang.org/@unison/httpclient) - HTTP client
- [Unison Cloud UI](https://app.unison.cloud) - View logs and monitor services
