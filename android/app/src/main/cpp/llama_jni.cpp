// JNI bridge between LlamaEngine.kt and llama.cpp: greedy chat completion for text cleanup.
//
// The cleanup prompt starts with a long static part (system prompt + examples) that is the same for
// every dictation. It's decoded once and kept: attention-only models just drop the tokens after it,
// recurrent/hybrid models (whose state can't be truncated) restore a snapshot taken right after it.
#include <jni.h>
#include <android/log.h>
#include <atomic>
#include <chrono>
#include <string>
#include <vector>
#include "llama.h"

#define LOG_TAG "QuothLlama"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

namespace {

struct Engine {
    llama_model *model = nullptr;
    llama_context *ctx = nullptr;
    llama_sampler *sampler = nullptr;
    std::string tmpl;
    bool thinks = false;      // hybrid-thinking template (Qwen 3/3.5): switched off with an empty <think></think>
    bool snapshots = false;   // recurrent or hybrid: restore a saved state instead of truncating
    std::vector<llama_token> prefix;   // the static prompt part currently decoded (or snapshotted)
    std::vector<uint8_t> snapshot;
    std::atomic<bool> abort{false};
};

long long nowMs() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}

std::string jstr(JNIEnv *env, jstring s) {
    const char *c = env->GetStringUTFChars(s, nullptr);
    std::string out(c);
    env->ReleaseStringUTFChars(s, c);
    return out;
}

// JNI strings are modified UTF-8; take the text as UTF-8 bytes instead so emoji survive.
std::string jbytes(JNIEnv *env, jbyteArray a) {
    jsize n = env->GetArrayLength(a);
    std::string out(n, '\0');
    env->GetByteArrayRegion(a, 0, n, reinterpret_cast<jbyte *>(out.data()));
    return out;
}

std::string applyTemplate(const Engine &e, const std::vector<llama_chat_message> &msgs, bool addAssistant) {
    std::vector<char> buf(16 * 1024);
    int n = llama_chat_apply_template(e.tmpl.c_str(), msgs.data(), msgs.size(), addAssistant, buf.data(), (int) buf.size());
    if (n > (int) buf.size()) {
        buf.resize(n);
        n = llama_chat_apply_template(e.tmpl.c_str(), msgs.data(), msgs.size(), addAssistant, buf.data(), (int) buf.size());
    }
    return n < 0 ? std::string() : std::string(buf.data(), n);
}

std::vector<llama_token> tokenize(const Engine &e, const std::string &text, bool addSpecial) {
    const llama_vocab *vocab = llama_model_get_vocab(e.model);
    int n = -llama_tokenize(vocab, text.data(), (int) text.size(), nullptr, 0, addSpecial, true);
    std::vector<llama_token> out(n);
    if (llama_tokenize(vocab, text.data(), (int) text.size(), out.data(), n, addSpecial, true) < 0) out.clear();
    return out;
}

bool decode(Engine &e, std::vector<llama_token> &tokens) {
    const int batch = (int) llama_n_batch(e.ctx);
    for (size_t i = 0; i < tokens.size(); i += batch) {
        int n = (int) std::min<size_t>(batch, tokens.size() - i);
        if (llama_decode(e.ctx, llama_batch_get_one(tokens.data() + i, n)) != 0) return false;
    }
    return true;
}

}  // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_app_quoth_android_LlamaEngine_nativeLoad(JNIEnv *env, jclass, jstring path, jint nCtx, jint threads) {
    static bool backend = false;
    if (!backend) { llama_backend_init(); backend = true; }
    auto *e = new Engine();
    llama_model_params mp = llama_model_default_params();
    mp.n_gpu_layers = 0;
    e->model = llama_model_load_from_file(jstr(env, path).c_str(), mp);
    if (!e->model) { delete e; return 0; }
    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = nCtx;
    cp.n_batch = 512;
    cp.n_threads = threads;
    cp.n_threads_batch = threads;
    e->ctx = llama_init_from_model(e->model, cp);
    if (!e->ctx) { llama_model_free(e->model); delete e; return 0; }
    llama_set_abort_callback(e->ctx, [](void *data) { return static_cast<Engine *>(data)->abort.load(); }, e);
    e->sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(e->sampler, llama_sampler_init_greedy());
    const char *t = llama_model_chat_template(e->model, nullptr);
    e->tmpl = t ? t : "chatml";
    e->thinks = e->tmpl.find("enable_thinking") != std::string::npos;
    e->snapshots = llama_model_is_recurrent(e->model) || llama_model_is_hybrid(e->model);
    LOGI("loaded: %.2fB params, ctx %d, threads %d, thinks %d, snapshots %d",
         llama_model_n_params(e->model) / 1e9, nCtx, threads, e->thinks, e->snapshots);
    return reinterpret_cast<jlong>(e);
}

