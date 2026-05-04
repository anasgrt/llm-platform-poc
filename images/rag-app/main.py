"""Log Analysis RAG Application.

Flow:
  1. User asks a question about logs
  2. Embed the question via embedding service
  3. Search Qdrant for similar log chunks
  4. Return a fast deterministic summary by default
  5. Optionally send compact context to Qwen when USE_LLM=true

Environment variables:
  QWEN3_URL     — llama.cpp server (default: http://qwen3-server:8080)
  EMBED_URL     — embedding service (default: http://embedding-server:8080)
  QDRANT_URL    — Qdrant REST API (default: http://qdrant:6333)
  COLLECTION    — Qdrant collection name (default: logs)
  USE_LLM       — set true to use Qwen generation instead of Fast RAG
"""

import json
import os
import httpx
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse, StreamingResponse
from pydantic import BaseModel
import traceback

app = FastAPI(title="Log Analysis Platform")

@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    error_msg = f"{type(exc).__name__}: {str(exc)}"
    if isinstance(exc, httpx.RequestError):
        error_msg += f" (Request URL: {exc.request.url})"
    if isinstance(exc, httpx.HTTPStatusError):
        try:
            error_msg += f" - Response: {exc.response.text}"
        except:
            pass
    print(f"500 Internal Server Error: {error_msg}")
    traceback.print_exc()
    return JSONResponse(
        status_code=500,
        content={"detail": error_msg}
    )

QWEN3_URL = os.getenv("QWEN3_URL", "http://qwen3-server:8080")
EMBED_URL = os.getenv("EMBED_URL", "http://embedding-server:8080")
QDRANT_URL = os.getenv("QDRANT_URL", "http://qdrant:6333")
COLLECTION = os.getenv("COLLECTION", "logs")
TOP_K = int(os.getenv("TOP_K", "3"))
MAX_CONTEXT_CHARS = int(os.getenv("MAX_CONTEXT_CHARS", "600"))
MAX_TOKENS = int(os.getenv("MAX_TOKENS", "48"))
QWEN3_TIMEOUT = float(os.getenv("QWEN3_TIMEOUT", "180"))
USE_LLM = os.getenv("USE_LLM", "false").strip().lower() in {"1", "true", "yes", "on"}

# Shared HTTP client. Keep dependency checks bounded; give CPU inference its own
# longer request timeout in generate_analysis().
client = httpx.Client(timeout=httpx.Timeout(connect=5.0, read=60.0, write=30.0, pool=5.0))

SYSTEM_PROMPT = (
    "You are a DevOps log analyst. Use only LOGS. Reply in at most three "
    "short bullets: recurring error, likely cause, next fix. Mention source "
    "or timestamp when present. If unclear, say so."
)


class QueryRequest(BaseModel):
    question: str
    top_k: int = TOP_K


class QueryResponse(BaseModel):
    answer: str
    sources: list[dict]
    num_chunks_used: int


# ── Step 1: Embed the query ──────────────────────────────────────────────────

def embed_text(text: str) -> list[float]:
    """Send text to embedding service, get back a vector."""
    resp = client.post(f"{EMBED_URL}/embed", json={"texts": [text]})
    resp.raise_for_status()
    return resp.json()["embeddings"][0]


# ── Step 2: Search Qdrant for similar log chunks ─────────────────────────────

def search_logs(vector: list[float], top_k: int) -> list[dict]:
    """Query Qdrant for the most similar log chunks."""
    resp = client.post(
        f"{QDRANT_URL}/collections/{COLLECTION}/points/search",
        json={
            "vector": vector,
            "limit": top_k,
            "with_payload": True,
        },
    )
    resp.raise_for_status()
    results = resp.json().get("result", [])
    return [
        {
            "text": r["payload"]["text"],
            "source": r["payload"].get("source", "unknown"),
            "level": r["payload"].get("level", "info"),
            "timestamp": r["payload"].get("timestamp", ""),
            "score": r["score"],
        }
        for r in results
    ]


# ── Step 3: Build prompt with log context ────────────────────────────────────

