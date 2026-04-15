# Unison Cloud APNs Transport Repro

## Minimal function

```unison
httpEgressProbe : '{Exception, Http} {Text, Text}
httpEgressProbe =
  let
    fetch url =
      let req = HttpRequest.get (URI.parse url)
      match catch do Http.request req with
        Left _ -> "crashed"
        Right response ->
          "status:" ++ Nat.toText (HttpResponse.status response |> code)
  in
    { fetch "https://www.unison.cloud/"
    , fetch "https://api.sandbox.push.apple.com/3/device/probe"
    }
```

## Expected result

The second request is intentionally invalid at the application level, but it
should still return an HTTP status if transport succeeds.

For example, any of these would be fine:

- `status:400`
- `status:403`
- `status:404`

## Actual hosted result

```json
{"unisonCloud":"status:200","apnsSandbox":"crashed"}
```

## Why this matters

This isolates the failure to transport/runtime, not request semantics:

- the same deployed runtime can do ordinary outbound HTTPS
- the APNs-host request crashes before any HTTP status is returned
- the APNs request here has no JWT, no custom headers, and no Turbo-specific logic

So this is a minimal indication that deployed Unison Cloud `Http.request`
handles normal HTTPS, but fails when targeting the APNs host specifically.

## Concrete hosted probe used here

The current deployed proof route is implemented in
[turbo_http_egress_probe.u](/Users/mau/Development/Turbo/turbo_http_egress_probe.u),
but the function above is the essential repro.
