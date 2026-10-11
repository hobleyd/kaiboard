//! C interface used by the Swift keyboard extension. See `include/kaiboard_core.h`.

use crate::engine::{AiHints, Engine, Mode, Output};
use crate::json;
use std::ffi::{c_char, CStr, CString};

/// # Safety
/// `ptr` must be null or a valid NUL-terminated string.
unsafe fn text<'a>(ptr: *const c_char) -> Option<std::borrow::Cow<'a, str>> {
    (!ptr.is_null()).then(|| CStr::from_ptr(ptr).to_string_lossy())
}

fn into_c(s: String) -> *mut c_char {
    CString::new(s.replace('\0', "")).map_or(std::ptr::null_mut(), CString::into_raw)
}

fn encode(out: &Output) -> String {
    let mut s = String::with_capacity(512);
    s.push_str("{\"mode\":");
    json::push_str(&mut s, match out.mode {
        Mode::Complete => "complete",
        Mode::Next => "next",
    });
    s.push_str(",\"current\":");
    json::push_str(&mut s, &out.current);
    s.push_str(",\"context\":");
    json::push_str(&mut s, &out.context);
    s.push_str(",\"sentence\":");
    json::push_str(&mut s, &out.sentence);
    s.push_str(",\"sentenceStart\":");
    s.push_str(if out.sentence_start { "true" } else { "false" });
    s.push_str(",\"suggestions\":[");
    for (i, sug) in out.suggestions.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        s.push_str("{\"text\":");
        json::push_str(&mut s, &sug.text);
        s.push_str(",\"replace\":");
        json::push_str(&mut s, &sug.replace);
        s.push_str(",\"insert\":");
        json::push_str(&mut s, &sug.insert);
        s.push_str(",\"kind\":");
        json::push_str(&mut s, sug.kind.as_str());
        s.push_str(if sug.ai { ",\"ai\":true" } else { ",\"ai\":false" });
        s.push_str(if sug.auto { ",\"auto\":true}" } else { ",\"auto\":false}" });
    }
    s.push_str("]}");
    s
}

#[no_mangle]
pub extern "C" fn kb_engine_new() -> *mut Engine {
    Box::into_raw(Box::new(Engine::new()))
}

/// # Safety
/// `engine` must come from `kb_engine_new` and not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn kb_engine_free(engine: *mut Engine) {
    if !engine.is_null() {
        drop(Box::from_raw(engine));
    }
}

/// # Safety
/// `engine` must be valid; string arguments must be null or NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn kb_suggest(
    engine: *const Engine,
    before: *const c_char,
    ai_words: *const c_char,
    ai_fix: *const c_char,
    limit: u32,
) -> *mut c_char {
    let Some(engine) = engine.as_ref() else { return std::ptr::null_mut() };
    let before = text(before).unwrap_or_default();
    let hints = text(ai_words).map(|words| AiHints {
        words: words.lines().map(str::to_string).collect(),
        fix: text(ai_fix).map(|fix| fix.into_owned()),
    });
    into_c(encode(&engine.suggest(&before, hints.as_ref(), limit as usize)))
}

/// # Safety
/// `engine` must be valid; `before` must be null or NUL-terminated UTF-8; `xy`
/// must point to `points` pairs of floats.
#[no_mangle]
pub unsafe extern "C" fn kb_swipe(
    engine: *const Engine,
    before: *const c_char,
    xy: *const f32,
    points: u32,
    limit: u32,
) -> *mut c_char {
    let Some(engine) = engine.as_ref() else { return std::ptr::null_mut() };
    if xy.is_null() {
        return std::ptr::null_mut();
    }
    let before = text(before).unwrap_or_default();
    let flat = std::slice::from_raw_parts(xy, points as usize * 2);
    let path: Vec<(f32, f32)> = flat.chunks_exact(2).map(|p| (p[0], p[1])).collect();

    into_c(encode_words(&engine.swipe(&before, &path, limit as usize)))
}

fn encode_words(words: &[String]) -> String {
    let mut s = String::from("[");
    for (i, word) in words.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        json::push_str(&mut s, word);
    }
    s.push(']');
    s
}

/// # Safety
/// `engine` must be valid; `word` must be null or NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn kb_neighbours(engine: *const Engine, word: *const c_char, limit: u32) -> *mut c_char {
    let Some(engine) = engine.as_ref() else { return std::ptr::null_mut() };
    into_c(encode_words(&engine.neighbours(&text(word).unwrap_or_default(), limit as usize)))
}

/// # Safety
/// `engine` must be valid; strings must be null or NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn kb_replacements(
    engine: *const Engine,
    selected: *const c_char,
    proposed: *const c_char,
    limit: u32,
) -> *mut c_char {
    let Some(engine) = engine.as_ref() else { return std::ptr::null_mut() };
    let proposed = text(proposed).unwrap_or_default();
    let proposed: Vec<&str> = proposed.lines().collect();
    into_c(encode_words(&engine.replacements(&text(selected).unwrap_or_default(), &proposed, limit as usize)))
}

/// # Safety
/// `engine` must be valid; `before` must be null or NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn kb_learn(engine: *mut Engine, before: *const c_char) {
    if let (Some(engine), Some(before)) = (engine.as_mut(), text(before)) {
        engine.learn(&before);
    }
}

/// # Safety
/// `engine` must be valid; `word` must be null or NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn kb_learn_word(engine: *mut Engine, word: *const c_char) {
    if let (Some(engine), Some(word)) = (engine.as_mut(), text(word)) {
        engine.learn_word(&word);
    }
}

/// # Safety
/// `engine` must be valid.
#[no_mangle]
pub unsafe extern "C" fn kb_export(engine: *const Engine) -> *mut c_char {
    engine.as_ref().map_or(std::ptr::null_mut(), |engine| into_c(engine.export()))
}

/// # Safety
/// `engine` must be valid; `data` must be null or NUL-terminated UTF-8.
#[no_mangle]
pub unsafe extern "C" fn kb_import(engine: *mut Engine, data: *const c_char) {
    if let (Some(engine), Some(data)) = (engine.as_mut(), text(data)) {
        engine.import(&data);
    }
}

/// # Safety
/// `s` must be null or a string returned by this library, freed only once.
#[no_mangle]
pub unsafe extern "C" fn kb_string_free(s: *mut c_char) {
    if !s.is_null() {
        drop(CString::from_raw(s));
    }
}