def build_prompt(question: str, log_chunks: list[dict]) -> str:
    """Build a compact prompt.

    CPU-only llama.cpp under VirtualBox is very sensitive to prompt size, so
    this keeps retrieved context bounded and avoids the verbose chat template.
    """
    remaining = MAX_CONTEXT_CHARS
    context_parts = []
    for c in log_chunks:
        if remaining <= 0:
            break
        text = c["text"].strip()
        if len(text) > remaining:
            text = text[:remaining].rstrip() + "\n...[truncated]"
        remaining -= len(text)
        context_parts.append(
            f"Source={c['source']} Level={c['level']} Time={c['timestamp']}\n{text}"
        )
    context_block = "\n\n".join(
        context_parts
    )
    return (
        f"{SYSTEM_PROMPT}\n\n"
        f"LOGS:\n{context_block}\n\n"
        f"QUESTION: {question}\n"
        f"ANSWER:\n"
    )


# ── Step 4: Call Qwen3 via llama.cpp OpenAI API ──────────────────────────────

def generate_analysis(prompt: str) -> str:
    """Send the prompt to Qwen3 and return the full completion.

    Non-streaming because llama-cpp-python's streaming path is unreliable in
    this build. The prompt is deliberately compact so CPU inference returns.
    """
    resp = client.post(
        f"{QWEN3_URL}/v1/completions",
        json={
            "prompt": prompt,
            "max_tokens": MAX_TOKENS,
            "temperature": 0.3,
            "stream": False,
            "stop": ["<|im_end|>", "<|im_start|>"],
        },
        timeout=QWEN3_TIMEOUT,
    )
    resp.raise_for_status()
    return resp.json()["choices"][0]["text"].strip()


def fast_log_analysis(question: str, log_chunks: list[dict]) -> str:
    """Return a bounded deterministic summary without blocking on CPU LLM inference."""
    priority = {"FATAL": 0, "ERROR": 1, "WARN": 2, "INFO": 3, "DEBUG": 4}
    ranked = sorted(log_chunks, key=lambda c: priority.get(c["level"], 9))
    error_lines = []

    for chunk in ranked:
        for line in chunk["text"].splitlines():
            upper = line.upper()
            if chunk["level"] in {"FATAL", "ERROR", "WARN"} or any(
                marker in upper for marker in ("FATAL", "ERROR", "WARN", "CRASH", "FAIL", "TIMEOUT", "OOM")
            ):
                error_lines.append((chunk, line.strip()))

    if not error_lines:
        sources = ", ".join(sorted({c["source"] for c in log_chunks}))
        return (
            f"- No explicit ERROR/FATAL lines were found in the top retrieved chunks from {sources}.\n"
            "- The retrieved context is mostly informational or warning-level; broaden the query or re-run ingestion if expected errors are missing.\n"
            "- Next check: inspect the source logs around the returned timestamps for adjacent failures."
        )

    top_chunk, top_line = error_lines[0]
    affected_sources = ", ".join(sorted({chunk["source"] for chunk, _ in error_lines}))
    levels = ", ".join(sorted({chunk["level"] for chunk, _ in error_lines}, key=lambda x: priority.get(x, 9)))
    evidence = "\n".join(f"  - {line[:180]}" for _, line in error_lines[:3])

    return (
        f"- Recurring severity in retrieved logs: {levels} from {affected_sources}.\n"
        f"- Strongest match: {top_chunk['source']} {top_chunk['level']} {top_chunk['timestamp']} -> {top_line[:220]}\n"
        f"- Evidence:\n{evidence}\n"
        "- Next fix: inspect the named service/pod around these timestamps, then correlate adjacent WARN/FATAL lines for the first failure in the chain."
    )


# ── API Endpoints ────────────────────────────────────────────────────────────

def _ndjson(event_type: str, **fields) -> str:
    return json.dumps({"type": event_type, **fields}) + "\n"


