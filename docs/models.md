# Models

## Two kinds of model, two different jobs

Quoth uses AI models for two separate jobs:

| Job | What it does | Default | Runs with |
| --- | --- | --- | --- |
| **Speech recognition** | Turns your voice into raw text | OpenAI **Whisper Large v3 Turbo** (open source, MIT) | [whisper.cpp](https://github.com/ggml-org/whisper.cpp) on your Mac |
| **Language model** | Turns raw text into what you meant (cleanup), follows commands, rewrites, writes meeting notes | Alibaba **Qwen 2.5 14B Instruct** (open weights, Apache-2.0) | [llama.cpp](https://github.com/ggml-org/llama.cpp), built into Quoth (or [Ollama](https://ollama.com), if you prefer) |

They aren't interchangeable. Qwen 2.5 is a text model: it can't listen to audio. Whisper only transcribes: it can't follow instructions or rewrite text. So "Qwen instead of Whisper" doesn't work, but you can swap the model **within** each job, and mix where each runs (e.g. local Whisper + a cloud language model).

Some newer models do understand audio (e.g. Qwen's audio models, or OpenAI's `gpt-4o-transcribe`). Any of them that is served through an OpenAI-compatible `/audio/transcriptions` endpoint, in the cloud or by a local server, can be used as Quoth's speech model: choose **Cloud API** under Speech recognition and point the base URL at it.

## Choosing models in the app

Quoth → **Models**:

- **Speech recognition:** choose This Mac or Cloud. For This Mac, pick a Whisper model; ones you don't have show a **Download** button.
- **Language models:** choose where they run:
  - **This Mac (built in):** pick a model file; ones you don't have show a **Download** button. One model does every job.
    - Qwen 2.5 14B (9 GB, for 32 GB+ Macs), Qwen 2.5 7B (4.7 GB, 16 GB) or Qwen 3 4B (2.5 GB, 8 GB), all Apache-2.0, Q4_K_M quantisation.
  - **This Mac (Ollama)** if you already use Ollama, or **Cloud**, then a model per job:
  - **Dictation cleanup** runs on every dictation, so speed matters most.
  - **Command Mode & Transforms** benefits from a smarter model.
  - **Meeting notes** runs after the meeting, so a large model is fine.
- **Download more models:** pull any listed model with progress. Other Ollama models work too: run `ollama pull <name>` and it appears in the pickers.
- **Cloud API:** base URL, API key (stored in your Keychain) and model names.

## Comparing models: Model Lab

Quoth → Models → **Model Lab**. Pick 2–3 models and click Compare.

- **Language models:** runs Quoth's test sentences through each model with the real cleanup rules, plus your latest dictations. Results:
  - A score table per model: exact, same words, serious errors (answered your question, added content, or fell back).
  - Typical time per sentence.
  - Every output side by side.
- **Speech models:** transcribes three short clips with known text, plus your latest recordings. Results:
  - Word error rate per model (the share of words wrong).
  - Time per clip.
  - The transcripts side by side.

The bundled clips are synthetic voices, so real recordings from your History are the better test.

The same comparisons run from the command line: `swift run quoth-eval --model <tag>` (see [Development](development.md)).

## Measured results (M1 Max, 64 GB)

**Language models**, on Quoth's 66-sentence test set (`Evals/cleanup-golden.jsonl`):

| Model | Same words | Serious errors | Typical time | Notes |
| --- | --- | --- | --- | --- |
| Qwen 2.5 14B *(default)* | 61/66 | 0 | ~0.9 s | Best overall |
| Qwen 2.5 7B | 57/64* | 2* | ~0.45 s | Sometimes answers questions or garbles corrections |
| Gemma 3 12B | 57/64* | 0* | ~7 s | Accurate but can't reuse the prompt cache, so slow per dictation |

\* Measured on an earlier version of the set (64 sentences). Re-run them yourself in the Model Lab: on the 19-sentence quick set, 14B scored 14 exact and 7B 11 exact, both with 0 serious errors.

**Speech models**, Model Lab on the bundled clips:

| Model | Word errors | Time per clip |
| --- | --- | --- |
| Whisper Large v3 Turbo (q5) *(default)* | ~9% | ~1.2 s (0.7 s with a pinned language) |
| Whisper Base | ~20% | ~0.15 s |

Key-up to text is typically **about 1.5 s** with the defaults: 0.7 s speech + 0.8 s cleanup. Long dictations take longer, since the language model rewrites every word (about 12 s for 250 words).

## Recommendations by Mac

| Memory | Speech | Cleanup | Commands / meetings |
| --- | --- | --- | --- |
| 8 GB | Whisper Small | Qwen 2.5 3B (non-commercial licence), or cloud | Cloud |
| 16 GB | Whisper Large v3 Turbo | Qwen 2.5 7B | Qwen 2.5 7B |
| 32 GB+ | Whisper Large v3 Turbo | Qwen 2.5 14B | Qwen 2.5 14B or Mistral Small |

`scripts/setup.sh` picks the cleanup model by memory automatically.

## Cloud APIs

Any OpenAI-compatible service works for either job:

| Service | Base URL | Speech model | Language model |
| --- | --- | --- | --- |
| Groq (very fast) | `https://api.groq.com/openai/v1` | `whisper-large-v3-turbo` | `llama-3.3-70b-versatile` |
| OpenAI | `https://api.openai.com/v1` | `gpt-4o-mini-transcribe` | `gpt-4.1-mini` |
| LM Studio / llama.cpp / vLLM (local) | `http://127.0.0.1:<port>/v1` | depends on the server | any loaded model |

With a cloud API your audio and/or text is sent to that provider under their privacy terms. For heavy personal use it typically costs a few dollars a month.

## Licences

| Model | Licence |
| --- | --- |
| Whisper (all sizes) | MIT |
| Qwen 2.5 7B / 14B, Qwen 3 8B, Mistral Small | Apache-2.0 |
| Qwen 2.5 3B | Qwen Research Licence (non-commercial) |
| Llama 3.2 | Llama 3.2 Community Licence |
| Gemma 3 | Gemma Terms of Use |

The models are downloaded from Hugging Face (Whisper, and the GGUF language models) or the Ollama library; Quoth's repository doesn't contain model weights.
