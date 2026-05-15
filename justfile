set shell := ["bash", "-cu"]

default:
  @just --list

venv:
  rm -rf .venv
  python3 -m venv .venv --without-pip
  .venv/bin/python -m ensurepip --upgrade
  .venv/bin/python -m pip install --upgrade pip
  .venv/bin/python -m pip install -r requirements.txt

serve-local-http:
  sh -c 'cd {{justfile_directory()}} && direnv exec . ucm run turbo/main:.turbo.serveHttpLocal'

serve-local:
  sh -c 'cd {{justfile_directory()}} && direnv exec . ucm run turbo/main:.turbo.serveLocal'

backend-schema-drift-test:
  sh -c 'cd {{justfile_directory()}} && direnv exec . ucm run turbo/main:.turbo.schemaDrift.check'

deploy: backend-schema-drift-test
  sh -c 'cd {{justfile_directory()}} && direnv exec . ucm run turbo/main:.turbo.deploy'

bump-deploy-stamp:
  sh -c 'cd {{justfile_directory()}} && ./scripts/write_deploy_stamp_scratch.sh'
  sh -c 'cd {{justfile_directory()}} && printf "load scratch_deploy_stamp.u\nupdate\nquit\n" | direnv exec . ucm -p turbo/main'

deploy-force:
  just bump-deploy-stamp
  just deploy

deploy-staging:
  just deploy

postdeploy-check base="https://beepbeep.to" caller="@quinn" callee="@sasha" iterations="1" output_dir="/tmp/turbo-postdeploy-check" insecure="--insecure":
  python3 scripts/postdeploy_check.py \
    --base-url "{{base}}" \
    --caller "{{caller}}" \
    --callee "{{callee}}" \
    --iterations "{{iterations}}" \
    --output-dir "{{output_dir}}" \
    {{insecure}}

deploy-staging-verified base="https://beepbeep.to" caller="@quinn" callee="@sasha" iterations="1" output_dir="/tmp/turbo-postdeploy-check" insecure="--insecure":
  just swift-test-suite
  just deploy-staging
  just postdeploy-check "{{base}}" "{{caller}}" "{{callee}}" "{{iterations}}" "{{output_dir}}" "{{insecure}}"

production-preflight:
  just swift-test-suite
  just reliability-gate-regressions
  just reliability-gate-full

deploy-production base="https://beepbeep.to" caller="@quinn" callee="@sasha" iterations="1" output_dir="/tmp/turbo-postdeploy-check-production" insecure="--insecure":
  just production-preflight
  just deploy
  just postdeploy-check "{{base}}" "{{caller}}" "{{callee}}" "{{iterations}}" "{{output_dir}}" "{{insecure}}"

deploy-verified base="https://beepbeep.to" caller="@quinn" callee="@sasha" iterations="1" output_dir="/tmp/turbo-postdeploy-check" insecure="--insecure":
  just deploy-staging-verified "{{base}}" "{{caller}}" "{{callee}}" "{{iterations}}" "{{output_dir}}" "{{insecure}}"

testflight:
  direnv exec . python3 scripts/start_testflight_release.py

testflight-assign build_id:
  direnv exec . python3 scripts/start_testflight_release.py --skip-git-checks --assign-build-id "{{build_id}}"

route-probe:
  .venv/bin/python scripts/route_probe.py --base-url https://beepbeep.to --caller @quinn --callee @sasha --insecure

backend-stability-probe base="https://beepbeep.to" handle="@mau" iterations="10" timeout="8":
  python3 scripts/backend_stability_probe.py --base-url "{{base}}" --handle "{{handle}}" --iterations "{{iterations}}" --timeout "{{timeout}}"

websocket-stability-probe base="https://beepbeep.to" caller="@quinn" callee="@sasha" duration="90" heartbeat_interval="20" telemetry_interval="0" insecure="--insecure":
  python3 scripts/websocket_stability_probe.py --base-url "{{base}}" --caller "{{caller}}" --callee "{{callee}}" --duration "{{duration}}" --heartbeat-interval "{{heartbeat_interval}}" --telemetry-interval "{{telemetry_interval}}" {{insecure}}

