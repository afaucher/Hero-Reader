// Closed-set matcher: which of the on-screen words (if any) is in an ASR
// hypothesis? Mirrors stt-eval/matcher.py so the benchmark numbers carry over.
#pragma once

#include <string>
#include <unordered_map>
#include <vector>

namespace hero {

class WordMatcher {
 public:
  void set_words(const std::vector<std::string> &words);
  const std::vector<std::string> &words() const { return words_; }

  // Returns the matched on-screen word (original spelling) or "".
  // For partial hypotheses (final=false) the last token is only accepted if
  // no other on-screen word starts with it ("on" could still become "one").
  std::string match(const std::string &text, bool final) const;
  // Every distinct on-screen word in `text`, in spoken order (a child may
  // read several words in one breath). Same partial-result rule as match().
  std::vector<std::string> match_all(const std::string &text, bool final) const;

  // Debug view of one on-screen word against a hypothesis: how (or how
  // nearly) it matched. Diagnostic only; match_all() decides what fires.
  struct WordScore {
    std::string word;
    std::string kind;    // "exact", "homophone", "sound_alike", "wait" (partial,
                         // could still become a longer word) or "" (no match)
    std::string token;   // heard token that matched, or the closest-sounding one
    int distance = -1;   // phoneme edit distance to `token` (-1: not in pron dict)
    std::string word_phones, token_phones;
  };
  std::vector<WordScore> explain(const std::string &text, bool final) const;

  static std::vector<std::string> tokenize(const std::string &text);
  static std::string canon(const std::string &word);

  // Optional: pronunciation dictionary ("word PH ON ES" per line) enabling
  // sound-alike matching on final results, e.g. heard "true" -> "two" when
  // "two" is on screen. Loaded once and shared by all matchers.
  static bool load_pron_dict(const std::string &path);
  static bool has_pron_dict();

  // Which near misses sound-alike accepts (stt-eval/matcher.py SOUND_ALIKE_MODE):
  //   "any":        one phoneme off; 1-2 phoneme words: one extra sound
  //   "no-onset":   same, but the first sound must match ("hat" is not "cat")
  //   "extra-only": only one extra sound after the first ("cats" for "cat",
  //                 "true" for "two"). The default.
  // Returns false (and keeps the current mode) for an unknown name.
  bool set_sound_alike_mode(const std::string &mode);
  const std::string &sound_alike_mode() const { return mode_; }

 private:
  bool prefix_ambiguous(const std::string &c) const;
  std::string sound_alike(const std::vector<std::string> &toks) const;
  std::vector<std::string> words_;
  std::unordered_map<std::string, std::string> by_canon_;
  std::string mode_ = "extra-only";
};

}  // namespace hero
