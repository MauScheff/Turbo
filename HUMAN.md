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

# Start

› Hello we will be collaborating today. I want you to be efficient but also take your time and solve things
  well. We will be improving our end-to-end communications and the goal of today is that we can get our physical
  device devices where we are testing that all push-to-talk flows work so we have foreground to foreground,
  foreground to background, background to background and there's all these edge cases when it's asleep, when
  some time passes by and the connection is cut. So basically we want to always hear on the other end when we
  speak. That's what we're working on today. I have two physical devices here that we use for this kind of end-
  to-end tests because the push-to-talk framework from Apple cannot be tested in the simulator but if we do find
  bugs that don't need physical devices you also have all the tools and infrastructure to do simulations lane
  and testing end-to-end so you should try to go as far as you can without me to reduce the human work. When you
  are ready we can start with a simple smoke test. You may want to read the handoff while I prepare the first
  smoke test and what I'll do I have Avery on an iPhone and Blake on an iPad and I will do Avery to Blake
  foreground foreground and then continue with the test and then turn it lock the screen and then Apple's push-
  to-talk framework comes in the background so they have a UI from Apple and that should work too and I'll be
  doing this test progressively like the same test gets farther and farther away until we can have everything
  perfect but we will stop every time we have a little bug and fix it there so we should be able to have this
  long path testing path work flawlessly by the end of the day. Is there any question?

#Midwise
I'm very dissapointed because we have been working on this all afternoon.

# I have good judgement