hosted-backend-client-probe base="https://beepbeep.to" duration="60" heartbeat_interval="20" telemetry_interval="20" output="/tmp/turbo-debug/hosted_backend_client_probe_latest.json":
  python3 scripts/run_hosted_backend_client_probe.py --base-url "{{base}}" --duration "{{duration}}" --heartbeat-interval "{{heartbeat_interval}}" --telemetry-interval "{{telemetry_interval}}" --output "{{output}}"

direct-quic-provisioning-probe:
  .venv/bin/python scripts/direct_quic_provisioning_probe.py --base-url https://beepbeep.to --caller @quinn --callee @sasha --insecure

turn-policy-probe require_enabled="":
  .venv/bin/python scripts/turn_policy_probe.py --base-url https://beepbeep.to --handle @quinn --insecure {{require_enabled}}

route-probe-local base="http://localhost:8090/s/turbo" caller="@avery" callee="@blake":
  .venv/bin/python scripts/route_probe.py --base-url "{{base}}" --caller "{{caller}}" --callee "{{callee}}"

clean-scratch:
  find . -maxdepth 1 -type f -name '*.u' | sort
  find . -maxdepth 1 -type f -name '*.u' -delete

seed base="https://beepbeep.to" handle="@avery":
  curl --fail-with-body -i -X POST \
    -H "x-turbo-user-handle: {{handle}}" \
    -H "Authorization: Bearer {{handle}}" \
    "{{base}}/v1/dev/seed"

reset base="https://beepbeep.to" handle="@avery":
  curl --fail-with-body -i -X POST \
    -H "x-turbo-user-handle: {{handle}}" \
    -H "Authorization: Bearer {{handle}}" \
    "{{base}}/v1/dev/reset-state"

reset-all base="https://beepbeep.to" handle="@avery":
  curl --fail-with-body -i -X POST \
    -H "x-turbo-user-handle: {{handle}}" \
    -H "Authorization: Bearer {{handle}}" \
    "{{base}}/v1/dev/reset-all"

reset-pair-all base="https://beepbeep.to" handle_a="@avery" handle_b="@blake":
  just reset-all "{{base}}" "{{handle_a}}"
  just reset-all "{{base}}" "{{handle_b}}"
  just seed "{{base}}" "{{handle_a}}"

diagnostics-latest device_id base="https://beepbeep.to" handle="@turbo-ios":
  curl --fail-with-body -sS \
    -H "x-turbo-user-handle: {{handle}}" \
    -H "Authorization: Bearer {{handle}}" \
    "{{base}}/v1/dev/diagnostics/latest/{{device_id}}/"

diagnostics-latest-current base="https://beepbeep.to" handle="@turbo-ios":
  curl --fail-with-body -sS \
    -H "x-turbo-user-handle: {{handle}}" \
    -H "Authorization: Bearer {{handle}}" \
    "{{base}}/v1/dev/diagnostics/latest"

diagnostics-merge base="https://beepbeep.to" handles="" insecure="--insecure":
  python3 scripts/merged_diagnostics.py --base-url "{{base}}" {{insecure}} {{handles}}

diagnostics-merge-pair base="https://beepbeep.to" handle_a="@avery" handle_b="@blake" insecure="--insecure":
  python3 scripts/merged_diagnostics.py --base-url "{{base}}" {{insecure}} "{{handle_a}}" "{{handle_b}}"

reliability-intake handle_a handle_b="" base="https://beepbeep.to" surface="auto" incident_id="" insecure="--insecure":
  python3 scripts/reliability_intake.py \
    --base-url "{{base}}" \
    --surface "{{surface}}" \
    --incident-id "{{incident_id}}" \
    {{insecure}} \
    "{{handle_a}}" "{{handle_b}}"

