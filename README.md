# Hivenet Router demo

Run two open models on one GPU machine, put [Hivenet Router](https://github.com/HivenetOSS/hivenet_router) on another machine, and call both models through a single OpenAI-compatible endpoint from anywhere. Optionally, add the GPU in your laptop from behind your home router.

Everything runs in Docker. The GPU machines never open an inbound port: each agent dials out to the router, and the router sends requests back over that same connection.

```
 laptop (client)                router VM                          GPU VM · 4x RTX 5090
 ───────────────                ─────────                          ─────────────────────
 curl / OpenAI SDK ──HTTPS──▶  :8888  hivenet-router  ◀──TCP 9001──  agent-27b ─▶ vLLM Qwen3.8-27B     (GPU 0,1)
 browser ──────────HTTPS──▶  :3000  Grafana          ◀──TCP 9000──  agent-35b ─▶ vLLM Qwen3.6-35B-A3B (GPU 2,3)
 laptop GPU (bonus) ──────────────────────────────────▶ same two ports   agent-laptop ─▶ Ollama qwen3:1.7b
```

## What each machine needs

| Machine | Needs | Inbound ports |
|---|---|---|
| Router VM | Docker, git, openssl (`router/setup.sh`) | HTTPS `8888` (API), `3000` (Grafana) · TCP `9001` (gRPC), `9000` (libp2p) |
| GPU VM | NVIDIA driver, then `gpu/setup.sh` adds Docker, NVIDIA Container Toolkit, git, pip | none |
| Laptop | curl, jq, Python with `openai` · Docker + NVIDIA runtime for the bonus | none |

The agents read GPU temperature, power and memory through the NVIDIA container runtime, so nothing else is needed for telemetry. `router/setup.sh` and `gpu/setup.sh` install whatever is missing (Docker, the Compose plugin, the NVIDIA Container Toolkit) without prompts, reboots or service restarts; the GPU one refuses to restart Docker while containers are running.

On Compute with Hivenet, set these when you create the router VM: HTTPS ports `8888, 3000` and TCP ports `9000, 9001`. Each HTTPS port is published as `https://<instance-id>-<port>.<location>.tenants.hivecompute.ai`.

## Run it

Clone this repository on the two VMs:

```bash
git clone https://github.com/Hivenet-Igor/hivenet-router-demo.git ~/hivenet-router-demo \
  || git -C ~/hivenet-router-demo pull       # already cloned: update it
```

**1 · GPU VM, before the demo** (the weights are ~45 GB):

```bash
cd ~/hivenet-router-demo/gpu
./setup.sh        # installs what is missing
./prepare.sh      # checks GPUs and ports, downloads the weights
docker compose up -d vllm-27b vllm-35b      # a few minutes to load
```

**2 · Router VM.** Pass the public IP the GPU VM can reach, and the HTTPS URL of port 8888:

```bash
cd ~/hivenet-router-demo/router
./setup.sh        # installs Docker if missing
./up.sh <router-public-ip> https://<instance-id>-8888.<location>.tenants.hivecompute.ai
```

If your cloud publishes TCP 9001 and 9000 on other ports (Compute with Hivenet shows them as `<instance-id>-TCP.tenants.hivecompute.ai <port>`), pass the host and the public ports:

```bash
GRPC_PUBLIC_PORT=<port-for-9001> P2P_PUBLIC_PORT=<port-for-9000> \
  ./up.sh <instance-id>-TCP.tenants.hivecompute.ai https://<instance-id>-8888.<location>.tenants.hivecompute.ai
```

It creates the secrets (agent secret, client API key, admin key, a random Grafana password; set `GRAFANA_PASSWORD=...` to choose it), starts the router, Prometheus and Grafana, and prints two blocks: one to paste on the GPU VM, one to paste on the laptop.

**3 · GPU VM.** Paste the first block, then start the agents:

```bash
cd ~/hivenet-router-demo/gpu
./agents.sh      # checks .env and the router, starts both agents, waits until registered
```

**4 · Laptop.** Paste the second block, then try the requests in [`laptop/requests.sh`](laptop/requests.sh), one block at a time. For example:

```bash
curl -s $ROUTER/v1/chat/completions -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"HivenetQuant/Qwen3.6-35B-A3B","max_tokens":200,
       "chat_template_kwargs":{"enable_thinking":false},
       "messages":[{"role":"user","content":"In one paragraph, explain how a load balancer decides where to send a request."}]}' \
  | jq -r '.choices[0].message.content'
```

**Bonus · laptop GPU.** With the laptop block loaded:

```bash
cd laptop/bonus && ./up.sh
```

## Routing policy

The router loads [`router/policy.yaml`](router/policy.yaml): a primary step that only uses the agents on the GPU VM (`organization: Hivenet Compute`) and skips any agent whose KV cache, engine queue, GPU temperature, success rate or failure streak crosses a threshold; least-loaded ranking; a front-door shed that answers 429 when the whole pool is saturated; and a fallback step, `any-agent`, that takes everything else, such as the laptop GPU in the bonus.

You can read and replace it live with `GET` and `PUT /admin/policy` (see [`laptop/requests.sh`](laptop/requests.sh)), and the router's metrics show which step served each model (`hivenet_policy_primary_routed_total`, `hivenet_policy_fallback_routed_total`). Policy reference: [routerdocs.hivenet.com](https://routerdocs.hivenet.com/routing/policy-yaml-reference).

## Models and serving settings

| | Qwen3.8 27B | Qwen3.6 35B-A3B |
|---|---|---|
| Checkpoint | [`HivenetQuant/Qwen3.8-27B-NVFP4`](https://huggingface.co/HivenetQuant/Qwen3.8-27B-NVFP4) | [`HivenetQuant/Qwen3.6-35B-A3B-NVFP4`](https://huggingface.co/HivenetQuant/Qwen3.6-35B-A3B-NVFP4) |
| Type | dense, NVFP4 W4A4 | MoE (3B active), NVFP4 W4A16 |
| vLLM | `v0.30.0`, TP2 | `v0.30.0`, TP2 |
| Context | 262,144 tokens, FP8 KV cache | 262,144 tokens, FP8 KV cache |

Both run on vLLM `v0.30.0`. To use another version, set it when starting: `VLLM_VERSION=v0.26.0 docker compose up -d vllm-27b vllm-35b`.

Both are reasoning models with thinking on by default. Send `"chat_template_kwargs":{"enable_thinking":false}` for a direct answer. The W4A4 kernel needs a Blackwell GPU (RTX 5090 class).

## Clean up

This removes every container and gives the router a clean state: its routing table, per-key usage and quota counters, the Prometheus samples and the Grafana state are wiped, so the next demo starts at zero. Model weights (`~/models`), images, keys (`router/secrets`), agent identities (`gpu/ids`) and Ollama's model stay, so the next start downloads nothing.

Use `-v` on the router VM only. On the laptop it would delete Ollama's model. Do not run `docker system prune` or `docker rmi`, they delete images.

```bash
# GPU VM
cd ~/hivenet-router-demo/gpu && docker compose down
# router VM: also wipes history and metrics
cd ~/hivenet-router-demo/router
docker compose down -v
docker volume prune -f      # unnamed volumes left by earlier runs
# laptop
cd laptop/bonus && docker compose down
```

This demo uses a single static API key and opens the admin API with an admin key. For production setups, see the [Hivenet Router documentation](https://routerdocs.hivenet.com).

## License

Apache 2.0. The Grafana dashboards in `router/grafana/dashboards` come from [Hivenet Router](https://github.com/HivenetOSS/hivenet_router), also Apache 2.0.
