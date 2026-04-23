import test from "node:test";
import assert from "node:assert/strict";

import { __test } from "./index.js";

test("validateEvent requires the core telemetry fields", () => {
  assert.equal(__test.validateEvent({}), "missing-event-name");
  assert.equal(
    __test.validateEvent({
      eventName: "ios.transmit.begin_requested",
      source: "ios",
      severity: "info",
    }),
    null,
  );
});

test("normalizeEvent prefers metadataText and truncates oversized payloads", () => {
  const metadataText = "x".repeat(20_000);
  const event = __test.normalizeEvent({
    eventName: "backend.invariant.violation",
    source: "backend",
    severity: "error",
    metadataText,
  });

  assert.equal(event.metadataText.length, 16_384);
});

test("buildAnalyticsPoint keeps a stable field order for the dataset", () => {
  const event = __test.normalizeEvent({
    eventName: "ios.transmit.begin_requested",
    source: "ios",
    severity: "notice",
    userId: "user-1",
    userHandle: "@avery",
    deviceId: "device-1",
    channelId: "channel-1",
    alert: true,
  });

  const point = __test.buildAnalyticsPoint(event);

  assert.equal(point.blobs[0], "ios.transmit.begin_requested");
  assert.equal(point.blobs[4], "@avery");
  assert.equal(point.blobs[7], "channel-1");
  assert.deepEqual(point.doubles, [1, 1, 2]);
  assert.deepEqual(point.indexes, ["user-1"]);
});

test("shouldAlert triggers on explicit alerts and critical severity", () => {
  const explicitAlert = __test.normalizeEvent({
    eventName: "ios.invariant.violation",
    source: "ios",
    severity: "error",
    alert: true,
  });
  const criticalAlert = __test.normalizeEvent({
    eventName: "backend.telemetry.delivery_failed",
    source: "backend",
    severity: "critical",
  });
  const quietEvent = __test.normalizeEvent({
    eventName: "ios.transmit.begin_requested",
    source: "ios",
    severity: "notice",
  });

  assert.equal(__test.shouldAlert(explicitAlert), true);
  assert.equal(__test.shouldAlert(criticalAlert), true);
  assert.equal(__test.shouldAlert(quietEvent), false);
});

test("shouldStream excludes noisy heartbeat events from Discord stream", () => {
  const heartbeat = __test.normalizeEvent({
    eventName: "backend.presence.heartbeat",
    source: "backend",
    severity: "notice",
  });
  const joined = __test.normalizeEvent({
    eventName: "backend.channel.joined",
    source: "backend",
    severity: "notice",
  });

  assert.equal(__test.shouldStream(heartbeat), false);
  assert.equal(__test.shouldStream(joined), true);
});

test("sendDiscordEvent posts a compact embed payload", async () => {
  const originalFetch = globalThis.fetch;
  /** @type {any[]} */
  const payloads = [];

  globalThis.fetch = async (_url, options) => {
    payloads.push(JSON.parse(options.body));
    return new Response("", { status: 200 });
  };

  try {
    const ok = await __test.sendDiscordEvent(
      __test.normalizeEvent({
        eventName: "backend.invariant.violation",
        source: "backend",
        severity: "critical",
        userHandle: "@avery",
        deviceId: "device-1",
        channelId: "channel-1",
        invariantId: "backend.channel_state_conflict",
        message: "backend produced contradictory readiness",
      }),
      "https://discord.example/webhook",
      "alert",
    );

    assert.equal(ok, true);
    assert.equal(payloads.length, 1);
    assert.equal(payloads[0].username, "Turbo Telemetry");
    assert.equal(payloads[0].embeds[0].title, "ALERT backend backend.invariant.violation");
    assert.equal(payloads[0].embeds[0].fields[1].value, "@avery");
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("deliverDiscord skips heartbeat stream noise and only alerts alert-worthy events", async () => {
  const originalFetch = globalThis.fetch;
  /** @type {string[]} */
  const urls = [];

  globalThis.fetch = async (url) => {
    urls.push(String(url));
    return new Response("", { status: 200 });
  };

  try {
    const heartbeatResult = await __test.deliverDiscord(
      __test.normalizeEvent({
        eventName: "backend.presence.heartbeat",
        source: "backend",
        severity: "notice",
      }),
      {
        TURBO_TELEMETRY_DISCORD_ALERTS_WEBHOOK: "https://discord.example/alerts",
        TURBO_TELEMETRY_DISCORD_STREAM_WEBHOOK: "https://discord.example/stream",
      },
    );

    assert.deepEqual(heartbeatResult, { alerted: false, streamed: false });
    assert.deepEqual(urls, []);

    urls.length = 0;

    const quietResult = await __test.deliverDiscord(
      __test.normalizeEvent({
        eventName: "ios.transmit.begin_requested",
        source: "ios",
        severity: "info",
      }),
      {
        TURBO_TELEMETRY_DISCORD_ALERTS_WEBHOOK: "https://discord.example/alerts",
        TURBO_TELEMETRY_DISCORD_STREAM_WEBHOOK: "https://discord.example/stream",
      },
    );

    assert.deepEqual(quietResult, { alerted: false, streamed: true });
    assert.deepEqual(urls, ["https://discord.example/stream"]);

    urls.length = 0;

    const alertResult = await __test.deliverDiscord(
      __test.normalizeEvent({
        eventName: "backend.invariant.violation",
        source: "backend",
        severity: "error",
        alert: true,
      }),
      {
        TURBO_TELEMETRY_DISCORD_ALERTS_WEBHOOK: "https://discord.example/alerts",
        TURBO_TELEMETRY_DISCORD_STREAM_WEBHOOK: "https://discord.example/stream",
      },
    );

    assert.deepEqual(alertResult, { alerted: true, streamed: true });
    assert.deepEqual(urls, [
      "https://discord.example/stream",
      "https://discord.example/alerts",
    ]);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test("discordAlertsWebhook falls back to legacy single webhook", () => {
  assert.equal(
    __test.discordAlertsWebhook({
      TURBO_TELEMETRY_DISCORD_WEBHOOK: "https://discord.example/legacy",
    }),
    "https://discord.example/legacy",
  );
  assert.equal(
    __test.discordAlertsWebhook({
      TURBO_TELEMETRY_DISCORD_ALERTS_WEBHOOK: "https://discord.example/alerts",
      TURBO_TELEMETRY_DISCORD_WEBHOOK: "https://discord.example/legacy",
    }),
    "https://discord.example/alerts",
  );
});