reliability-intake-shake handle incident_id peer="" base="https://beepbeep.to" surface="production" insecure="--insecure":
  python3 scripts/reliability_intake.py \
    --base-url "{{base}}" \
    --surface "{{surface}}" \
    --incident-id "{{incident_id}}" \
    {{insecure}} \
    "{{handle}}" "{{peer}}"

ptt-push-target channel_id base="https://beepbeep.to" handle="@avery":
  curl --fail-with-body -sS \
    -H "x-turbo-user-handle: {{handle}}" \
    -H "Authorization: Bearer {{handle}}" \
    "{{base}}/v1/channels/{{channel_id}}/ptt-push-target"

ptt-apns-start channel_id base="https://beepbeep.to" handle="@avery" bundle_id="com.rounded.Turbo" insecure="--insecure":
  python3 scripts/send_ptt_apns.py \
    --base-url "{{base}}" \
    --handle "{{handle}}" \
    --channel-id "{{channel_id}}" \
    --bundle-id "{{bundle_id}}" \
    {{insecure}}

ptt-apns-bridge base="https://beepbeep.to" handle_a="@avery" handle_b="@blake" bundle_id="com.rounded.Turbo" insecure="--insecure":
  python3 scripts/ptt_apns_bridge.py \
    --base-url "{{base}}" \
    --handle-a "{{handle_a}}" \
    --handle-b "{{handle_b}}" \
    --bundle-id "{{bundle_id}}" \
    {{insecure}}

ptt-apns-worker base="https://beepbeep.to" bundle_id="com.rounded.Turbo" insecure="--insecure":
  python3 scripts/ptt_apns_worker.py \
    --base-url "{{base}}" \
    --bundle-id "{{bundle_id}}" \
    {{insecure}}

cf-apns-worker-dev:
  sh -c 'cd {{justfile_directory()}}/cloudflare/apns-worker && wrangler dev'

cf-apns-worker-deploy:
  sh -c 'cd {{justfile_directory()}}/cloudflare/apns-worker && wrangler deploy'

cf-telemetry-worker-dev:
  sh -c 'cd {{justfile_directory()}}/cloudflare/telemetry-worker && wrangler dev'

cf-telemetry-worker-deploy:
  sh -c 'cd {{justfile_directory()}}/cloudflare/telemetry-worker && wrangler deploy'

telemetry-query query="SHOW TABLES":
  sh -c 'query="$1"; query="${query#query=}"; python3 scripts/query_telemetry.py --query "$query"' _ {{quote(query)}}

telemetry-recent hours="24" limit="50" insecure="":
  sh -c 'hours="{{hours}}"; limit="{{limit}}"; insecure="{{insecure}}"; hours="${hours#hours=}"; limit="${limit#limit=}"; insecure="${insecure#insecure=}"; python3 scripts/query_telemetry.py --hours "$hours" --limit "$limit" $insecure'

telemetry-recent-signal hours="24" limit="50" insecure="":
  sh -c 'hours="{{hours}}"; limit="{{limit}}"; insecure="{{insecure}}"; hours="${hours#hours=}"; limit="${limit#limit=}"; insecure="${insecure#insecure=}"; python3 scripts/query_telemetry.py --hours "$hours" --limit "$limit" --exclude-event-name "backend.presence.heartbeat" $insecure'

telemetry-recent-dev hours="24" limit="50" insecure="":
  sh -c 'hours="{{hours}}"; limit="{{limit}}"; insecure="{{insecure}}"; hours="${hours#hours=}"; limit="${limit#limit=}"; insecure="${insecure#insecure=}"; python3 scripts/query_telemetry.py --hours "$hours" --limit "$limit" --dev-traffic true $insecure'

