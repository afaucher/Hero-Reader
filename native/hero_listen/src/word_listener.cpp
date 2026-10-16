#include "word_listener.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstring>
#include <fstream>

using namespace godot;

namespace {

constexpr int kSampleRate = 16000;

std::string str(const Dictionary &d, const char *key, const std::string &def = "") {
  if (!d.has(key)) return def;
  return String(d[key]).utf8().get_data();
}

float num(const Dictionary &d, const char *key, float def) {
  return d.has(key) ? float(d[key]) : def;
}

int64_t now_us() {
  return std::chrono::duration_cast<std::chrono::microseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

// sherpa-onnx encodes hotwords with a sentencepiece-style vocab; build one from
// tokens.txt next to it (the model dir must be writable, e.g. under user://).
// Every piece scores -1 so words split into the fewest, longest pieces, which
// is how the model spells them (equal scores spell hotwords letter by letter).
std::string ensure_bpe_vocab(const std::string &tokens, bool *upper) {
  std::ifstream in(tokens);
  std::string vocab = tokens.substr(0, tokens.find_last_of("/\\") + 1) + "_hotwords_bpe.vocab";
  std::string line, all;
  int up = 0, low = 0;
  while (std::getline(in, line)) {
    std::string tok = line.substr(0, line.find(' '));
    if (tok.empty()) continue;
    all += tok + "\t-1\n";
    for (unsigned char c : tok) {
      if (c < 128 && std::isupper(c)) up++;
      if (c < 128 && std::islower(c)) low++;
    }
  }
  *upper = up > low;
  std::ofstream out(vocab);
  out << all;
  return vocab;
}

}  // namespace

WordListener::WordListener() {}

WordListener::~WordListener() {
  stop_worker();
  if (ostream_) SherpaOnnxDestroyOnlineStream(ostream_);
  if (online_) SherpaOnnxDestroyOnlineRecognizer(online_);
  if (offline_) SherpaOnnxDestroyOfflineRecognizer(offline_);
  if (vad_) SherpaOnnxDestroyVoiceActivityDetector(vad_);
  if (resampler_) SherpaOnnxDestroyLinearResampler(resampler_);
}

void WordListener::stop_worker() {
  {
    std::lock_guard<std::mutex> lk(mu_);
    stop_ = true;
  }
  cv_.notify_all();
  if (worker_.joinable()) worker_.join();
}

bool WordListener::load_model(const Dictionary &cfg) {
  if (loaded_) {
    UtilityFunctions::push_error("WordListener: model already loaded");
    return false;
  }
  std::string kind = str(cfg, "kind", "streaming");
  std::string encoder = str(cfg, "encoder"), decoder = str(cfg, "decoder"),
              joiner = str(cfg, "joiner"), tokens = str(cfg, "tokens"),
              model_type = str(cfg, "model_type");
  int threads = int(num(cfg, "threads", 2));
  hotwords_ = cfg.has("hotwords") && bool(cfg["hotwords"]);
  std::string pron_dict = str(cfg, "pron_dict");
  if (!pron_dict.empty() && !hero::WordMatcher::load_pron_dict(pron_dict)) {
    UtilityFunctions::push_warning("WordListener: could not read pron_dict ", pron_dict.c_str());
  }
  std::string bpe_vocab = hotwords_ ? ensure_bpe_vocab(tokens, &upper_tokens_) : "";

  if (kind == "streaming") {
    streaming_ = true;
    SherpaOnnxOnlineRecognizerConfig c;
    std::memset(&c, 0, sizeof(c));
    c.feat_config.sample_rate = kSampleRate;
    c.feat_config.feature_dim = 80;
    c.model_config.transducer.encoder = encoder.c_str();
    c.model_config.transducer.decoder = decoder.c_str();
    c.model_config.transducer.joiner = joiner.c_str();
    c.model_config.tokens = tokens.c_str();
    c.model_config.num_threads = threads;
    c.model_config.provider = "cpu";
    c.model_config.model_type = model_type.c_str();
    c.model_config.modeling_unit = hotwords_ ? "bpe" : "cjkchar";
    c.model_config.bpe_vocab = bpe_vocab.c_str();
    c.decoding_method = hotwords_ ? "modified_beam_search" : "greedy_search";
    c.max_active_paths = int(num(cfg, "beam", 8));
    c.hotwords_score = num(cfg, "hotwords_score", 3.0f);
    c.enable_endpoint = 1;
    c.rule1_min_trailing_silence = 2.4f;
    c.rule2_min_trailing_silence = num(cfg, "trailing_silence", 0.3f);
    c.rule3_min_utterance_length = 20.0f;
    online_ = SherpaOnnxCreateOnlineRecognizer(&c);
    if (!online_) {
      UtilityFunctions::push_error("WordListener: failed to create streaming recognizer");
      return false;
    }
    new_stream();
  } else if (kind == "vad_offline") {
    streaming_ = false;
    family_ = str(cfg, "family", "transducer");
    SherpaOnnxOfflineRecognizerConfig c;
    std::memset(&c, 0, sizeof(c));
    c.feat_config.sample_rate = kSampleRate;
    c.feat_config.feature_dim = 80;
    c.model_config.tokens = tokens.c_str();
    c.model_config.num_threads = threads;
    c.model_config.provider = "cpu";
    c.decoding_method = "greedy_search";
    if (family_ == "transducer") {
      c.model_config.transducer.encoder = encoder.c_str();
      c.model_config.transducer.decoder = decoder.c_str();
      c.model_config.transducer.joiner = joiner.c_str();
      c.model_config.model_type = model_type.empty() ? "nemo_transducer" : model_type.c_str();
      if (hotwords_) {
        c.model_config.modeling_unit = "bpe";
        c.model_config.bpe_vocab = bpe_vocab.c_str();
        c.decoding_method = "modified_beam_search";
        c.max_active_paths = int(num(cfg, "beam", 8));
        c.hotwords_score = num(cfg, "hotwords_score", 1.5f);
      }
    } else if (family_ == "moonshine_v2") {
      c.model_config.moonshine.encoder = encoder.c_str();
      c.model_config.moonshine.merged_decoder = decoder.c_str();
      hotwords_ = false;
    } else if (family_ == "whisper") {
      c.model_config.whisper.encoder = encoder.c_str();
      c.model_config.whisper.decoder = decoder.c_str();
      c.model_config.whisper.language = "en";
      c.model_config.whisper.task = "transcribe";
      c.model_config.whisper.tail_paddings = -1;
      hotwords_ = false;
    } else {
      UtilityFunctions::push_error("WordListener: unknown family ", family_.c_str());
      return false;
    }
    offline_ = SherpaOnnxCreateOfflineRecognizer(&c);
    if (!offline_) {
      UtilityFunctions::push_error("WordListener: failed to create offline recognizer");
      return false;
    }
    std::string vad_model = str(cfg, "vad_model");
    SherpaOnnxVadModelConfig v;
    std::memset(&v, 0, sizeof(v));
    v.silero_vad.model = vad_model.c_str();
    v.silero_vad.threshold = 0.5f;
    v.silero_vad.min_silence_duration = num(cfg, "min_silence", 0.25f);
    v.silero_vad.min_speech_duration = 0.1f;
    v.silero_vad.window_size = 512;
    v.silero_vad.max_speech_duration = 8.0f;
    v.sample_rate = kSampleRate;
    v.num_threads = 1;
    v.provider = "cpu";
    preroll_ = int(num(cfg, "preroll", 0.25f) * kSampleRate);
    vad_ = SherpaOnnxCreateVoiceActivityDetector(&v, 30.0f);
    if (!vad_) {
      UtilityFunctions::push_error("WordListener: failed to create VAD");
      return false;
    }
  } else {
    UtilityFunctions::push_error("WordListener: unknown kind ", kind.c_str());
    return false;
  }
  loaded_ = true;
  stop_ = false;
  worker_ = std::thread(&WordListener::worker_loop, this);
  set_process(true);
  return true;
}

std::string WordListener::hotwords_string() const {
  std::string out;
  for (const auto &w : matcher_.words()) {
    std::string t = w;
    for (auto &ch : t) {
      ch = static_cast<char>(upper_tokens_ ? std::toupper(static_cast<unsigned char>(ch))
                                           : std::tolower(static_cast<unsigned char>(ch)));
    }
    if (!out.empty()) out += "/";
    out += t;
  }
  return out;
}

void WordListener::new_stream() {
  if (ostream_) SherpaOnnxDestroyOnlineStream(ostream_);
  if (hotwords_ && !matcher_.words().empty()) {
    ostream_ = SherpaOnnxCreateOnlineStreamWithHotwords(online_, hotwords_string().c_str());
  } else {
    ostream_ = SherpaOnnxCreateOnlineStream(online_);
  }
  last_text_.clear();
  fired_ = false;
}

void WordListener::set_words(const PackedStringArray &words) {
  std::vector<std::string> w;
  for (int i = 0; i < words.size(); ++i) w.emplace_back(words[i].utf8().get_data());
  {
    std::lock_guard<std::mutex> lk(mu_);
    pending_words_ = std::move(w);
    words_dirty_ = true;
  }
  cv_.notify_all();
}

PackedStringArray WordListener::get_words() const {
  PackedStringArray out;
  for (const auto &w : matcher_.words()) out.push_back(String::utf8(w.c_str()));
  return out;
}

void WordListener::push_frames(const PackedVector2Array &frames, int mix_rate) {
  PackedFloat32Array mono;
  mono.resize(frames.size());
  for (int i = 0; i < frames.size(); ++i) mono.set(i, 0.5f * (frames[i].x + frames[i].y));
  push_samples(mono, mix_rate);
}

void WordListener::push_samples(const PackedFloat32Array &samples, int sample_rate) {
  if (!loaded_ || samples.is_empty()) return;
  const float *x = samples.ptr();
  int n = samples.size();

  // Voice tracking (for latency stats, the level meter and voice_started).
  double e = 0;
  for (int i = 0; i < n; ++i) e += double(x[i]) * x[i];
  float rms = float(std::sqrt(e / n));
  float ms = rms * rms;
  noise_floor_ = ms < noise_floor_ * 4 ? std::min(noise_floor_ * 1.002f, ms) : noise_floor_ * 1.0005f;
  noise_floor_ = std::max(noise_floor_, 1e-9f);
  level_.store(std::min(1.0f, rms * 8.0f));
  bool voiced = ms > std::max(noise_floor_ * 8.0f, 1e-6f);
  if (voiced) {
    last_voice_us_.store(now_us());
    if (!voice_) {
      std::lock_guard<std::mutex> lk(ev_mu_);
      events_.push_back({2, "", "", 0});
    }
  }
  voice_ = voiced;

  if (sample_rate == kSampleRate) {
    enqueue_16k(x, n);
    return;
  }
  if (!resampler_ || resampler_rate_ != sample_rate) {
    if (resampler_) SherpaOnnxDestroyLinearResampler(resampler_);
    resampler_ = SherpaOnnxCreateLinearResampler(sample_rate, kSampleRate, 0, 0);
    resampler_rate_ = sample_rate;
  }
  const SherpaOnnxResampleOut *out = SherpaOnnxLinearResamplerResample(resampler_, x, n, 0);
  enqueue_16k(out->samples, out->n);
  SherpaOnnxLinearResamplerResampleFree(out);
}

void WordListener::enqueue_16k(const float *x, int n) {
  samples_in_ += n;
  {
    std::lock_guard<std::mutex> lk(mu_);
    audio_.insert(audio_.end(), x, x + n);
  }
  cv_.notify_all();
}

void WordListener::flush() {
  {
    std::lock_guard<std::mutex> lk(mu_);
    flush_ = true;
  }
  cv_.notify_all();
}

void WordListener::reset() {
  {
    std::lock_guard<std::mutex> lk(mu_);
    audio_.clear();
    reset_ = true;
  }
  cv_.notify_all();
}

bool WordListener::is_hearing_voice() const {
  return now_us() - last_voice_us_.load() < 150000;
}

void WordListener::emit_event(int type, const std::string &word, const std::string &text) {
  double latency = (now_us() - last_voice_us_.load()) / 1000.0;
  std::lock_guard<std::mutex> lk(ev_mu_);
  events_.push_back({type, word, text, latency});
}

void WordListener::worker_loop() {
  std::vector<float> chunk;
  while (true) {
    bool do_flush = false, do_reset = false;
    {
      std::unique_lock<std::mutex> lk(mu_);
      cv_.wait(lk, [&] { return stop_ || !audio_.empty() || flush_ || words_dirty_ || reset_; });
      if (stop_) return;
      if (words_dirty_) {
        matcher_.set_words(pending_words_);
        words_dirty_ = false;
        do_reset = true;  // a new screen: forget the half-heard previous word
      }
      if (reset_) {
        reset_ = false;
        do_reset = true;
      }
      chunk.assign(audio_.begin(), audio_.end());
      audio_.clear();
      do_flush = flush_;
      flush_ = false;
    }
    auto t0 = now_us();
    if (do_reset) {
      if (streaming_) {
        new_stream();
      } else {
        SherpaOnnxVoiceActivityDetectorReset(vad_);
        vad_carry_.clear();
        history_.clear();
        history_start_ = 0;
      }
    }
    if (!chunk.empty()) {
      if (streaming_) process_streaming(chunk.data(), int(chunk.size()));
      else process_vad(chunk.data(), int(chunk.size()));
    }
    if (do_flush) {
      if (streaming_) {
        std::vector<float> tail(kSampleRate * 6 / 10, 0.0f);
        process_streaming(tail.data(), int(tail.size()));
      } else {
        SherpaOnnxVoiceActivityDetectorFlush(vad_);
        process_vad(nullptr, 0);
      }
    }
    auto dt = now_us() - t0;
    busy_us_ += dt;
    int64_t prev = max_chunk_us_.load();
    while (dt > prev && !max_chunk_us_.compare_exchange_weak(prev, dt)) {
    }
  }
}

void WordListener::process_streaming(const float *x, int n) {
  // Feed in 20 ms steps so partial results are checked as often as a game
  // frame would deliver audio.
  const int step = kSampleRate / 50;
  for (int i = 0; i < n; i += step) {
    int m = std::min(step, n - i);
    SherpaOnnxOnlineStreamAcceptWaveform(ostream_, kSampleRate, x + i, m);
    while (SherpaOnnxIsOnlineStreamReady(online_, ostream_)) {
      SherpaOnnxDecodeOnlineStream(online_, ostream_);
    }
    const SherpaOnnxOnlineRecognizerResult *r = SherpaOnnxGetOnlineStreamResult(online_, ostream_);
    std::string text = r->text ? r->text : "";
    SherpaOnnxDestroyOnlineRecognizerResult(r);
    if (text != last_text_) {
      last_text_ = text;
      if (!fired_) {
        std::string w = matcher_.match(text, false);
        if (!w.empty()) {
          fired_ = true;
          words_heard_++;
          emit_event(0, w, text);
        }
      }
    }
    if (SherpaOnnxOnlineStreamIsEndpoint(online_, ostream_)) {
      if (!fired_ && !last_text_.empty()) {
        std::string w = matcher_.match(last_text_, true);
        if (!w.empty()) {
          words_heard_++;
          emit_event(0, w, last_text_);
        } else {
          other_heard_++;
          emit_event(1, "", last_text_);
        }
      }
      SherpaOnnxOnlineStreamReset(online_, ostream_);
      last_text_.clear();
      fired_ = false;
    }
  }
}

void WordListener::process_vad(const float *x, int n) {
  if (n > 0) {
    vad_carry_.insert(vad_carry_.end(), x, x + n);
    // Keep ~10 s of audio so each segment can be re-cut with lead-in: the VAD
    // only triggers once a word has started, which clips its first consonant.
    history_.insert(history_.end(), x, x + n);
    const size_t keep = kSampleRate * 10;
    if (history_.size() > keep + kSampleRate) {
      size_t drop = history_.size() - keep;
      history_.erase(history_.begin(), history_.begin() + drop);
      history_start_ += int64_t(drop);
    }
  }
  size_t whole = vad_carry_.size() / 512 * 512;
  if (whole) {
    SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad_, vad_carry_.data(), int(whole));
    vad_carry_.erase(vad_carry_.begin(), vad_carry_.begin() + whole);
  }
  while (!SherpaOnnxVoiceActivityDetectorEmpty(vad_)) {
    const SherpaOnnxSpeechSegment *seg = SherpaOnnxVoiceActivityDetectorFront(vad_);
    // Pad: offline models are trained on longer audio than a single word.
    std::vector<float> padded(kSampleRate * 3 / 10, 0.0f);
    int64_t a = int64_t(seg->start) - preroll_ - history_start_;
    int64_t b = int64_t(seg->start) + seg->n - history_start_;
    if (preroll_ > 0 && b > 0 && b <= int64_t(history_.size())) {
      a = std::max<int64_t>(a, 0);
      padded.insert(padded.end(), history_.begin() + a, history_.begin() + b);
    } else {
      padded.insert(padded.end(), seg->samples, seg->samples + seg->n);
    }
    padded.insert(padded.end(), kSampleRate * 3 / 10, 0.0f);
    SherpaOnnxDestroySpeechSegment(seg);
    SherpaOnnxVoiceActivityDetectorPop(vad_);

    const SherpaOnnxOfflineStream *s =
        hotwords_ && !matcher_.words().empty()
            ? SherpaOnnxCreateOfflineStreamWithHotwords(offline_, hotwords_string().c_str())
            : SherpaOnnxCreateOfflineStream(offline_);
    SherpaOnnxAcceptWaveformOffline(s, kSampleRate, padded.data(), int(padded.size()));
    SherpaOnnxDecodeOfflineStream(offline_, s);
    const SherpaOnnxOfflineRecognizerResult *r = SherpaOnnxGetOfflineStreamResult(s);
    std::string text = r->text ? r->text : "";
    SherpaOnnxDestroyOfflineRecognizerResult(r);
    SherpaOnnxDestroyOfflineStream(s);
    if (text.empty()) continue;
    std::string w = matcher_.match(text, true);
    if (!w.empty()) {
      words_heard_++;
      emit_event(0, w, text);
    } else {
      other_heard_++;
      emit_event(1, "", text);
    }
  }
}

