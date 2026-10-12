//! Turns the text before the cursor, plus whatever the language model has
//! proposed for it, into the contents of the suggestion bar.

use crate::context::{self, is_apostrophe, Context};
use crate::dict::Dict;
use crate::distance::{adjacent, typo_cost};
use std::collections::HashMap;

/// Apostrophe-less spellings that are almost always meant as contractions.
const FIXUPS: &[(&str, &str)] = &[
    ("im", "I'm"), ("ive", "I've"), ("dont", "don't"), ("doesnt", "doesn't"), ("didnt", "didn't"),
    ("cant", "can't"), ("wont", "won't"), ("isnt", "isn't"), ("arent", "aren't"), ("wasnt", "wasn't"),
    ("werent", "weren't"), ("havent", "haven't"), ("hasnt", "hasn't"), ("hadnt", "hadn't"),
    ("wouldnt", "wouldn't"), ("couldnt", "couldn't"), ("shouldnt", "shouldn't"), ("thats", "that's"),
    ("whats", "what's"), ("theres", "there's"), ("heres", "here's"), ("youre", "you're"),
    ("youve", "you've"), ("youll", "you'll"), ("youd", "you'd"), ("theyre", "they're"),
    ("theyve", "they've"), ("theyll", "they'll"), ("weve", "we've"), ("hes", "he's"), ("shes", "she's"),
    ("itll", "it'll"), ("thatll", "that'll"), ("wouldve", "would've"), ("couldve", "could've"),
    ("shouldve", "should've"), ("aint", "ain't"), ("yall", "y'all"), ("oclock", "o'clock"),
];

const CONTRACTION_SUFFIXES: &[&str] = &["s", "re", "ve", "ll", "d", "m", "t"];

/// Real words that get swapped for one another. The model may propose
/// replacing one with another even though they are not near-misses on the keys.
const CONFUSABLES: &[&[&str]] = &[
    &["their", "there", "they're"], &["your", "you're"], &["its", "it's"], &["to", "too", "two"],
    &["then", "than"], &["affect", "effect"], &["lose", "loose"], &["whose", "who's"],
    &["were", "we're", "where"], &["accept", "except"], &["hear", "here"], &["know", "no", "now"],
    &["weather", "whether"], &["a", "an"], &["peace", "piece"], &["brake", "break"], &["of", "off"],
    &["quite", "quiet"], &["passed", "past"], &["bought", "brought"], &["by", "buy", "bye"],
];

/// Valid words the keyboard accepts but never volunteers.
const NO_SUGGEST: &[&str] = &[
    "sex", "sexy", "sexual", "porn", "porno", "fuck", "fucking", "fucked", "shit", "nude", "pussy",
    "anal", "cock", "dick", "cum", "tits", "boobs", "ass", "bitch", "slut", "whore", "xxx",
];

const SENTENCE_STARTERS: &[&str] = &["I", "The", "Thanks"];

/// How many nats of word frequency one unit of typo cost is worth.
const TYPO_WEIGHT: f32 = 4.5;
/// Words rarer than this are never auto-corrected to.
const AUTOCORRECT_MIN_LOGP: f32 = -13.5;
/// An unknown word typed this many times is treated as a real word.
/// How far below the best completion a respelling may score and still be auto-applied.
const AUTOCORRECT_MARGIN: f32 = 2.0;
const LEARNED_AFTER: u32 = 2;
const MAX_WORD_CHARS: usize = 24;
const MAX_USER_ENTRIES: usize = 4000;