telemetry-follow hours="1" limit="50" poll="5" insecure="":
  sh -c 'hours="{{hours}}"; limit="{{limit}}"; poll="{{poll}}"; insecure="{{insecure}}"; hours="${hours#hours=}"; limit="${limit#limit=}"; poll="${poll#poll=}"; insecure="${insecure#insecure=}"; python3 scripts/query_telemetry.py --hours "$hours" --limit "$limit" --follow --poll-seconds "$poll" $insecure'

telemetry-follow-signal hours="1" limit="50" poll="5" insecure="":
  sh -c 'hours="{{hours}}"; limit="{{limit}}"; poll="{{poll}}"; insecure="{{insecure}}"; hours="${hours#hours=}"; limit="${limit#limit=}"; poll="${poll#poll=}"; insecure="${insecure#insecure=}"; python3 scripts/query_telemetry.py --hours "$hours" --limit "$limit" --exclude-event-name "backend.presence.heartbeat" --follow --poll-seconds "$poll" $insecure'

telemetry-follow-dev hours="1" limit="50" poll="5" insecure="":
  sh -c 'hours="{{hours}}"; limit="{{limit}}"; poll="{{poll}}"; insecure="{{insecure}}"; hours="${hours#hours=}"; limit="${limit#limit=}"; poll="${poll#poll=}"; insecure="${insecure#insecure=}"; python3 scripts/query_telemetry.py --hours "$hours" --limit "$limit" --dev-traffic true --follow --poll-seconds "$poll" $insecure'

telemetry-user handle hours="24" limit="50" insecure="":
  sh -c 'handle="{{handle}}"; hours="{{hours}}"; limit="{{limit}}"; insecure="{{insecure}}"; handle="${handle#handle=}"; hours="${hours#hours=}"; limit="${limit#limit=}"; insecure="${insecure#insecure=}"; python3 scripts/query_telemetry.py --hours "$hours" --limit "$limit" --user-handle "$handle" $insecure'

simulator-scenario scenario="" base="https://beepbeep.to" handle_a="@avery" handle_b="@blake" insecure="--insecure":
  python3 scripts/run_simulator_scenarios.py \
    --scenario "{{scenario}}" \
    --base-url "{{base}}" \
    --handle-a "{{handle_a}}" \
    --handle-b "{{handle_b}}"

simulator-scenario-merge base="https://beepbeep.to" handle_a="@avery" handle_b="@blake" insecure="--insecure":
  python3 scripts/merged_diagnostics.py --base-url "{{base}}" {{insecure}} \
    --device "{{handle_a}}=sim-scenario-avery" \
    --device "{{handle_b}}=sim-scenario-blake"

simulator-scenario-merge-strict base="https://beepbeep.to" handle_a="@avery" handle_b="@blake" insecure="--insecure":
  python3 scripts/merged_diagnostics.py --base-url "{{base}}" {{insecure}} --fail-on-violations \
    --device "{{handle_a}}=sim-scenario-avery" \
    --device "{{handle_b}}=sim-scenario-blake"

simulator-scenario-hosted-strict scenario="" base="https://beepbeep.to" handle_a="@avery" handle_b="@blake" insecure="--insecure":
  sh -c 'device_a="sim-scenario-avery-$(uuidgen | tr "[:upper:]" "[:lower:]")"; device_b="sim-scenario-blake-$(uuidgen | tr "[:upper:]" "[:lower:]")"; python3 scripts/run_simulator_scenarios.py --scenario "{{scenario}}" --base-url "{{base}}" --handle-a "{{handle_a}}" --handle-b "{{handle_b}}" --device-id-a "$device_a" --device-id-b "$device_b" && python3 scripts/merged_diagnostics.py --base-url "{{base}}" {{insecure}} --fail-on-violations --device "{{handle_a}}=$device_a" --device "{{handle_b}}=$device_b"'