void WordListener::poll() {
  std::vector<Event> evs;
  {
    std::lock_guard<std::mutex> lk(ev_mu_);
    evs.swap(events_);
  }
  for (const auto &e : evs) {
    if (e.type == 0) {
      emit_signal("word_heard", String::utf8(e.word.c_str()), String::utf8(e.text.c_str()), e.latency_ms);
    } else if (e.type == 1) {
      emit_signal("heard_other", String::utf8(e.text.c_str()));
    } else {
      emit_signal("voice_started");
    }
  }
}

Dictionary WordListener::get_stats() const {
  Dictionary d;
  double audio_s = samples_in_.load() / double(kSampleRate);
  d["audio_seconds"] = audio_s;
  d["busy_seconds"] = busy_us_.load() / 1e6;
  d["rtf"] = audio_s > 0 ? busy_us_.load() / 1e6 / audio_s : 0.0;
  d["max_chunk_ms"] = max_chunk_us_.load() / 1000.0;
  d["words_heard"] = words_heard_.load();
  d["other_heard"] = other_heard_.load();
  d["streaming"] = streaming_;
  d["hotwords"] = hotwords_;
  return d;
}

void WordListener::_notification(int what) {
  if (what == NOTIFICATION_PROCESS) poll();
}

void WordListener::_bind_methods() {
  ClassDB::bind_method(D_METHOD("load_model", "config"), &WordListener::load_model);
  ClassDB::bind_method(D_METHOD("is_loaded"), &WordListener::is_loaded);
  ClassDB::bind_method(D_METHOD("set_words", "words"), &WordListener::set_words);
  ClassDB::bind_method(D_METHOD("get_words"), &WordListener::get_words);
  ClassDB::bind_method(D_METHOD("push_frames", "frames", "mix_rate"), &WordListener::push_frames);
  ClassDB::bind_method(D_METHOD("push_samples", "samples", "sample_rate"), &WordListener::push_samples);
  ClassDB::bind_method(D_METHOD("flush"), &WordListener::flush);
  ClassDB::bind_method(D_METHOD("reset"), &WordListener::reset);
  ClassDB::bind_method(D_METHOD("poll"), &WordListener::poll);
  ClassDB::bind_method(D_METHOD("get_level"), &WordListener::get_level);
  ClassDB::bind_method(D_METHOD("is_hearing_voice"), &WordListener::is_hearing_voice);
  ClassDB::bind_method(D_METHOD("get_stats"), &WordListener::get_stats);

  ADD_SIGNAL(MethodInfo("word_heard", PropertyInfo(Variant::STRING, "word"),
                        PropertyInfo(Variant::STRING, "heard_text"),
                        PropertyInfo(Variant::FLOAT, "latency_ms")));
  ADD_SIGNAL(MethodInfo("heard_other", PropertyInfo(Variant::STRING, "heard_text")));
  ADD_SIGNAL(MethodInfo("voice_started"));
}
