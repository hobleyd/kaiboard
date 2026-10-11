// C interface to the Rust text engine (core/src/ffi.rs).

#ifndef KAIBOARD_CORE_H
#define KAIBOARD_CORE_H

#include <stdint.h>

typedef struct KBEngine KBEngine;

KBEngine *kb_engine_new(void);
void kb_engine_free(KBEngine *engine);

// Returns the suggestion bar for the text before the cursor as JSON:
//   {"mode": "complete" | "next", "current": str, "context": str,
//    "sentence": str, "sentenceStart": bool,
//    "suggestions": [{"text", "replace", "insert", "kind", "ai", "auto"}]}
// `ai_words` is the language model's newline-separated answer for the same
// text, or NULL if there is none yet; `ai_fix` its optional proofread copy of
// "sentence". The result must be released with kb_string_free.
char *kb_suggest(const KBEngine *engine, const char *before, const char *ai_words, const char *ai_fix,
                 uint32_t limit);

// Decodes a finger path swiped across the letter keys into a JSON array of the
// words it most likely spells, best first. `xy` holds `points` (x, y) pairs: x
// in key widths from the left edge of the top letter row, y in rows from its
// top edge. The result must be released with kb_string_free.
char *kb_swipe(const KBEngine *engine, const char *before, const float *xy, uint32_t points, uint32_t limit);

// JSON array of real words a slip of the thumb away from `word`, most common
// first. Release with kb_string_free.
char *kb_neighbours(const KBEngine *engine, const char *word, uint32_t limit);
// Tidies newline-separated words proposed as replacements for `selected` into
// a JSON array: single words, no repeats, capitalised like `selected`. Release
// with kb_string_free.
char *kb_replacements(const KBEngine *engine, const char *selected, const char *proposed, uint32_t limit);

// Records the word just completed at the end of `before`.
void kb_learn(KBEngine *engine, const char *before);
// Marks a word as correctly spelled.
void kb_learn_word(KBEngine *engine, const char *word);

// Learned words as text for persistence; release with kb_string_free.
char *kb_export(const KBEngine *engine);
void kb_import(KBEngine *engine, const char *data);

void kb_string_free(char *s);

#endif