simulator-scenario-http-control scenario="" base="https://beepbeep.to" handle_a="@avery" handle_b="@blake" insecure="--insecure":
  sh -c 'device_a="sim-scenario-avery-$(uuidgen | tr "[:upper:]" "[:lower:]")"; device_b="sim-scenario-blake-$(uuidgen | tr "[:upper:]" "[:lower:]")"; python3 scripts/run_simulator_scenarios.py --scenario "{{scenario}}" --base-url "{{base}}" --handle-a "{{handle_a}}" --handle-b "{{handle_b}}" --device-id-a "$device_a" --device-id-b "$device_b" --control-command-transport-policy "http-only" && python3 scripts/merged_diagnostics.py --base-url "{{base}}" {{insecure}} --fail-on-violations --device "{{handle_a}}=$device_a" --device "{{handle_b}}=$device_b"'

simulator-scenario-local scenario="" base="http://localhost:8090/s/turbo" handle_a="@avery" handle_b="@blake":
  python3 scripts/run_simulator_scenarios.py \
    --scenario "{{scenario}}" \
    --base-url "{{base}}" \
    --handle-a "{{handle_a}}" \
    --handle-b "{{handle_b}}"

simulator-scenario-merge-local base="http://localhost:8090/s/turbo" handle_a="@avery" handle_b="@blake":
  python3 scripts/merged_diagnostics.py --base-url "{{base}}" --no-telemetry \
    --device "{{handle_a}}=sim-scenario-avery" \
    --device "{{handle_b}}=sim-scenario-blake"

simulator-scenario-merge-local-strict base="http://localhost:8090/s/turbo" handle_a="@avery" handle_b="@blake":
  python3 scripts/merged_diagnostics.py --base-url "{{base}}" --no-telemetry --fail-on-violations \
    --device "{{handle_a}}=sim-scenario-avery" \
    --device "{{handle_b}}=sim-scenario-blake"

simulator-ptt-push channel_id event="transmit-start" active_speaker="@blake" sender_user_id="user-blake" sender_device_id="device-blake" device="booted" bundle_id="com.rounded.Turbo":
  python3 scripts/sim_ptt_push.py \
    --device "{{device}}" \
    --bundle-id "{{bundle_id}}" \
    --event "{{event}}" \
    --channel-id "{{channel_id}}" \
    --active-speaker "{{active_speaker}}" \
    --sender-user-id "{{sender_user_id}}" \
    --sender-device-id "{{sender_device_id}}"

simulator-scenario-suite:
  just simulator-scenario

simulator-scenario-suite-hosted-smoke:
  sh -c 'python3 scripts/run_simulator_scenarios.py --scenario "presence_online_projection,request_accept_ready_refresh_stability" --base-url "https://beepbeep.to" --handle-a "@avery" --handle-b "@blake" --device-id-a "sim-scenario-avery-$(uuidgen | tr "[:upper:]" "[:lower:]")" --device-id-b "sim-scenario-blake-$(uuidgen | tr "[:upper:]" "[:lower:]")"'

simulator-scenario-suite-local:
  just simulator-scenario-local "" http://localhost:8090/s/turbo

simulator-fuzz-local seed count base="http://localhost:8090/s/turbo":
  python3 scripts/run_simulator_fuzz.py run \
    --seed "{{seed}}" \
    --count "{{count}}" \
    --base-url "{{base}}"

simulator-fuzz-local-overnight seed count base="http://localhost:8090/s/turbo":
  python3 scripts/run_simulator_fuzz.py run \
    --seed "{{seed}}" \
    --count "{{count}}" \
    --base-url "{{base}}" \
    --stop-on-first-failure

simulator-fuzz-replay artifact_dir:
  python3 scripts/run_simulator_fuzz.py replay --artifact-dir "{{artifact_dir}}"

simulator-fuzz-shrink artifact_dir:
  python3 scripts/run_simulator_fuzz.py shrink --artifact-dir "{{artifact_dir}}"

production-replay diagnostics_json output_dir="/tmp/turbo-production-replay" name="":
  python3 scripts/convert_production_replay.py \
    --merged-diagnostics-json "{{diagnostics_json}}" \
    --output-dir "{{output_dir}}" \
    --name "{{name}}"