@app.post("/api/analyze")
def analyze_logs(req: QueryRequest):
    """Streaming RAG endpoint — emits NDJSON events as the answer is generated."""

    def event_stream():
        try:
            yield _ndjson("status", data="Retrieving relevant log chunks...")
            query_vector = embed_text(req.question)
            log_chunks = search_logs(query_vector, req.top_k)

            if not log_chunks:
                yield _ndjson("token", data="No relevant log entries found. Have you run the ingestion job?")
                yield _ndjson("done", sources=[], num_chunks_used=0)
                return

            if USE_LLM:
                yield _ndjson("status", data=f"Generating analysis from {len(log_chunks)} retrieved chunks...")
                prompt = build_prompt(req.question, log_chunks)
                answer = generate_analysis(prompt)
            else:
                yield _ndjson("status", data=f"Summarizing {len(log_chunks)} retrieved chunks...")
                answer = fast_log_analysis(req.question, log_chunks)

            if answer:
                yield _ndjson("token", data=answer)
            else:
                yield _ndjson("error", data="Analysis returned an empty result.")
                return

            yield _ndjson("done", sources=log_chunks, num_chunks_used=len(log_chunks))
        except httpx.HTTPStatusError as e:
            body = ""
            try:
                body = e.response.text[:500]
            except Exception:
                pass
            yield _ndjson("error", data=f"{type(e).__name__}: {e} - {body}")
        except httpx.RequestError as e:
            yield _ndjson("error", data=f"{type(e).__name__}: {e} (Request URL: {e.request.url})")
        except Exception as e:
            traceback.print_exc()
            yield _ndjson("error", data=f"{type(e).__name__}: {e}")

    return StreamingResponse(event_stream(), media_type="application/x-ndjson")


@app.get("/health")
def health():
    """Health check — verifies connectivity to all backends."""
    status = {"rag_app": "ok", "mode": "llm" if USE_LLM else "fast_rag"}
    checks = [
        ("qwen3", f"{QWEN3_URL}/v1/models"),
        ("embed", f"{EMBED_URL}/health"),
        ("qdrant", f"{QDRANT_URL}/healthz"),
    ]
    for name, url in checks:
        try:
            r = client.get(url, timeout=5.0)
            status[name] = "ok" if r.status_code == 200 else f"status:{r.status_code}"
        except Exception as e:
            status[name] = f"error: {type(e).__name__}"
    return status


# ── Chat UI ──────────────────────────────────────────────────────────────────

_MODEL_NAME_CACHE: str | None = None


def get_model_name() -> str:
    """Fetch the served model id from qwen3-server and cache it.

    llama.cpp returns the model file path (e.g. /models/Qwen3-4B-Q4_K_M.gguf);
    we strip the directory and the .gguf suffix so the badge stays compact.
    """
    global _MODEL_NAME_CACHE
    if _MODEL_NAME_CACHE:
        return _MODEL_NAME_CACHE
    try:
        r = client.get(f"{QWEN3_URL}/v1/models", timeout=5.0)
        r.raise_for_status()
        data = r.json().get("data", [])
        if data:
            mid = str(data[0].get("id", ""))
            name = os.path.basename(mid)
            if name.endswith(".gguf"):
                name = name[: -len(".gguf")]
            if name:
                _MODEL_NAME_CACHE = name
                return name
    except Exception:
        pass
    return "model unavailable"


