//! Splits the text before the cursor into the pieces the keyboard cares about.

/// How much preceding text is handed to the language model.
const CONTEXT_WINDOW_CHARS: usize = 320;
/// How many words back the model is asked to proofread.
const SENTENCE_WINDOW_WORDS: usize = 20;

#[derive(Debug, PartialEq, Eq)]
pub struct Context<'a> {
    /// The partial word touching the cursor, or "" when the cursor follows
    /// whitespace or punctuation.
    pub current: &'a str,
    /// Everything before `current`, clipped to the model's context window.
    pub preceding: &'a str,
    /// The word before `current`, when only spaces separate the two. Together
    /// with `gap` it is the exact text sitting between that word's start and
    /// `current`.
    pub prev_word: Option<&'a str>,
    /// The spaces between `prev_word` and `current`.
    pub gap: &'a str,
    /// The unfinished sentence at the end of `preceding`, at most
    /// `SENTENCE_WINDOW_WORDS` words of it.
    pub sentence: &'a str,
    /// Whitespace between `preceding` and `current`.
    pub trailing: &'a str,
    /// Whether `current` begins a sentence.
    pub sentence_start: bool,
}

pub fn is_apostrophe(c: char) -> bool {
    c == '\'' || c == '\u{2019}'
}

pub fn is_word_char(c: char) -> bool {
    c.is_alphanumeric() || is_apostrophe(c)
}

fn is_inline_space(c: char) -> bool {
    c == ' ' || c == '\t' || c == '\u{a0}'
}

fn is_closer(c: char) -> bool {
    matches!(c, ')' | ']' | '"' | '\'' | '\u{201d}' | '\u{2019}')
}

/// Byte offset where the trailing run of word characters in `text` begins.
fn word_start(text: &str) -> usize {
    let mut start = text.len();
    for (i, c) in text.char_indices().rev() {
        if !is_word_char(c) {
            break;
        }
        start = i;
    }
    // A leading apostrophe is an opening quote, not part of the word.
    while let Some(c) = text[start..].chars().next() {
        if !is_apostrophe(c) {
            break;
        }
        start += c.len_utf8();
    }
    start
}

fn clip(text: &str) -> &str {
    let text = text.trim_end();
    let total = text.chars().count();
    if total <= CONTEXT_WINDOW_CHARS {
        return text.trim_start();
    }
    let skip = total - CONTEXT_WINDOW_CHARS;
    let cut = text.char_indices().nth(skip).map_or(0, |(i, _)| i);
    // Start on a word boundary so the model never sees half a word.
    match text[cut..].find(char::is_whitespace) {
        Some(ws) => text[cut + ws..].trim_start(),
        None => &text[cut..],
    }
}

/// The part of `text` after its last sentence break.
fn last_sentence(text: &str) -> &str {
    let mut start = 0;
    let mut chars = text.char_indices().peekable();
    while let Some((i, c)) = chars.next() {
        let ends_here = chars.peek().is_none_or(|&(_, next)| next.is_whitespace());
        if c == '\n' || (matches!(c, '.' | '!' | '?' | '\u{2026}') && ends_here) {
            start = i + c.len_utf8();
        }
    }
    let sentence = text[start..].trim_start();
    let words = sentence.split_whitespace().count();
    if words <= SENTENCE_WINDOW_WORDS {
        return sentence;
    }
    let first = sentence.split_whitespace().nth(words - SENTENCE_WINDOW_WORDS).unwrap_or(sentence);
    &sentence[first.as_ptr() as usize - sentence.as_ptr() as usize..]
}

pub fn parse(before: &str) -> Context<'_> {
    let start = word_start(before);
    let current = &before[start..];
    let head = &before[..start];

    let spaced = head.trim_end_matches(is_inline_space);
    let gap = &head[spaced.len()..];
    let prev_word = if gap.is_empty() {
        None
    } else {
        let prev = &spaced[word_start(spaced)..];
        (!prev.is_empty()).then_some(prev)
    };

    let text = head.trim_end();
    let sentence_start = if text.is_empty() || head[text.len()..].contains('\n') {
        true
    } else if text.len() == head.len() {
        false
    } else {
        matches!(
            text.trim_end_matches(is_closer).chars().last(),
            Some('.' | '!' | '?' | '\u{2026}')
        )
    };

    let preceding = clip(head);
    Context {
        current,
        preceding,
        prev_word,
        gap,
        sentence: last_sentence(preceding),
        trailing: &head[text.len()..],
        sentence_start,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn partial_word() {
        let c = parse("I am goi");
        assert_eq!(c.current, "goi");
        assert_eq!(c.prev_word, Some("am"));
        assert_eq!(c.preceding, "I am");
        assert!(!c.sentence_start);
    }

    #[test]
    fn after_space() {
        let c = parse("see you  ");
        assert_eq!(c.current, "");
        assert_eq!(c.prev_word, Some("you"));
        assert_eq!(c.gap, "  ");
    }

    #[test]
    fn sentence_starts() {
        assert!(parse("").sentence_start);
        assert!(parse("Done. ").sentence_start);
        assert!(parse("Really?\" th").sentence_start);
        assert!(parse("line one\n").sentence_start);
        assert!(!parse("www.exa").sentence_start);
        assert!(!parse("one, two").sentence_start);
    }

    #[test]
    fn punctuation_breaks_bigram() {
        assert_eq!(parse("well, th").prev_word, None);
        assert_eq!(parse("(th").prev_word, None);
    }

    #[test]
    fn apostrophes() {
        assert_eq!(parse("I don\u{2019}t").current, "don\u{2019}t");
        assert_eq!(parse("she said 'hel").current, "hel");
    }

    #[test]
    fn clips_on_word_boundary() {
        let long = "word ".repeat(200);
        let c = parse(&long);
        assert!(c.preceding.chars().count() <= CONTEXT_WINDOW_CHARS);
        assert!(c.preceding.starts_with("word"));
    }

    #[test]
    fn sentences() {
        assert_eq!(parse("All good. Did you here what she ").sentence, "Did you here what she");
        assert_eq!(parse("All good. Did you here what she ").trailing, " ");
        assert_eq!(parse("Done. ").sentence, "");
        assert_eq!(parse("v1.2 is out").sentence, "v1.2 is");
        let long = "word ".repeat(50);
        assert_eq!(parse(&long).sentence.split(' ').count(), SENTENCE_WINDOW_WORDS);
    }

    #[test]
    fn non_ascii() {
        let c = parse("caf\u{e9} na\u{ef}v");
        assert_eq!(c.current, "na\u{ef}v");
        assert_eq!(c.prev_word, Some("caf\u{e9}"));
    }
}
