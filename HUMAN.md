# Tips 
Say: "Be clear, concise and simple." when starting a new session.
-> Not sure

## Example first prompt
 
We're trying to get the smoke test from phone to phone (avery <-> blake) working, in our test we connect them
  both, then lock averys screen, and then try to talk from blake but it's not waking, we did manage to wake at
  some point before when we were using the bridge and under some circumstances like doing foreground talk first,
  now we moved to our worker based infra and are trying to get wake to work there, we never managed to get wake
  and hear working (never any audio in lock screen) but we did manage to wake @avery via push via Apple's PTT
  framework before with the local python bridge. Ideally we want to minimize human work, so the more you can do
  without me better. I may be speaking some times so text may not be perfect. Please review the last handoff and
  any .md files you need to start working on this. Please respond with short, simple, and concise answers, and
  when asking me to do things, be short and concise and tell me exactly step by step what to do. Let's do this!
  
  -> OKlafalaya
---

## Good
› We'll be working together on our App today, specifically on supporting physical device Apple's PTT Framework
  wake and listening speak while on the background. We had foreground to foreground working before. But now, in
  our smoke tests, when @avery is locked and @blake holds to talk to talk to @avery, we get @avery to wake but
  we don't hear anyting. This could be backend (unison) or frontend (Swift) but we think that what happens is
  that we're doing something wrong in following Apple's instructions / documentation for PushToTalk.framework,
  and it's mostly our state management since we have a lot of state switching (and often buggy callback-like
  hacked code), that we want to simplify and make clean and elegant maybe with state machines, ADTs and
  functional style so it's easy to debug. You should go as far as possible without me, by using our testing
  infrastructure eveytime we're talking control plane and we don't really need a physical device to test actual
  PTT framework or APNs that only work on real devices. Try to teach me as we go.

---

yes, and how might we design and iterate on our system so that once it works, it always works and it's very
  reliable, by design.
  
  -> GOOD
