# The demo requests, run from the laptop. Not a script to execute in one go:
# copy one block at a time. Every block needs ~/hivenet-demo.env loaded:
#   . ~/hivenet-demo.env
A=HivenetQuant/Qwen3.8-27B
B=HivenetQuant/Qwen3.6-35B-A3B

# --- is the router up, and locked? -------------------------------------------
curl -s $ROUTER/health; echo
curl -s -o /dev/null -w 'no key: %{http_code}\n' $ROUTER/admin/health
curl -s -H "Authorization: Bearer $ADMIN" $ROUTER/admin/health | jq -c '{status, total_agents}'

# --- the fleet ---------------------------------------------------------------
curl -s $ROUTER/v1/models -H "Authorization: Bearer $KEY" | jq -r '.data[].id'
curl -s -H "Authorization: Bearer $ADMIN" $ROUTER/admin/routing-table | jq '.agents[] | {
  model: .metadata.model, replica: .metadata.replica_id,
  healthy: .status.healthy, ok: .universal.successful_requests_total,
  srtt_ms: .universal.srtt_ms, kv_cache: .engine.kv_cache_utilization,
  gpus: [.hardware.gpu[]? | "GPU\(.index) \(.temperature_c)°C \(.power_watts|floor) W \(.vram_used_bytes/1e9|floor) GB"] }'

# --- model A, thinking off ---------------------------------------------------
curl -s $ROUTER/v1/chat/completions -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"HivenetQuant/Qwen3.8-27B","max_tokens":400,
       "chat_template_kwargs":{"enable_thinking":false},
       "messages":[{"role":"system","content":"Answer in plain text, no Markdown."},
         {"role":"user","content":"In three short bullet points: why do companies run open models on their own GPUs?"}]}' \
  | jq -r '"── \(.model) · \(.usage.completion_tokens) tokens ──\n\n\(.choices[0].message.content)\n"' \
  | fold -s -w 100

# --- model B, streamed -------------------------------------------------------
echo "── HivenetQuant/Qwen3.6-35B-A3B · streaming ──"; echo
curl -sN $ROUTER/v1/chat/completions -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"HivenetQuant/Qwen3.6-35B-A3B","stream":true,"max_tokens":400,
       "chat_template_kwargs":{"enable_thinking":false},
       "messages":[{"role":"system","content":"Answer in plain text, no Markdown."},
         {"role":"user","content":"In one paragraph, explain to a non-technical audience how a load balancer decides where to send a request."}]}' \
  | sed -un 's/^data: //p' | grep --line-buffered -v '^\[DONE\]' \
  | jq -j --unbuffered '.choices[0].delta.content // empty' | fold -s -w 100; echo

# --- model A, thinking on: reasoning and answer come back separately ---------
curl -s $ROUTER/v1/chat/completions -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"HivenetQuant/Qwen3.8-27B","max_tokens":2048,
       "messages":[{"role":"system","content":"Answer in plain text, no Markdown."},
         {"role":"user","content":"A train leaves Paris at 14:20 and the trip takes 2 h 55 min. What time does it arrive, and how did you work it out?"}]}' \
  | jq -r '.choices[0].message | "── reasoning (first lines) ──\n\((.reasoning // .reasoning_content // "")[:400])…\n\n── answer ──\n\(.content)\n"' \
  | fold -s -w 100

# --- 20 parallel calls across both models ------------------------------------
( for i in $(seq 1 10); do for m in $A $B; do
    curl -s -o /dev/null -w '%{http_code}\n' $ROUTER/v1/chat/completions \
      -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
      -d '{"model":"'$m'","max_tokens":64,"chat_template_kwargs":{"enable_thinking":false},
           "messages":[{"role":"user","content":"Name three French cheeses."}]}' &
  done; done; wait ) | sort | uniq -c

# --- per-key quota in the response headers -----------------------------------
curl -s -D - -o /dev/null $ROUTER/v1/chat/completions -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"'$A'","max_tokens":16,"chat_template_kwargs":{"enable_thinking":false},
       "messages":[{"role":"user","content":"Hi"}]}' | grep -i '^x-ratelimit'

# --- after stopping agent-35b on the GPU VM: a clean 503 ---------------------
curl -s $ROUTER/v1/chat/completions -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"'$B'","messages":[{"role":"user","content":"Hi"}]}'; echo

# --- the OpenAI SDK: only base_url and key change ----------------------------
python3 - <<'EOF'
import os
from openai import OpenAI
client = OpenAI(base_url=os.environ["ROUTER"] + "/v1", api_key=os.environ["KEY"])
for m in ["HivenetQuant/Qwen3.8-27B", "HivenetQuant/Qwen3.6-35B-A3B"]:
    r = client.chat.completions.create(model=m, max_tokens=120,
        messages=[{"role": "user", "content": "Say hi in French."}],
        extra_body={"chat_template_kwargs": {"enable_thinking": False}})
    print(f"{m:32s} -> {r.choices[0].message.content}")
EOF

# --- the active routing policy (router/policy.yaml) -------------------------
curl -s -H "Authorization: Bearer $ADMIN" $ROUTER/admin/policy | jq '{
  match: .routing_policy.match, gates: .routing_policy.exclude_if,
  strategy: .routing_policy.strategy, fallback: [.fallback_chain[].name] }'

# --- push a stricter policy live: GPUs above 20 °C count as too hot ----------
curl -s -X PUT $ROUTER/admin/policy -H "Authorization: Bearer $ADMIN" \
  -H 'Content-Type: text/yaml' --data-binary @- <<'EOF'
routing_policy:
  match: {organization: "Hivenet Compute"}
  exclude_if: {gpu_temperature_c: {gt: 20}}
  strategy: least-loaded
fallback_chain:
  - {name: any-agent, match: {}, strategy: least-loaded}
EOF
echo
# every GPU is above 20 °C: the primary step empties, the fallback step serves
curl -s -o /dev/null -w '%{http_code}\n' $ROUTER/v1/chat/completions -H "Authorization: Bearer $KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"'$A'","max_tokens":16,"messages":[{"role":"user","content":"Hi"}]}'

# --- on the router VM: which step served each model ---------------------------
#   curl -s localhost:2112/metrics | grep -E '^hivenet_policy_(primary|fallback)_routed_total'

# --- restore the policy from the repo -----------------------------------------
curl -s https://raw.githubusercontent.com/Hivenet-Igor/hivenet-router-demo/main/router/policy.yaml \
  | curl -s -X PUT $ROUTER/admin/policy -H "Authorization: Bearer $ADMIN" \
      -H 'Content-Type: text/yaml' --data-binary @-; echo

# --- bonus: the laptop GPU model ---------------------------------------------
curl -s $ROUTER/v1/chat/completions -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"qwen3:1.7b","max_tokens":200,"reasoning_effort":"none",
       "messages":[{"role":"user","content":"Say hi from a laptop GPU, in one short sentence."}]}' \
  | jq -r '.choices[0].message.content'