extern "C" JNIEXPORT void JNICALL
Java_app_quoth_android_LlamaEngine_nativeFree(JNIEnv *, jclass, jlong h) {
    auto *e = reinterpret_cast<Engine *>(h);
    if (!e) return;
    llama_sampler_free(e->sampler);
    llama_free(e->ctx);
    llama_model_free(e->model);
    delete e;
}

extern "C" JNIEXPORT void JNICALL
Java_app_quoth_android_LlamaEngine_nativeAbort(JNIEnv *, jclass, jlong h) {
    if (h) reinterpret_cast<Engine *>(h)->abort = true;
}

// Chat completion. roles/contents are the messages (contents as UTF-8 bytes); the last one is the
// dictation-specific user message, everything before it is the cacheable static part.
// Returns the reply as UTF-8 bytes, or null on failure or abort.
extern "C" JNIEXPORT jbyteArray JNICALL
Java_app_quoth_android_LlamaEngine_nativeComplete(JNIEnv *env, jclass, jlong h, jobjectArray roles,
                                                  jobjectArray contents, jint maxTokens) {
    auto *e = reinterpret_cast<Engine *>(h);
    e->abort = false;
    const long long t0 = nowMs();

    const jsize n = env->GetArrayLength(roles);
    std::vector<std::string> r(n), c(n);
    std::vector<llama_chat_message> msgs(n);
    for (jsize i = 0; i < n; ++i) {
        r[i] = jstr(env, (jstring) env->GetObjectArrayElement(roles, i));
        c[i] = jbytes(env, (jbyteArray) env->GetObjectArrayElement(contents, i));
    }
    for (jsize i = 0; i < n; ++i) msgs[i] = {r[i].c_str(), c[i].c_str()};

    std::string full = applyTemplate(*e, msgs, true);
    std::string head = n > 1 ? applyTemplate(*e, std::vector<llama_chat_message>(msgs.begin(), msgs.end() - 1), false) : "";
    if (full.empty()) return nullptr;
    if (full.compare(0, head.size(), head) != 0) head.clear();  // template doesn't split cleanly: no cache
    if (e->thinks) full += "<think>\n\n</think>\n\n";

    std::vector<llama_token> prefix = tokenize(*e, head, true);
    std::vector<llama_token> rest = tokenize(*e, full.substr(head.size()), head.empty());
    llama_memory_t mem = llama_get_memory(e->ctx);

    bool cached = !prefix.empty() && prefix == e->prefix;
    if (cached && !e->snapshots) {
        cached = llama_memory_seq_rm(mem, 0, (llama_pos) prefix.size(), -1);
    } else if (cached) {
        llama_memory_seq_rm(mem, 0, -1, -1);
        cached = llama_state_seq_set_data(e->ctx, e->snapshot.data(), e->snapshot.size(), 0) > 0;
    }
    if (!cached) {
        e->prefix.clear();
        llama_memory_clear(mem, true);
        if (!prefix.empty()) {
            if (!decode(*e, prefix)) return nullptr;
            if (e->snapshots) {
                e->snapshot.resize(llama_state_seq_get_size(e->ctx, 0));
                llama_state_seq_get_data(e->ctx, e->snapshot.data(), e->snapshot.size(), 0);
            }
            e->prefix = prefix;
        }
    }
    const long long t1 = nowMs();
    if (prefix.size() + rest.size() + maxTokens > llama_n_ctx(e->ctx)) {
        LOGI("prompt too long: %zu + %zu + %d tokens", prefix.size(), rest.size(), maxTokens);
        return nullptr;
    }
    if (!decode(*e, rest)) return nullptr;
    const long long t2 = nowMs();

    const llama_vocab *vocab = llama_model_get_vocab(e->model);
    std::string out;
    int generated = 0;
    for (; generated < maxTokens && !e->abort; ++generated) {
        llama_token tok = llama_sampler_sample(e->sampler, e->ctx, -1);
        if (llama_vocab_is_eog(vocab, tok)) break;
        char piece[256];
        int len = llama_token_to_piece(vocab, tok, piece, sizeof piece, 0, false);
        if (len > 0) out.append(piece, len);
        if (llama_decode(e->ctx, llama_batch_get_one(&tok, 1)) != 0) break;
    }
    const long long t3 = nowMs();
    LOGI("timing prefix=%zu tokens %s %lldms, prompt=%zu tokens %lldms, output=%d tokens %lldms",
         prefix.size(), cached ? "cached" : "decoded", t1 - t0, rest.size(), t2 - t1, generated, t3 - t2);
    if (e->abort) return nullptr;

    jbyteArray result = env->NewByteArray((jsize) out.size());
    env->SetByteArrayRegion(result, 0, (jsize) out.size(), reinterpret_cast<const jbyte *>(out.data()));
    return result;
}