const SCORE_CERTAIN: f32 = 200.0;
const SCORE_AI: f32 = 100.0;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mode {
    /// The cursor is inside a word: offer completions and corrections.
    Complete,
    /// The cursor follows a space: offer next words.
    Next,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    /// The word exactly as typed.
    Verbatim,
    Completion,
    Correction,
    Next,
    /// Replaces the previous, already committed word.
    Fix,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Verbatim => "verbatim",
            Kind::Completion => "completion",
            Kind::Correction => "correction",
            Kind::Next => "next",
            Kind::Fix => "fix",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Suggestion {
    /// What the bar shows.
    pub text: String,
    /// Text immediately before the cursor that accepting this replaces.
    pub replace: String,
    pub insert: String,
    pub kind: Kind,
    /// Proposed by the language model rather than the local lexicon.
    pub ai: bool,
    /// Applied automatically if the user just keeps typing.
    pub auto: bool,
}

#[derive(Debug)]
pub struct Output {
    pub mode: Mode,
    pub current: String,
    /// Text to show the language model.
    pub context: String,
    /// The unfinished sentence the model is asked to proofread.
    pub sentence: String,
    pub sentence_start: bool,
    pub suggestions: Vec<Suggestion>,
}

/// The language model's answer for the same text `suggest` is called with.
#[derive(Default, Debug)]
pub struct AiHints {
    /// In `Complete` mode, the words the user probably means; in `Next` mode,
    /// likely next words. Most likely first.
    pub words: Vec<String>,
    /// In `Next` mode, the model's proofread copy of `Output::sentence`.
    pub fix: Option<String>,
}

struct UserWord {
    spelling: String,
    count: u32,
}

pub struct Engine {
    dict: &'static Dict,
    user_words: HashMap<String, UserWord>,
    /// previous word -> following word -> times typed, all lowercase.
    user_bigrams: HashMap<String, HashMap<String, u32>>,
}

struct Candidate {
    spelling: String,
    score: f32,
    kind: Kind,
    ai: bool,
    /// Set when this is a credible auto-correction; higher wins.
    auto: Option<f32>,
}

#[derive(Default)]
struct Pool(HashMap<String, Candidate>);

impl Pool {
    fn add(&mut self, lower: &str, cand: Candidate) {
        match self.0.get_mut(lower) {
            None => {
                self.0.insert(lower.to_string(), cand);
            }
            Some(old) => {
                let (ai, auto) = (old.ai || cand.ai, max_opt(old.auto, cand.auto));
                if cand.score > old.score {
                    *old = cand;
                }
                old.ai = ai;
                old.auto = auto;
            }
        }
    }

    fn ranked(self) -> Vec<Candidate> {
        let mut all: Vec<_> = self.0.into_values().collect();
        all.sort_by(|a, b| b.score.total_cmp(&a.score).then_with(|| a.spelling.cmp(&b.spelling)));
        all
    }
}

fn max_opt(a: Option<f32>, b: Option<f32>) -> Option<f32> {
    match (a, b) {
        (Some(a), Some(b)) => Some(a.max(b)),
        (a, b) => a.or(b),
    }
}

/// Lowercases and straightens typographic apostrophes.
fn normalize(word: &str) -> String {
    word.chars().map(|c| if is_apostrophe(c) { '\'' } else { c }).flat_map(char::to_lowercase).collect()
}

fn capitalize(word: &str) -> String {
    let mut chars = word.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

/// Gives `word` the capitalisation pattern the user typed.
fn apply_case(typed: &str, word: &str) -> String {
    let mut letters = typed.chars().filter(|c| c.is_alphabetic());
    let Some(first) = letters.next() else { return word.to_string() };
    if !first.is_uppercase() {
        return word.to_string();
    }
    let mut rest = letters.peekable();
    if rest.peek().is_some() && rest.all(char::is_uppercase) {
        word.to_uppercase()
    } else {
        capitalize(word)
    }
}

fn max_cost(len: usize) -> f32 {
    match len {
        0..=3 => 1.0,
        4..=5 => 1.6,
        _ => 2.0,
    }
}

fn blocked(lower: &str) -> bool {
    NO_SUGGEST.contains(&lower)
}

fn fixup(lower: &str) -> Option<&'static str> {
    FIXUPS.iter().find(|&&(from, _)| from == lower).map(|&(_, to)| to)
}

fn confusable(a: &str, b: &str) -> bool {
    CONFUSABLES.iter().any(|group| group.contains(&a) && group.contains(&b))
}

/// Cheap filter run before the edit-distance computation: slips rarely change
/// the first letter into anything but a neighbouring key or the second letter.
fn plausible_start(typed: &[u8], word: &[u8]) -> bool {
    typed[0] == word[0]
        || adjacent(typed[0], word[0])
        || word.get(1) == Some(&typed[0])
        || typed.get(1) == Some(&word[0])
}

/// Whether `word` could be what someone who has typed `typed` so far means.
/// Guards against the model answering with something unrelated to the keys
/// actually pressed.
fn related(typed: &str, word: &str) -> bool {
    if word.starts_with(typed) {
        return true;
    }
    if !typed.is_ascii() || !word.is_ascii() {
        return false;
    }
    let (t, w) = (typed.as_bytes(), word.as_bytes());
    if typo_cost(t, w, max_cost(t.len())).is_some() {
        return true;
    }
    // A longer word whose beginning was mistyped.
    t.len() >= 3
        && (t.len() - 1..=t.len() + 1).any(|cut| cut <= w.len() && typo_cost(t, &w[..cut], 1.0).is_some())
}

/// Reduces a model-produced string to a single plain word, if it contains one.
fn clean(raw: &str) -> Option<String> {
    // The model sometimes escapes apostrophes as if writing JSON by hand.
    let raw = raw.replace('\\', "");
    let token = raw.split_whitespace().next()?;
    let token = token.trim_matches(|c: char| !c.is_alphanumeric());
    let plain = token.chars().all(|c| c.is_alphabetic() || is_apostrophe(c) || c == '-');
    let len = token.chars().count();
    (plain && (1..=MAX_WORD_CHARS).contains(&len)).then(|| token.replace('\u{2019}', "'"))
}

fn learnable(lower: &str) -> bool {
    let len = lower.chars().count();
    (1..=MAX_WORD_CHARS).contains(&len) && lower.chars().all(|c| c.is_alphabetic() || c == '\'')
}

impl Default for Engine {
    fn default() -> Self {
        Self::new()
    }
}

impl Engine {
    pub fn new() -> Engine {
        Engine { dict: Dict::get(), user_words: HashMap::new(), user_bigrams: HashMap::new() }
    }

    fn builtin_known(&self, lower: &str) -> bool {
        if self.dict.contains(lower) || FIXUPS.iter().any(|&(_, to)| to.eq_ignore_ascii_case(lower)) {
            return true;
        }
        match lower.split_once('\'') {
            Some((stem, suffix)) => CONTRACTION_SUFFIXES.contains(&suffix) && self.is_known(stem),
            None => false,
        }
    }

    fn is_known(&self, lower: &str) -> bool {
        self.builtin_known(lower) || self.user_words.get(lower).is_some_and(|w| w.count >= LEARNED_AFTER)
    }

    /// Preferred spelling of a lowercase word.
    fn spelling(&self, lower: &str) -> String {
        if let Some(entry) = self.dict.lookup(lower) {
            entry.word.to_string()
        } else if let Some(word) = self.user_words.get(lower) {
            word.spelling.clone()
        } else {
            lower.to_string()
        }
    }

    /// Score bonuses for words known to follow `prev`.
    fn follow_boosts(&self, prev: Option<&str>) -> HashMap<&str, f32> {
        let mut boosts = HashMap::new();
        let Some(prev) = prev else { return boosts };
        for (entry, weight) in self.dict.followers(prev) {
            boosts.insert(entry.lower, 1.5 + 2.0 * weight);
        }
        if let Some(seen) = self.user_bigrams.get(prev) {
            for (word, &count) in seen {
                *boosts.entry(word.as_str()).or_insert(0.0) += 3.0 + (count as f32).ln();
            }
        }
        boosts
    }

    pub fn suggest(&self, before: &str, ai: Option<&AiHints>, limit: usize) -> Output {
        let ctx = context::parse(before);
        let (mode, suggestions) = if ctx.current.is_empty() {
            (Mode::Next, self.next(&ctx, ai, limit))
        } else {
            (Mode::Complete, self.complete(&ctx, ai, limit))
        };
        Output {
            mode,
            current: ctx.current.to_string(),
            context: ctx.preceding.to_string(),
            sentence: ctx.sentence.to_string(),
            sentence_start: ctx.sentence_start,
            suggestions,
        }
    }

    /// Decodes a finger path traced across the letter keys into the words it
    /// most likely spells, best first. `path` is in the units of
    /// `distance::key_center`.
    pub fn swipe(&self, before: &str, path: &[(f32, f32)], limit: usize) -> Vec<String> {
        self.swipe_scored(before, path, limit).into_iter().map(|(word, _)| word).collect()
    }

    /// As `swipe`, with each word's score in nats; higher fits better.
    pub fn swipe_scored(&self, before: &str, path: &[(f32, f32)], limit: usize) -> Vec<(String, f32)> {
        let ctx = context::parse(before);
        // A swipe starts a new word, so whatever is at the cursor precedes it.
        let prev = if ctx.current.is_empty() { ctx.prev_word } else { Some(ctx.current) }.map(normalize);
        let boosts = self.follow_boosts(prev.as_deref());

        let builtin = self.dict.entries.iter().map(|e| (e.lower, e.word, e.logp));
        let learned = self
            .user_words
            .iter()
            .filter(|(_, word)| word.count >= LEARNED_AFTER)
            .map(|(lower, word)| (lower.as_str(), word.spelling.as_str(), -11.0 + (word.count as f32).ln()));
        let lexicon = builtin
            .chain(learned)
            .filter(|&(lower, _, _)| !blocked(lower))
            .map(|(lower, word, logp)| (lower, word, logp + boosts.get(lower).copied().unwrap_or(0.0)));
        crate::swipe::decode(path, lexicon, limit)
    }

    /// Real words a slip of the thumb away from `word`, most common first.
    pub fn neighbours(&self, word: &str, limit: usize) -> Vec<String> {
        let lower = normalize(word);
        if !lower.is_ascii() || !(2..=30).contains(&lower.len()) {
            return Vec::new();
        }
        let bytes = lower.as_bytes();
        let max = max_cost(bytes.len());
        let mut near: Vec<(f32, &str)> = self
            .dict
            .entries
            .iter()
            .filter(|e| e.lower != lower && e.lower.len().abs_diff(bytes.len()) <= 2 && !blocked(e.lower))
            .filter(|e| plausible_start(bytes, e.lower.as_bytes()))
            .filter_map(|e| Some((e.logp - TYPO_WEIGHT * typo_cost(bytes, e.lower.as_bytes(), max)?, e.word)))
            .collect();
        near.sort_by(|a, b| b.0.total_cmp(&a.0).then_with(|| a.1.cmp(b.1)));
        near.into_iter().take(limit).map(|(_, spelling)| apply_case(word, spelling)).collect()
    }

    /// Tidies words proposed as replacements for `selected`: one plain word
    /// each, no repeats, not `selected` itself, capitalised like it.
    pub fn replacements(&self, selected: &str, proposed: &[&str], limit: usize) -> Vec<String> {
        let mut seen = vec![normalize(selected)];
        let mut out = Vec::new();
        for word in proposed.iter().filter_map(|raw| clean(raw)) {
            let lower = normalize(&word);
            if out.len() >= limit || seen.contains(&lower) {
                continue;
            }
            let spelling = self.dict.lookup(&lower).map_or(word, |e| e.word.to_string());
            out.push(apply_case(selected, &spelling));
            seen.push(lower);
        }
        out
    }

    fn complete(&self, ctx: &Context, ai: Option<&AiHints>, limit: usize) -> Vec<Suggestion> {
        let typed = ctx.current;
        let lower = normalize(typed);
        if lower.chars().any(char::is_numeric) {
            return Vec::new();
        }
        let known = self.is_known(&lower);
        let prev = ctx.prev_word.map(normalize);
        let boosts = self.follow_boosts(prev.as_deref());
        let boost = |word: &str| boosts.get(word).copied().unwrap_or(0.0);
        let mut pool = Pool::default();

        // Spellings that are wrong however the sentence continues.
        let certain = fixup(&lower).or_else(|| {
            // Proper nouns typed in lowercase. Shorter ones are mostly
            // abbreviations that collide with the start of ordinary words.
            let canonical = self.dict.lookup(&lower)?.word;
            let wanted = lower == "i" || lower.len() >= 3;
            (wanted && canonical != lower && typed == lower).then_some(canonical)
        });
        if let Some(word) = certain {
            pool.add(&normalize(word), Candidate {
                spelling: word.to_string(),
                score: SCORE_CERTAIN,
                kind: Kind::Correction,
                ai: false,
                auto: Some(SCORE_CERTAIN),
            });
        }

        let mut best_completion = f32::NEG_INFINITY;
        for entry in self.dict.with_prefix(&lower) {
            if entry.lower.len() == lower.len() || blocked(entry.lower) {
                continue;
            }
            let extra = (entry.lower.len() - lower.len()).min(6) as f32;
            let score = entry.logp - 0.3 * extra + boost(entry.lower);
            best_completion = best_completion.max(score);
            pool.add(entry.lower, Candidate {
                spelling: entry.word.to_string(),
                score,
                kind: Kind::Completion,
                ai: false,
                auto: None,
            });
        }
        for (word, user) in &self.user_words {
            if user.count >= LEARNED_AFTER && word.len() > lower.len() && word.starts_with(&*lower) {
                pool.add(word, Candidate {
                    spelling: user.spelling.clone(),
                    score: -11.0 + (user.count as f32).ln() + boost(word),
                    kind: Kind::Completion,
                    ai: false,
                    auto: None,
                });
            }
        }

        if !known && lower.is_ascii() && (2..=30).contains(&lower.len()) {
            let bytes = lower.as_bytes();
            let max = max_cost(bytes.len());
            for entry in &self.dict.entries {
                let word = entry.lower.as_bytes();
                if word.len().abs_diff(bytes.len()) > 2 || !plausible_start(bytes, word) || blocked(entry.lower) {
                    continue;
                }
                let Some(cost) = typo_cost(bytes, word, max) else { continue };
                let score = entry.logp - TYPO_WEIGHT * cost + boost(entry.lower);
                pool.add(entry.lower, Candidate {
                    spelling: entry.word.to_string(),
                    score,
                    kind: Kind::Correction,
                    ai: false,
                    // Don't respell into an obscure word when what was typed
                    // is the start of a far more common one.
                    auto: (entry.logp > AUTOCORRECT_MIN_LOGP
                        && (entry.lower.starts_with(&*lower) || score > best_completion - AUTOCORRECT_MARGIN))
                        .then_some(score),
                });
            }
        }

        for (rank, raw) in ai.map_or(&[][..], |ai| &ai.words).iter().enumerate() {
            let Some(word) = clean(raw) else { continue };
            let word_lower = normalize(&word);
            if word_lower == lower || !related(&lower, &word_lower) {
                continue;
            }
            let completes = word_lower.starts_with(&*lower);
            // The model's first choice may be auto-applied, but only when it
            // turns a non-word into a real one.
            let trusted = rank == 0 && !known && self.is_known(&word_lower);
            pool.add(&word_lower, Candidate {
                spelling: self.dict.lookup(&word_lower).map_or(word, |e| e.word.to_string()),
                score: SCORE_AI - rank as f32,
                kind: if completes { Kind::Completion } else { Kind::Correction },
                ai: true,
                auto: trusted.then_some(SCORE_AI),
            });
        }

        let mut ranked = pool.ranked();
        let auto = ranked
            .iter()
            .enumerate()
            .filter_map(|(i, cand)| cand.auto.map(|score| (i, score)))
            .max_by(|a, b| a.1.total_cmp(&b.1))
            .map(|(i, _)| ranked.remove(i));

        let suggestion = |cand: Candidate, auto: bool| {
            let text = apply_case(typed, &cand.spelling);
            Suggestion { insert: text.clone(), text, replace: typed.to_string(), kind: cand.kind, ai: cand.ai, auto }
        };
        let mut out = Vec::with_capacity(limit);
        if !known || auto.is_some() {
            out.push(Suggestion {
                text: typed.to_string(),
                replace: typed.to_string(),
                insert: typed.to_string(),
                kind: Kind::Verbatim,
                ai: false,
                auto: false,
            });
        }
        out.extend(auto.map(|cand| suggestion(cand, true)));
        out.extend(ranked.into_iter().map(|cand| suggestion(cand, false)));
        out.truncate(limit);
        out
    }

    /// Validates the model's replacement for the already-typed word `last` and
    /// returns the text to substitute.
    fn checked_fix(&self, last: &str, fix: &str) -> Option<String> {
        let (last_lower, fix_lower) = (normalize(last), normalize(fix));
        if last_lower == fix_lower {
            // A pure capitalisation change must match the lexicon's spelling.
            let canonical = self.dict.lookup(&fix_lower)?.word;
            return (canonical == fix && canonical != last && last == last_lower).then(|| fix.to_string());
        }
        if !self.is_known(&fix_lower) {
            return None;
        }
        let near = last_lower.is_ascii()
            && fix_lower.is_ascii()
            && typo_cost(last_lower.as_bytes(), fix_lower.as_bytes(), max_cost(last_lower.len())).is_some();
        (near || confusable(&last_lower, &fix_lower)).then(|| apply_case(last, &self.spelling(&fix_lower)))
    }

    /// Compares the model's proofread copy of the sentence with what was
    /// typed and, if every change it made is a believable correction, returns
    /// a suggestion that rewrites the sentence from the first changed word.
    fn sentence_fix(&self, ctx: &Context, proofread: &str) -> Option<Suggestion> {
        let sentence = ctx.sentence;
        let proofread = proofread.trim_matches(|c: char| c.is_whitespace() || matches!(c, '\u{ab}' | '\u{bb}' | '"'));
        let mut theirs = proofread.split_whitespace();
        let mut rewritten = String::new();
        let mut copied = 0;
        let mut first: Option<(usize, String)> = None;

        for ours in sentence.split_whitespace() {
            // Models like to finish the sentence; extra words at the end are
            // ignored, but a shorter answer means the words no longer line up.
            let theirs = theirs.next()?;
            let is_edge = |c: char| !c.is_alphanumeric();
            let (core, fixed) = (ours.trim_matches(is_edge), theirs.trim_matches(is_edge));
            if core.is_empty() || core == fixed {
                continue;
            }
            let Some(fixed) = self.checked_fix(core, fixed) else {
                if normalize(core) == normalize(fixed) {
                    continue;
                }
                return None;
            };
            let start = core.as_ptr() as usize - sentence.as_ptr() as usize;
            match first {
                None => first = Some((start, fixed.clone())),
                Some(_) => rewritten.push_str(&sentence[copied..start]),
            }
            rewritten.push_str(&fixed);
            copied = start + core.len();
        }

        let (start, text) = first?;
        rewritten.push_str(&sentence[copied..]);
        Some(Suggestion {
            text,
            replace: format!("{}{}", &sentence[start..], ctx.trailing),
            insert: format!("{rewritten}{}", ctx.trailing),
            kind: Kind::Fix,
            ai: true,
            auto: false,
        })
    }

    fn next(&self, ctx: &Context, ai: Option<&AiHints>, limit: usize) -> Vec<Suggestion> {
        let prev = ctx.prev_word.map(normalize);
        let mut out: Vec<Suggestion> = Vec::with_capacity(limit);
        let mut seen: Vec<String> = prev.iter().cloned().collect();

        let fix = ai.and_then(|ai| ai.fix.as_deref()).and_then(|proofread| self.sentence_fix(ctx, proofread));
        out.extend(fix);

        let mut push = |lower: String, spelling: String, ai: bool| {
            if seen.contains(&lower) || out.len() >= limit {
                return;
            }
            let text = if ctx.sentence_start { capitalize(&spelling) } else { spelling };
            out.push(Suggestion { insert: text.clone(), text, replace: String::new(), kind: Kind::Next, ai, auto: false });
            seen.push(lower);
        };

        for word in ai.map_or(&[][..], |ai| &ai.words).iter().filter_map(|raw| clean(raw)) {
            let lower = normalize(&word);
            let spelling = self.dict.lookup(&lower).map_or(word, |e| e.word.to_string());
            push(lower, spelling, true);
        }

        if let Some(prev) = prev.as_deref() {
            let mut learned: Vec<_> = self.user_bigrams.get(prev).into_iter().flatten().collect();
            learned.sort_by(|a, b| b.1.cmp(a.1).then_with(|| a.0.cmp(b.0)));
            for (word, _) in learned {
                push(word.clone(), self.spelling(word), false);
            }
            for (entry, _) in self.dict.followers(prev) {
                if !blocked(entry.lower) {
                    push(entry.lower.to_string(), entry.word.to_string(), false);
                }
            }
        }
        if ctx.sentence_start {
            for word in SENTENCE_STARTERS {
                push(normalize(word), word.to_string(), false);
            }
        }
        out
    }

    /// Records the word that was just completed at the end of `before`.
    pub fn learn(&mut self, before: &str) {
        let text = before.trim_end_matches(|c: char| !c.is_alphanumeric());
        let ctx = context::parse(text);
        let lower = normalize(ctx.current);
        if !learnable(&lower) {
            return;
        }
        if let Some(prev) = ctx.prev_word.map(normalize).filter(|prev| learnable(prev)) {
            *self.user_bigrams.entry(prev).or_default().entry(lower.clone()).or_insert(0) += 1;
        }
        if !self.builtin_known(&lower) {
            let word = self.user_words.entry(lower).or_insert(UserWord { spelling: String::new(), count: 0 });
            word.count += 1;
            // A capital at the start of a sentence says nothing about the word.
            if word.spelling.is_empty() || !ctx.sentence_start {
                word.spelling = ctx.current.replace('\u{2019}', "'");
            }
        }
        self.prune();
    }

    /// Marks `word` as correctly spelled, e.g. after the user rejected an
    /// auto-correction of it.
    pub fn learn_word(&mut self, word: &str) {
        let lower = normalize(word);
        if !learnable(&lower) || self.builtin_known(&lower) {
            return;
        }
        let entry = self.user_words.entry(lower).or_insert(UserWord { spelling: String::new(), count: 0 });
        entry.count = entry.count.max(LEARNED_AFTER);
        entry.spelling = word.replace('\u{2019}', "'");
    }

    fn prune(&mut self) {
        if self.user_words.len() > MAX_USER_ENTRIES {
            self.user_words.retain(|_, word| word.count > 1);
        }
        if self.user_bigrams.len() > MAX_USER_ENTRIES {
            self.user_bigrams.retain(|_, next| {
                next.retain(|_, count| *count > 1);
                !next.is_empty()
            });
        }
    }

    /// Serialises everything learned from the user, one record per line.
    pub fn export(&self) -> String {
        let mut lines: Vec<String> = Vec::new();
        for word in self.user_words.values() {
            lines.push(format!("W\t{}\t{}", word.spelling, word.count));
        }
        for (prev, next) in &self.user_bigrams {
            for (word, count) in next {
                lines.push(format!("B\t{prev}\t{word}\t{count}"));
            }
        }
        lines.sort();
        lines.join("\n")
    }

    /// Merges records produced by `export`.
    pub fn import(&mut self, data: &str) {
        for line in data.lines() {
            let fields: Vec<&str> = line.split('\t').collect();
            match fields[..] {
                ["W", spelling, count] => {
                    if let (true, Ok(count)) = (learnable(&normalize(spelling)), count.parse()) {
                        self.user_words.insert(normalize(spelling), UserWord { spelling: spelling.to_string(), count });
                    }
                }
                ["B", prev, word, count] => {
                    if let (true, true, Ok(count)) = (learnable(prev), learnable(word), count.parse()) {
                        self.user_bigrams.entry(prev.to_string()).or_default().insert(word.to_string(), count);
                    }
                }
                _ => {}
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn texts(out: &Output) -> Vec<&str> {
        out.suggestions.iter().map(|s| s.text.as_str()).collect()
    }

    fn auto(out: &Output) -> Option<&str> {
        out.suggestions.iter().find(|s| s.auto).map(|s| s.text.as_str())
    }

    fn hints(words: &[&str], fix: Option<&str>) -> AiHints {
        AiHints { words: words.iter().map(|w| w.to_string()).collect(), fix: fix.map(str::to_string) }
    }

    #[test]
    fn corrects_typos() {
        let e = Engine::new();
        for (typed, want) in [
            ("I went to teh", "the"),
            ("my adress", "address"),
            ("Teh", "The"),
            ("see you tomorow", "tomorrow"),
            ("that is definately", "definitely"),
            ("I recieved", "received"),
            ("becuase", "because"),
            ("thnaks", "thanks"),
            ("I wnat", "want"),
            ("wor", "work"),
            ("its a beutiful", "beautiful"),
        ] {
            let out = e.suggest(typed, None, 3);
            assert_eq!(out.mode, Mode::Complete);
            assert_eq!(auto(&out), Some(want), "{typed}: {:?}", texts(&out));
            assert_eq!(out.suggestions[0].kind, Kind::Verbatim);
        }
    }

    #[test]
    fn leaves_real_words_alone() {
        let e = Engine::new();
        for typed in ["hello", "the", "I think", "London", "don't", "it's", "Sarah's"] {
            let out = e.suggest(typed, None, 3);
            assert_eq!(auto(&out), None, "{typed}: {:?}", texts(&out));
            assert!(out.suggestions.iter().all(|s| s.kind != Kind::Verbatim), "{typed}");
        }
    }

    #[test]
    fn contractions_and_capitals() {
        let e = Engine::new();
        assert_eq!(auto(&e.suggest("im", None, 3)), Some("I'm"));
        assert_eq!(auto(&e.suggest("I dont", None, 3)), Some("don't"));
        assert_eq!(auto(&e.suggest("Youre", None, 3)), Some("You're"));
        assert_eq!(auto(&e.suggest("and i", None, 3)), Some("I"));
        assert_eq!(auto(&e.suggest("in london", None, 3)), Some("London"));
    }

    #[test]
    fn completes_words() {
        let e = Engine::new();
        let out = e.suggest("see you tomor", None, 3);
        assert!(texts(&out).contains(&"tomorrow"), "{:?}", texts(&out));
        let out = e.suggest("Th", None, 3);
        assert!(texts(&out).contains(&"The"), "{:?}", texts(&out));
        assert_eq!(auto(&e.suggest("see you tomor", None, 3)), None);
        let out = e.suggest("abc123", None, 3);
        assert!(out.suggestions.is_empty());
    }

    #[test]
    fn previous_word_shapes_completions() {
        let e = Engine::new();
        let after_thank = e.suggest("thank y", None, 3);
        assert_eq!(texts(&after_thank)[..2], ["y", "you"]);
    }

    #[test]
    fn next_words() {
        let e = Engine::new();
        let out = e.suggest("I ", None, 3);
        assert_eq!(out.mode, Mode::Next);
        assert_eq!(texts(&out), ["have", "am", "was"]);
        assert!(out.suggestions.iter().all(|s| s.replace.is_empty() && s.kind == Kind::Next));
        assert_eq!(texts(&e.suggest("", None, 3)), ["I", "The", "Thanks"]);
    }

    #[test]
    fn ai_words_lead_when_they_fit_the_keys() {
        let e = Engine::new();
        let ai = hints(&["keyboard", "banana", "Keys."], None);
        let out = e.suggest("I love my new keyb", Some(&ai), 3);
        assert_eq!(out.context, "I love my new");
        assert_eq!(out.suggestions[0].kind, Kind::Verbatim);
        assert_eq!(out.suggestions[1].text, "keyboard");
        assert!(out.suggestions[1].ai && out.suggestions[1].auto);
        assert!(!texts(&out).contains(&"banana"));
    }

    #[test]
    fn ai_correction_is_auto_applied_only_for_non_words() {
        let e = Engine::new();
        let ai = hints(&["weather"], None);
        let out = e.suggest("lovely wheather", Some(&ai), 3);
        assert_eq!(auto(&out), Some("weather"));
        assert!(out.suggestions[1].ai);

        let ai = hints(&["there"], None);
        let out = e.suggest("over their", Some(&ai), 3);
        assert_eq!(auto(&out), None);
        assert_eq!(out.suggestions[0].text, "there");
    }

    #[test]
    fn ai_next_words_and_fix() {
        let e = Engine::new();
        let ai = hints(&["and", "to the", "  "], Some("I went over there."));
        let out = e.suggest("Hi. I went over their ", Some(&ai), 3);
        assert_eq!(out.sentence, "I went over their");
        let fix = &out.suggestions[0];
        assert_eq!((fix.kind, fix.text.as_str()), (Kind::Fix, "there"));
        assert_eq!((fix.replace.as_str(), fix.insert.as_str()), ("their ", "there "));
        assert_eq!(texts(&out)[1..], ["and", "to"]);
        assert!(out.suggestions.iter().all(|s| s.ai));
    }

    #[test]
    fn ai_fix_can_reach_back_into_the_sentence() {
        let e = Engine::new();
        let ai = hints(&["said"], Some("\u{ab}Did you hear what she said?\u{bb}"));
        let fix = &e.suggest("Did you here what she ", Some(&ai), 3).suggestions[0];
        assert_eq!((fix.kind, fix.text.as_str()), (Kind::Fix, "hear"));
        assert_eq!((fix.replace.as_str(), fix.insert.as_str()), ("here what she ", "hear what she "));

        let ai = hints(&[], Some("I think you're going to love it, there."));
        let fix = &e.suggest("i think your going to love it, their ", Some(&ai), 3).suggestions[0];
        assert_eq!(fix.text, "I");
        assert_eq!(fix.replace, "i think your going to love it, their ");
        assert_eq!(fix.insert, "I think you're going to love it, there ");
    }

    #[test]
    fn unrelated_ai_fix_is_dropped() {
        let e = Engine::new();
        for fix in ["I went banana", "I went home", "I went hoem", "I went", "We drove home", "I went home tonight", ""] {
            let ai = hints(&["now"], Some(fix));
            let out = e.suggest("I went home ", Some(&ai), 3);
            assert!(out.suggestions.iter().all(|s| s.kind != Kind::Fix), "{fix}");
        }
        let ai = hints(&[], Some("Flying to Paris"));
        assert_eq!(e.suggest("flying to paris ", Some(&ai), 3).suggestions[0].text, "Paris");
    }

    #[test]
    fn ai_next_words_are_capitalised_at_sentence_start() {
        let e = Engine::new();
        let ai = hints(&["we", "The", "it\\'s"], None);
        assert_eq!(texts(&e.suggest("All done. ", Some(&ai), 3)), ["We", "The", "It's"]);
        assert_eq!(texts(&e.suggest("and then ", Some(&ai), 3)), ["we", "the", "it's"]);
    }

    #[test]
    fn copes_with_emoji() {
        let mut engine = Engine::new();
        let path = [(0.5, 0.5), (3.0, 0.6), (5.5, 1.5)];
        for text in [
            "😀", "hi 😀", "hi 😀 ", "😀hello", "hello😀", "hel😀lo", "👨‍👩‍👧", "🇦🇺", "1️⃣", "☺️", "☺️ thnks", "teh 🇦🇺",
            "I like 🍕. ", "😀 Teh",
        ] {
            engine.suggest(text, None, 8);
            engine.suggest(text, Some(&hints(&["😀", "hello"], Some(text))), 8);
            engine.swipe(text, &path, 8);
            engine.neighbours(text, 6);
            engine.replacements(text, &[text, "hello"], 8);
            engine.learn(text);
            engine.learn_word(text);
        }
        engine.import(&engine.export());
    }

    #[test]
    fn learns_new_words() {
        let mut e = Engine::new();
        assert_eq!(e.suggest("try kaiboard", None, 3).suggestions[0].kind, Kind::Verbatim);
        e.learn("try Kaiboard ");
        e.learn("love Kaiboard. ");
        assert!(e.suggest("try kaiboard", None, 3).suggestions.iter().all(|s| s.kind != Kind::Verbatim));
        assert!(texts(&e.suggest("the Kaib", None, 3)).contains(&"Kaiboard"));
        assert_eq!(texts(&e.suggest("try ", None, 3))[0], "Kaiboard");

        let mut restored = Engine::new();
        restored.import(&e.export());
        assert_eq!(restored.export(), e.export());
        assert_eq!(texts(&restored.suggest("try ", None, 3))[0], "Kaiboard");
    }

    #[test]
    fn replacements_for_a_selected_word() {
        let e = Engine::new();
        assert!(e.neighbours("sent", 6).contains(&"send".to_string()));
        assert!(e.neighbours("Coffin", 6).iter().all(|w| w.starts_with(char::is_uppercase)));
        assert!(e.neighbours("xqzvkj", 6).is_empty());
        let got = e.replacements("Series", &["words", "series", "the word", "Words.", "it\\'s", "42"], 3);
        assert_eq!(got, ["Words", "The", "It's"]);
    }

    #[test]
    fn rejected_autocorrection_sticks() {
        let mut e = Engine::new();
        assert!(auto(&e.suggest("helo", None, 3)).is_some());
        e.learn_word("helo");
        assert_eq!(auto(&e.suggest("helo", None, 3)), None);
    }
}