CHAT_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Log Analysis — __MODEL_NAME__</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:system-ui,-apple-system,sans-serif;background:#0f1117;color:#e0e0e0;height:100vh;display:flex;flex-direction:column}
header{padding:16px 24px;border-bottom:1px solid #1e2130;display:flex;align-items:center;gap:12px}
header h1{font-size:18px;font-weight:500;color:#fff}
header span{font-size:12px;background:#2a4a3a;color:#4ade80;padding:2px 10px;border-radius:99px}
.chat{flex:1;overflow-y:auto;padding:24px;display:flex;flex-direction:column;gap:16px}
.msg{max-width:720px;padding:14px 18px;border-radius:12px;font-size:14px;line-height:1.7;white-space:pre-wrap}
.msg.user{background:#1e3a5f;align-self:flex-end;color:#bfdbfe}
.msg.bot{background:#1e2130;align-self:flex-start;border:1px solid #2a2d3a}
.msg.bot .sources{margin-top:12px;padding-top:10px;border-top:1px solid #2a2d3a;font-size:12px;color:#888}
.input-bar{padding:16px 72px 16px 24px;border-top:1px solid #1e2130;display:flex;gap:10px}
.input-bar input{flex:1;background:#1a1d2e;border:1px solid #2a2d3a;color:#fff;padding:12px 16px;border-radius:10px;font-size:14px;outline:none}
.input-bar input:focus{border-color:#3b82f6}
.input-bar button{background:#3b82f6;color:#fff;border:none;padding:12px 24px;border-radius:10px;cursor:pointer;font-size:14px;font-weight:500;min-width:118px}
.input-bar button:disabled{opacity:.4;cursor:not-allowed}
.spinner{display:inline-block;width:16px;height:16px;border:2px solid #444;border-top-color:#3b82f6;border-radius:50%;animation:spin .6s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
</style>
</head>
<body>
<header>
  <h1>Log Analysis Platform</h1>
  <span>__MODEL_NAME__</span>
</header>
<div class="chat" id="chat">
  <div class="msg bot">Ready. Ask me about your logs — errors, patterns, root causes, correlations.<br><br>
Examples:<br>• What errors keep recurring?<br>• Why are pods crashlooping?<br>• Summarize the NGINX 5xx errors<br>• What happened around 03:14 UTC?</div>
</div>
<form class="input-bar" id="form" autocomplete="off">
  <input id="q" placeholder="Ask about your logs..." autofocus>
  <button id="btn" type="submit">Analyze</button>
</form>
<script>
const chat=document.getElementById('chat'),form=document.getElementById('form'),q=document.getElementById('q'),btn=document.getElementById('btn');
let busy=false;
form.addEventListener('submit',send);
btn.addEventListener('click',send);
q.addEventListener('keydown',e=>{
  if(e.key==='Enter'&&!e.shiftKey){
    e.preventDefault();
    if(form.requestSubmit) form.requestSubmit(); else send(e);
  }
});
async function send(e){
  if(e) e.preventDefault();
  if(busy)return;
  const text=q.value.trim(); if(!text)return;
  busy=true; q.value=''; btn.disabled=true;
  chat.innerHTML+=`<div class="msg user">${esc(text)}</div>`;
  const bubble=document.createElement('div');
  bubble.className='msg bot';
  const body=document.createElement('span');
  const status=document.createElement('span');
  status.innerHTML='<div class="spinner"></div> Retrieving logs...';
  bubble.appendChild(body); bubble.appendChild(status);
  chat.appendChild(bubble); chat.scrollTop=chat.scrollHeight;
  let answer='';
  try{
    const r=await fetch('/api/analyze',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({question:text})});
    if(!r.ok){
      let detail=''; try{ detail=(await r.json()).detail||''; }catch(_){}
      throw new Error(detail||('HTTP '+r.status));
    }
    const reader=r.body.getReader(), decoder=new TextDecoder();
    let buf='';
    while(true){
      const {value,done}=await reader.read();
      if(done) break;
      buf+=decoder.decode(value,{stream:true});
      const lines=buf.split('\\n'); buf=lines.pop();
      for(const line of lines){
        if(!line.trim()) continue;
        let evt; try{ evt=JSON.parse(line); }catch(_){ continue; }
        if(evt.type==='token'){
          if(status){ status.remove(); }
          answer+=evt.data;
          body.textContent=answer;
        } else if(evt.type==='status'){
          status.textContent=evt.data;
        } else if(evt.type==='done'){
          if(evt.sources&&evt.sources.length){
            const src=document.createElement('div');
            src.className='sources';
            src.textContent=`Based on ${evt.num_chunks_used} log chunks from: ${[...new Set(evt.sources.map(s=>s.source))].join(', ')}`;
            bubble.appendChild(src);
          }
        } else if(evt.type==='error'){
          bubble.innerHTML='Error: '+esc(evt.data);
        }
      }
      chat.scrollTop=chat.scrollHeight;
    }
  }catch(e){bubble.innerHTML='Error: '+esc(e.message)}
  busy=false; btn.disabled=false; q.focus(); chat.scrollTop=chat.scrollHeight;
}
window.send=send;
function esc(s){return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')}
</script>
</body></html>"""


@app.get("/", response_class=HTMLResponse)
def ui():
    html = CHAT_HTML.replace("__MODEL_NAME__", get_model_name())
    return HTMLResponse(
        html,
        headers={
            "Cache-Control": "no-store, max-age=0",
            "Pragma": "no-cache",
        },
    )
