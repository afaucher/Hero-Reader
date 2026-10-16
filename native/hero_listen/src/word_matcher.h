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

  static std::vector<std::string> tokenize(const std::string &text);
  static std::string canon(const std::string &word);

  // Optional: pronunciation dictionary ("word PH ON ES" per line) enabling
  // sound-alike matching on final results, e.g. heard "true" -> "two" when
  // "two" is on screen. Loaded once and shared by all matchers.
  static bool load_pron_dict(const std::string &path);
  static bool has_pron_dict();

 private:
  bool prefix_ambiguous(const std::string &c) const;
  std::string sound_alike(const std::vector<std::string> &toks) const;
  std::vector<std::string> words_;
  std::unordered_map<std::string, std::string> by_canon_;
};

}  // namespace hero
