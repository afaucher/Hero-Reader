// WordListener: a Godot node that listens for the words currently on screen.
//
//   var l := WordListener.new()
//   l.load_model({"kind": "streaming", "dir": ..., ...})
//   l.set_words(["cat", "dog", "sun"])
//   l.word_heard.connect(_on_word_heard)   # (word, heard_text, latency_ms)
//   # every frame: l.push_frames(capture.get_buffer(n), mix_rate)
//
// Recognition runs on a worker thread with sherpa-onnx; signals are emitted
// on the main thread from _process (or from poll() if you drive it yourself).
#pragma once

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "sherpa-onnx/c-api/c-api.h"
#include "word_matcher.h"

namespace godot {

class WordListener : public Node {
  GDCLASS(WordListener, Node)

 public:
  WordListener();
  ~WordListener() override;

  // Model setup. Keys (paths are absolute filesystem paths, not res://):
  //   kind:        "streaming" (zipformer/NeMo transducer) or "vad_offline"
  //   family:      vad_offline only: "transducer" | "moonshine_v2" | "whisper"
  //   encoder, decoder, joiner, tokens: model files
  //   model_type:  "" or "nemo_transducer"
  //   hotwords:    bool, bias decoding toward on-screen words (transducers)
  //   vad_model:   silero_vad.onnx (vad_offline)
  //   min_silence: VAD hang-over seconds (default 0.25)
  //   preroll:     seconds of lead-in added before each VAD segment (0.25)
  //   beam:        beam width when hotwords are on (default 8)
  //   hotwords_score: boost (default 3.0 streaming, 1.5 vad_offline)
  //   pron_dict:   pronunciation dictionary enabling sound-alike matches
  //   threads:     inference threads (default 2)
  bool load_model(const Dictionary &config);
  bool is_loaded() const { return loaded_; }

  void set_words(const PackedStringArray &words);
  PackedStringArray get_words() const;

  // Audio input. push_frames takes AudioEffectCapture output (stereo).
  void push_frames(const PackedVector2Array &frames, int mix_rate);
  void push_samples(const PackedFloat32Array &samples, int sample_rate);
  // Mark end of input (tests / end of level): flushes pending speech.
  void flush();
  // Drop queued audio and any half-heard word (e.g. between levels).
  void reset();

  // Emit queued signals now. Called automatically from _process.
  void poll();

  // Recent input loudness 0..1, for a "listening" meter on the cannon.
  float get_level() const { return level_.load(); }
  bool is_hearing_voice() const;
  Dictionary get_stats() const;

 protected:
  static void _bind_methods();
  void _notification(int what);

 private:
  struct Event {
    int type;  // 0 = word, 1 = other speech, 2 = voice start
    std::string word, text;
    double latency_ms;
  };
  using Clock = std::chrono::steady_clock;

  void worker_loop();
  void process_streaming(const float *x, int n);
  void process_vad(const float *x, int n);
  void new_stream();
  std::string hotwords_string() const;
  void emit_event(int type, const std::string &word, const std::string &text);
  void enqueue_16k(const float *x, int n);
  void stop_worker();

  // config
  bool loaded_ = false;
  bool streaming_ = true;
  bool hotwords_ = false;
  bool upper_tokens_ = false;
  std::string family_;

  // sherpa-onnx handles
  const SherpaOnnxOnlineRecognizer *online_ = nullptr;
  const SherpaOnnxOnlineStream *ostream_ = nullptr;
  const SherpaOnnxOfflineRecognizer *offline_ = nullptr;
  const SherpaOnnxVoiceActivityDetector *vad_ = nullptr;
  const SherpaOnnxLinearResampler *resampler_ = nullptr;
  int resampler_rate_ = 0;

  // worker state (guarded by mu_)
  std::thread worker_;
  mutable std::mutex mu_;
  std::condition_variable cv_;
  std::deque<float> audio_;
  bool stop_ = false;
  bool flush_ = false;
  bool words_dirty_ = false;
  bool reset_ = false;
  std::vector<std::string> pending_words_;
  std::vector<std::string> current_words_;  // copy for get_words() (guarded by mu_)

  // worker-only
  hero::WordMatcher matcher_;
  std::string last_text_;
  std::vector<std::string> fired_;  // words already zapped this utterance
  bool hotwords_stale_ = false;      // streaming: rebuild stream when idle
  std::vector<float> vad_carry_;
  std::vector<float> history_;  // recent 16 kHz audio for VAD lead-in
  int64_t history_start_ = 0;   // sample index of history_[0]
  int preroll_ = 0;

  // events to main thread
  std::mutex ev_mu_;
  std::vector<Event> events_;

  // voice tracking for latency + level meter (main thread writes)
  std::atomic<float> level_{0.0f};
  std::atomic<int64_t> last_voice_us_{0};
  float noise_floor_ = 1e-4f;
  bool voice_ = false;

  // stats
  std::atomic<int64_t> samples_in_{0};
  std::atomic<int64_t> busy_us_{0};
  std::atomic<int64_t> max_chunk_us_{0};
  std::atomic<int> words_heard_{0};
  std::atomic<int> other_heard_{0};
};

}  // namespace godot
