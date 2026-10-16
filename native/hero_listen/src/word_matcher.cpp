#include "word_matcher.h"

#include <algorithm>
#include <cctype>
#include <fstream>
#include <mutex>
#include <sstream>

namespace hero {

namespace {

// Words a child can read correctly but ASR may spell differently.
const std::vector<std::vector<std::string>> kHomophones = {
    {"to", "two", "too", "2"}, {"for", "four", "4"},  {"one", "won", "1"},
    {"no", "know"},            {"right", "write"},    {"eight", "ate", "8"},
    {"there", "their", "they're"}, {"see", "sea", "c"}, {"be", "bee", "b"},
    {"i", "eye"},              {"you", "u"},          {"are", "r"},
    {"why", "y"},              {"by", "buy", "bye"},  {"here", "hear"},
    {"red", "read"},           {"blue", "blew"},      {"new", "knew"},
    {"so", "sew"},             {"sun", "son"},        {"meet", "meat"},
    {"not", "knot"},           {"oh", "o"},           {"okay", "ok"},
    {"zero", "0"},             {"three", "3"},        {"five", "5"},
    {"six", "6"},              {"seven", "7"},        {"nine", "9"},
    {"ten", "10"},
};

const std::unordered_map<std::string, std::string> &canon_table() {
  static const auto table = [] {
    std::unordered_map<std::string, std::string> t;
    for (const auto &group : kHomophones) {
      std::string rep = *std::min_element(group.begin(), group.end());
      for (const auto &w : group) t[w] = rep;
    }
    return t;
  }();
  return table;
}

std::unordered_map<std::string, std::vector<std::string>> &pron() {
  static std::unordered_map<std::string, std::vector<std::string>> d;
  return d;
}
std::mutex pron_mu;

const std::vector<std::string> *phones(const std::string &w) {
  auto it = pron().find(w);
  return it == pron().end() ? nullptr : &it->second;
}

int edit_distance(const std::vector<std::string> &a, const std::vector<std::string> &b) {
  std::vector<int> prev(b.size() + 1), cur(b.size() + 1);
  for (size_t j = 0; j <= b.size(); ++j) prev[j] = int(j);
  for (size_t i = 1; i <= a.size(); ++i) {
    cur[0] = int(i);
    for (size_t j = 1; j <= b.size(); ++j) {
      cur[j] = std::min({prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] != b[j - 1])});
    }
    std::swap(prev, cur);
  }
  return prev[b.size()];
}

}  // namespace

bool WordMatcher::load_pron_dict(const std::string &path) {
  std::lock_guard<std::mutex> lk(pron_mu);
  if (!pron().empty()) return true;
  std::ifstream in(path);
  if (!in.good()) return false;
  std::string line;
  while (std::getline(in, line)) {
    if (line.empty() || line[0] == '#') continue;
    std::istringstream ss(line);
    std::string word, ph;
    ss >> word;
    std::vector<std::string> ps;
    while (ss >> ph) ps.push_back(ph);
    pron()[word] = std::move(ps);
  }
  return !pron().empty();
}

bool WordMatcher::has_pron_dict() { return !pron().empty(); }

std::string WordMatcher::sound_alike(const std::vector<std::string> &toks) const {
  // Accept the on-screen word whose pronunciation is within one phoneme of a
  // heard word. Short (1-2 phoneme) words only tolerate one *extra* sound
  // ("true" for "two"), never a substitution ("go" must not match "no").
  int best_d = 99;
  std::string best;
  bool tie = false;
  for (const auto &t : toks) {
    const auto *pt = phones(t);
    if (!pt) continue;
    for (const auto &w : words_) {
      std::string lw = w;
      for (auto &ch : lw) ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
      const auto *pw = phones(lw);
      if (!pw) continue;
      int d = edit_distance(*pt, *pw);
      int limit = pw->size() <= 2 ? 0 : 1;
      if (pw->size() == 2 && pt->size() == 3 && d == 1) limit = 1;
      if (d > limit) continue;
      if (d < best_d) {
        best_d = d;
        best = w;
        tie = false;
      } else if (d == best_d && w != best) {
        tie = true;
      }
    }
  }
  return tie ? "" : best;
}

std::string WordMatcher::canon(const std::string &word) {
  std::string w;
  for (char ch : word) w += static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
  while (!w.empty() && w.front() == '\'') w.erase(w.begin());
  while (!w.empty() && w.back() == '\'') w.pop_back();
  const auto &t = canon_table();
  auto it = t.find(w);
  return it == t.end() ? w : it->second;
}

std::vector<std::string> WordMatcher::tokenize(const std::string &text) {
  std::vector<std::string> out;
  std::string cur;
  for (size_t i = 0; i < text.size(); ++i) {
    unsigned char ch = static_cast<unsigned char>(text[i]);
    if (std::isalnum(ch) || ch == '\'') {
      cur += static_cast<char>(std::tolower(ch));
    } else if (!cur.empty()) {
      out.push_back(cur);
      cur.clear();
    }
  }
  if (!cur.empty()) out.push_back(cur);
  return out;
}

void WordMatcher::set_words(const std::vector<std::string> &words) {
  words_ = words;
  by_canon_.clear();
  for (const auto &w : words) by_canon_[canon(w)] = w;
}

bool WordMatcher::prefix_ambiguous(const std::string &c) const {
  for (const auto &kv : by_canon_) {
    if (kv.first != c && kv.first.compare(0, c.size(), c) == 0) return true;
  }
  return false;
}

std::string WordMatcher::match(const std::string &text, bool final) const {
  auto toks = tokenize(text);
  for (size_t i = 0; i < toks.size(); ++i) {
    std::string c = canon(toks[i]);
    auto it = by_canon_.find(c);
    if (it == by_canon_.end()) continue;
    bool is_last = i + 1 == toks.size();
    if (final || !is_last || !prefix_ambiguous(c)) return it->second;
  }
  if (final && has_pron_dict()) return sound_alike(toks);
  return "";
}

}  // namespace hero