synthetic-conversation-probe base="https://beepbeep.to" caller="@quinn" callee="@sasha" iterations="1" artifact_dir="/tmp/turbo-synthetic-conversation-probe" insecure="--insecure":
  python3 scripts/synthetic_conversation_probe.py \
    --base-url "{{base}}" \
    --caller "{{caller}}" \
    --callee "{{callee}}" \
    --iterations "{{iterations}}" \
    --artifact-dir "{{artifact_dir}}" \
    {{insecure}}

slo-dashboard synthetic_conversation output_dir="/tmp/turbo-slo-dashboard" name="turbo-slo-dashboard":
  python3 scripts/slo_dashboard.py \
    --synthetic-conversation "{{synthetic_conversation}}" \
    --output-dir "{{output_dir}}" \
    --name "{{name}}" \
    --fail-on-breach

protocol-model-checks tla_jar="/tmp/tla2tools.jar" output_dir="/tmp/turbo-protocol-model-checks":
  python3 scripts/protocol_model_check.py \
    --tla-jar "{{tla_jar}}" \
    --output-dir "{{output_dir}}"

protocol-session-generation-model-check tla_jar="/tmp/tla2tools.jar" output_dir="/tmp/turbo-protocol-session-generation-model-check":
  python3 scripts/protocol_model_check.py \
    --module TurboSessionGeneration \
    --config TurboSessionGeneration.cfg \
    --tla-jar "{{tla_jar}}" \
    --output-dir "{{output_dir}}" \
    --skip-swift-properties

swift-test-target name:
  python3 scripts/run_targeted_swift_tests.py --name "{{name}}"

swift-test-suite:
  python3 scripts/run_swift_test_suite.py

reliability-gate-regressions:
  python3 -m py_compile scripts/run_simulator_scenarios.py scripts/run_targeted_swift_tests.py scripts/run_swift_test_suite.py scripts/merged_diagnostics.py scripts/reliability_intake.py scripts/check_invariant_registry.py scripts/convert_production_replay.py scripts/synthetic_conversation_probe.py scripts/slo_dashboard.py scripts/protocol_model_check.py scripts/postdeploy_check.py
  python3 scripts/convert_production_replay.py --merged-diagnostics-json fixtures/production_replay/merged_diagnostics.json --output-dir /tmp/turbo-production-replay-smoke --name fixture_production_replay
  python3 scripts/synthetic_conversation_probe.py --fixture-report fixtures/synthetic_conversation_probe/route_probe_success.json --artifact-dir /tmp/turbo-synthetic-conversation-probe-smoke --iterations 2 --label fixture-smoke
  python3 scripts/slo_dashboard.py --synthetic-conversation /tmp/turbo-synthetic-conversation-probe-smoke/synthetic-conversation-probe.json --output-dir /tmp/turbo-slo-dashboard-smoke --name fixture-slo-dashboard --fail-on-breach
  python3 scripts/protocol_model_check.py --skip-tlc --skip-swift-properties --output-dir /tmp/turbo-protocol-model-checks-static
  python3 scripts/check_invariant_registry.py
  just swift-test-target signalingJoinDriftReassertsRequestedBackendChannelForActiveLocalSession
  just swift-test-target selectedPeerReducerConnectionTimeoutClearsRequesterAutoJoinIdleGap
  just swift-test-target selectedConnectionTimeoutDoesNotInterruptInFlightBackendConnect
  just swift-test-target scenarioBackendExpectationAcceptsReadyWhenPhaseHasProgressed

reliability-gate-smoke:
  just reliability-gate-regressions
  just simulator-scenario-hosted-strict "presence_online_projection,request_accept_ready_refresh_stability,background_wake_refresh_stability"

reliability-gate-full:
  just reliability-gate-regressions
  just simulator-scenario-hosted-strict

reliability-gate-local:
  just reliability-gate-regressions
  just simulator-scenario-suite-local
  just simulator-scenario-merge-local-strict
