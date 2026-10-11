//! Text engine for the Kaiboard keyboard.
//!
//! The Swift keyboard extension owns the UI and the Apple Intelligence
//! (Foundation Models) calls; everything that has to run on every keystroke
//! lives here: working out what the user is in the middle of typing, finding
//! spelling candidates, and merging the model's context-aware guesses with the
//! instant local ones into the final suggestion bar.

mod context;
mod dict;
mod distance;
mod engine;
mod ffi;
mod json;
mod swipe;

pub use context::{parse, Context};
pub use engine::{AiHints, Engine, Kind, Mode, Output, Suggestion};
