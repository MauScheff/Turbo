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
  sh -c 'cd {{justfile_directory()}} && ucm run turbo/main:.turbo.serveHttpLocal'

serve-local:
  sh -c 'cd {{justfile_directory()}} && ucm run turbo/main:.turbo.serveLocal'

prod-probe:
  .venv/bin/python scripts/prod_probe.py --base-url https://beepbeep.to --caller @quinn --callee @sasha --insecure

smoke-probe:
  .venv/bin/python scripts/smoke_beepbeep.py --base-url https://beepbeep.to --caller @quinn --callee @sasha --insecure

route-probe:
  .venv/bin/python scripts/route_probe.py --base-url https://beepbeep.to --caller @quinn --callee @sasha --insecure

clean-scratch:
  find . -maxdepth 1 -type f \( -name 'scratch_*.u' -o -name 'scratch-*.u' \) -print -delete

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

simulator-scenario scenario="" base="https://beepbeep.to" handle_a="@avery" handle_b="@blake" insecure="--insecure":
  rm -f .scenario-runtime-config.json
  TURBO_SCENARIO_FILTER="{{scenario}}" TURBO_SCENARIO_BASE_URL="{{base}}" TURBO_SCENARIO_HANDLE_A="{{handle_a}}" TURBO_SCENARIO_HANDLE_B="{{handle_b}}" python3 -c 'import json, os, time; json.dump({"enabledUntilEpochSeconds": time.time() + 600, "filter": os.environ["TURBO_SCENARIO_FILTER"], "baseURL": os.environ["TURBO_SCENARIO_BASE_URL"], "handleA": os.environ["TURBO_SCENARIO_HANDLE_A"], "handleB": os.environ["TURBO_SCENARIO_HANDLE_B"], "deviceIDA": "sim-scenario-avery", "deviceIDB": "sim-scenario-blake"}, open(".scenario-runtime-config.json", "w", encoding="utf-8"))'
  xcodebuild -project Turbo.xcodeproj -scheme BeepBeep \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.4' \
    -only-testing:TurboTests \
    -skip-testing:TurboUITests \
    -derivedDataPath /tmp/turbo-dd-simulator-scenario \
    test CODE_SIGNING_ALLOWED=NO
  rm -f .scenario-runtime-config.json

simulator-scenario-merge base="https://beepbeep.to" handle_a="@avery" handle_b="@blake" insecure="--insecure":
  python3 scripts/merged_diagnostics.py --base-url "{{base}}" {{insecure}} \
    --device "{{handle_a}}=sim-scenario-avery" \
    --device "{{handle_b}}=sim-scenario-blake"

simulator-scenario-local scenario="" base="http://localhost:8081/s/turbo" handle_a="@avery" handle_b="@blake":
  rm -f .scenario-runtime-config.json
  TURBO_SCENARIO_FILTER="{{scenario}}" TURBO_SCENARIO_BASE_URL="{{base}}" TURBO_SCENARIO_HANDLE_A="{{handle_a}}" TURBO_SCENARIO_HANDLE_B="{{handle_b}}" python3 -c 'import json, os, time; json.dump({"enabledUntilEpochSeconds": time.time() + 600, "filter": os.environ["TURBO_SCENARIO_FILTER"], "baseURL": os.environ["TURBO_SCENARIO_BASE_URL"], "handleA": os.environ["TURBO_SCENARIO_HANDLE_A"], "handleB": os.environ["TURBO_SCENARIO_HANDLE_B"], "deviceIDA": "sim-scenario-avery", "deviceIDB": "sim-scenario-blake"}, open(".scenario-runtime-config.json", "w", encoding="utf-8"))'
  xcodebuild -project Turbo.xcodeproj -scheme BeepBeep \
    -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.4' \
    -only-testing:TurboTests \
    -skip-testing:TurboUITests \
    -derivedDataPath /tmp/turbo-dd-simulator-scenario \
    test CODE_SIGNING_ALLOWED=NO
  rm -f .scenario-runtime-config.json

simulator-scenario-merge-local base="http://localhost:8081/s/turbo" handle_a="@avery" handle_b="@blake":
  python3 scripts/merged_diagnostics.py --base-url "{{base}}" \
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
  just simulator-scenario request_decline
  just simulator-scenario request_cancel_before_accept
  just simulator-scenario request_accept_ready
  just simulator-scenario request_accept_ready_disconnect_initiator
  just simulator-scenario request_accept_ready_disconnect_receiver

simulator-scenario-suite-local:
  just simulator-scenario-local request_decline http://localhost:8080/s/turbo
  just simulator-scenario-local request_cancel_before_accept http://localhost:8080/s/turbo
  just simulator-scenario-local request_accept_ready http://localhost:8080/s/turbo
  just simulator-scenario-local request_accept_ready_disconnect_initiator http://localhost:8080/s/turbo
  just simulator-scenario-local request_accept_ready_disconnect_receiver http://localhost:8080/s/turbo

backend-check: venv prod-probe
