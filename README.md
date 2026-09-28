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
| Router VM | Docker, git, openssl | HTTPS `8888` (API), `3000` (Grafana) · TCP `9001` (gRPC), `9000` (libp2p) |
| GPU VM | NVIDIA driver, Docker, NVIDIA Container Toolkit, git, Python | none |
| Laptop | curl, jq, Python with `openai` · Docker + NVIDIA runtime for the bonus | none |

The agents read GPU temperature, power and memory through the NVIDIA container runtime, so nothing else is needed for telemetry. `gpu/install-nvidia-toolkit.sh` installs the toolkit if your image lacks it.

On Compute with Hivenet, set these when you create the router VM: HTTPS ports `8888, 3000` and TCP ports `9000, 9001`. Each HTTPS port is published as `https://<instance-id>-<port>.<location>.tenants.hivecompute.ai`.

## Run it

Clone this repository on the two VMs:

```bash
git clone https://github.com/Hivenet-Igor/hivenet-router-demo.git ~/hivenet-router-demo
```

**1 · GPU VM, before the demo** (the weights are ~45 GB):

```bash
cd ~/hivenet-router-demo/gpu
./prepare.sh
docker compose up -d vllm-27b vllm-35b      # a few minutes to load
```

**2 · Router VM.** Pass the public IP the GPU VM can reach, and the HTTPS URL of port 8888:

```bash
cd ~/hivenet-router-demo/router
./up.sh <router-public-ip> https://<instance-id>-8888.<location>.tenants.hivecompute.ai
```

If your cloud publishes TCP 9001 and 9000 on other ports (Compute with Hivenet shows them as `<instance-id>-TCP.tenants.hivecompute.ai <port>`), pass the host and the public ports:

```bash
GRPC_PUBLIC_PORT=<port-for-9001> P2P_PUBLIC_PORT=<port-for-9000> \
  ./up.sh <instance-id>-TCP.tenants.hivecompute.ai https://<instance-id>-8888.<location>.tenants.hivecompute.ai
```

It creates the secrets (agent secret, client API key, admin key, Grafana password), starts the router, Prometheus and Grafana, and prints two blocks: one to paste on the GPU VM, one to paste on the laptop.

**3 · GPU VM.** Paste the first block, then start the agents:

```bash
cd ~/hivenet-router-demo/gpu
docker compose up -d agent-27b agent-35b
docker compose logs -f agent-27b agent-35b   # look for "Registration successful"
```

**4 · Laptop.** Paste the second block, then try the requests in [`laptop/requests.sh`](laptop/requests.sh), one block at a time. For example:

```bash
curl -s $ROUTER/v1/chat/completions -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"HivenetQuant/Qwen3.6-35B-A3B","max_tokens":200,
       "chat_template_kwargs":{"enable_thinking":false},
       "messages":[{"role":"user","content":"Write a haiku about GPUs."}]}' \
  | jq -r '.choices[0].message.content'
```

**Bonus · laptop GPU.** With the laptop block loaded:

```bash
cd laptop/bonus && ./up.sh
```

## Models and serving settings

| | Qwen3.8 27B | Qwen3.6 35B-A3B |
|---|---|---|
| Checkpoint | [`HivenetQuant/Qwen3.8-27B-NVFP4`](https://huggingface.co/HivenetQuant/Qwen3.8-27B-NVFP4) | [`HivenetQuant/Qwen3.6-35B-A3B-NVFP4`](https://huggingface.co/HivenetQuant/Qwen3.6-35B-A3B-NVFP4) |
| Type | dense, NVFP4 W4A4 | MoE (3B active), NVFP4 W4A16 |
| vLLM | `v0.26.0`, TP2 | `v0.25.1`, TP2 |
| Context | 262,144 tokens, FP8 KV cache | 262,144 tokens, FP8 KV cache |

Both are reasoning models with thinking on by default. Send `"chat_template_kwargs":{"enable_thinking":false}` for a direct answer. The W4A4 kernel needs a Blackwell GPU (RTX 5090 class).

## Clean up

```bash
# GPU VM
cd ~/hivenet-router-demo/gpu && docker compose down
# router VM
cd ~/hivenet-router-demo/router && docker compose down
# laptop
cd laptop/bonus && docker compose down
```

This demo uses a single static API key and opens the admin API with an admin key. For production setups, see the [Hivenet Router documentation](https://routerdocs.hivenet.com).

## License

Apache 2.0. The Grafana dashboards in `router/grafana/dashboards` come from [Hivenet Router](https://github.com/HivenetOSS/hivenet_router), also Apache 2.0.
