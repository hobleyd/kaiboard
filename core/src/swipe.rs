//! Decodes a path swiped across the letter keys into words.
//!
//! Every plausible word is turned into the path a finger would trace through
//! its letters; the word whose ideal path lies closest to the real one wins,
//! with word frequency breaking ties between look-alike paths.

use crate::distance::key_center;

type Point = (f32, f32);

/// Points each path is resampled to before comparison.
const SAMPLES: usize = 32;
/// How far, in key widths, a swipe may start or end from a word's first or last letter.
const ENDPOINT_SLACK: f32 = 1.3;
/// Average distance between the paths beyond which a word is not considered.
const MAX_MEAN_DISTANCE: f32 = 0.9;
/// Nats of word frequency that one key width of average deviation costs.
const DISTANCE_WEIGHT: f32 = 22.0;
/// Cost per key width, averaged over the word's letters, that the swipe passes
/// by each letter's key. Tells apart words whose paths differ at one corner.
const KEY_WEIGHT: f32 = 8.0;
/// Extra cost per key width that the ends of the swipe miss the word's first
/// and last letters by; people aim those more carefully than the middle.
const ENDPOINT_WEIGHT: f32 = 4.0;
/// How far, in nats, a word may score below the best reading of a swipe and
/// still be a serious contender for what was meant. "put", "pot" and "pit"
/// fall within this of each other; "you" and "toy" are several times further apart.
pub const CONTENDER_MARGIN: f32 = 3.5;

fn distance(a: Point, b: Point) -> f32 {
    (a.0 - b.0).hypot(a.1 - b.1)
}

fn length(path: &[Point]) -> f32 {
    path.windows(2).map(|w| distance(w[0], w[1])).sum()
}

/// `SAMPLES` points spaced evenly along `path`, which must not be empty.
fn resample(path: &[Point]) -> [Point; SAMPLES] {
    let mut out = [path[0]; SAMPLES];
    let step = length(path) / (SAMPLES - 1) as f32;
    if step <= f32::EPSILON {
        return out;
    }
    let (mut filled, mut carried, mut from) = (1, 0.0f32, path[0]);
    for &to in &path[1..] {
        let mut segment = distance(from, to);
        while filled < SAMPLES && carried + segment >= step {
            let t = (step - carried) / segment;
            from = (from.0 + (to.0 - from.0) * t, from.1 + (to.1 - from.1) * t);
            out[filled] = from;
            filled += 1;
            segment = distance(from, to);
            carried = 0.0;
        }
        carried += segment;
        from = to;
    }
    // Rounding can leave the last sample or two unfilled.
    for point in &mut out[filled..] {
        *point = path[path.len() - 1];
    }
    out
}

/// The key centres a finger visits to spell `word`, or `None` if it has
/// characters that are not on the letter keys.
fn ideal(word: &str, keys: &mut Vec<Point>) -> Option<()> {
    keys.clear();
    for letter in word.bytes() {
        if letter == b'\'' {
            continue;
        }
        let center = key_center(letter)?;
        if keys.last() != Some(&center) {
            keys.push(center);
        }
    }
    (!keys.is_empty()).then_some(())
}

/// Ranks `lexicon` entries `(lowercase, spelling, log probability)` by how
/// well they explain `path` and returns the best `limit` spellings with their
/// scores, in nats.
pub fn decode<'a>(
    path: &[Point],
    lexicon: impl Iterator<Item = (&'a str, &'a str, f32)>,
    limit: usize,
) -> Vec<(String, f32)> {
    let (Some(&start), Some(&end)) = (path.first(), path.last()) else { return Vec::new() };
    let traced = resample(path);
    let traced_length = length(path);

    let mut keys = Vec::with_capacity(32);
    let mut scored: Vec<(f32, &str)> = Vec::new();
    for (lower, spelling, logp) in lexicon {
        if lower.len() < 2 || ideal(lower, &mut keys).is_none() {
            continue;
        }
        let ends = (distance(keys[0], start), distance(keys[keys.len() - 1], end));
        if ends.0 > ENDPOINT_SLACK || ends.1 > ENDPOINT_SLACK {
            continue;
        }
        // Fingers cut corners, so a real path is usually a little shorter than the ideal one.
        let ideal_length = length(&keys);
        if ideal_length > traced_length * 1.8 + 1.0 || ideal_length < traced_length * 0.5 - 1.0 {
            continue;
        }
        let wanted = resample(&keys);
        let mean = traced.iter().zip(&wanted).map(|(&a, &b)| distance(a, b)).sum::<f32>() / SAMPLES as f32;
        if mean > MAX_MEAN_DISTANCE {
            continue;
        }
        let missed = keys
            .iter()
            .map(|&key| path.iter().map(|&point| distance(key, point)).fold(f32::INFINITY, f32::min))
            .sum::<f32>()
            / keys.len() as f32;
        let cost = DISTANCE_WEIGHT * mean + KEY_WEIGHT * missed + ENDPOINT_WEIGHT * (ends.0 + ends.1);
        scored.push((logp - cost, spelling));
    }
    scored.sort_by(|a, b| b.0.total_cmp(&a.0).then_with(|| a.1.cmp(b.1)));

    let mut out: Vec<(String, f32)> = Vec::with_capacity(limit);
    for (score, spelling) in scored {
        if out.len() >= limit {
            break;
        }
        if !out.iter().any(|(seen, _)| seen == spelling) {
            out.push((spelling.to_string(), score));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Engine;

    /// A finger path through `word`: straight lines between keys, cutting each
    /// corner and drifting off-centre by up to `wobble` key widths.
    fn trace(word: &str, wobble: f32) -> Vec<Point> {
        let mut keys = Vec::new();
        ideal(word, &mut keys).unwrap();
        let mut path = Vec::new();
        for (i, pair) in keys.windows(2).enumerate() {
            for step in 0..10 {
                let t = step as f32 / 10.0;
                let phase = (i * 10 + step) as f32 * 0.9;
                path.push((
                    pair[0].0 + (pair[1].0 - pair[0].0) * t + wobble * phase.sin(),
                    pair[0].1 + (pair[1].1 - pair[0].1) * t + wobble * (phase * 1.7).cos(),
                ));
            }
        }
        path.push(keys[keys.len() - 1]);
        // Smoothing rounds the corners off, as a hurried finger does.
        let smoothed: Vec<Point> = (0..path.len())
            .map(|i| {
                let window = &path[i.saturating_sub(2)..(i + 3).min(path.len())];
                let n = window.len() as f32;
                (window.iter().map(|p| p.0).sum::<f32>() / n, window.iter().map(|p| p.1).sum::<f32>() / n)
            })
            .collect();
        smoothed
    }

    #[test]
    fn resampling_is_even() {
        let points = resample(&[(0.0, 0.0), (1.0, 0.0), (1.0, 3.0)]);
        assert_eq!(points[0], (0.0, 0.0));
        assert!(distance(points[SAMPLES - 1], (1.0, 3.0)) < 1e-3);
        let gaps: Vec<f32> = points.windows(2).map(|w| distance(w[0], w[1])).collect();
        // Samples that straddle the corner are closer together than the step.
        assert!(gaps.iter().all(|gap| *gap > 0.08 && *gap < 4.0 / 31.0 + 0.001), "{gaps:?}");
        assert_eq!(resample(&[(2.0, 1.0)]), [(2.0, 1.0); SAMPLES]);
    }

    #[test]
    fn decodes_swiped_words() {
        let engine = Engine::new();
        let words = [
            "hello", "world", "keyboard", "tomorrow", "the", "and", "people", "because", "thanks", "great",
            "phone", "what", "morning", "weekend", "dinner", "really", "about", "London", "meeting", "friend",
        ];
        for wobble in [0.0, 0.2] {
            let missed: Vec<_> = words
                .iter()
                .filter_map(|word| {
                    let got = engine.swipe("", &trace(&word.to_lowercase(), wobble), 3);
                    (got.first().map(String::as_str) != Some(*word)).then_some((*word, got))
                })
                .collect();
            assert!(missed.is_empty(), "wobble {wobble}: {missed:?}");
        }
    }

    #[test]
    fn offers_alternatives_and_uses_the_previous_word() {
        let engine = Engine::new();
        // "put", "pit", "pot" and "pout" all trace the same line along the top row.
        let got = engine.swipe("", &trace("pit", 0.0), 3);
        assert!(got.len() == 3 && got.contains(&"put".to_string()), "{got:?}");
        // "code" and "coffee" differ by one neighbouring key; the runner-up is offered too.
        assert_eq!(engine.swipe("", &trace("coffee", 0.0), 2), ["code", "coffee"]);
        assert_eq!(engine.swipe("thank ", &trace("you", 0.2), 1), ["you"]);
        assert_eq!(engine.swipe("thank", &trace("you", 0.2), 1), ["you"]);
    }

    #[test]
    fn only_look_alikes_are_contenders() {
        let engine = Engine::new();
        let contenders = |word: &str| -> Vec<String> {
            let scored = engine.swipe_scored("", &trace(word, 0.2), 8);
            let best = scored[0].1;
            scored.into_iter().filter(|(_, score)| best - score <= CONTENDER_MARGIN).map(|(word, _)| word).collect()
        };
        assert_eq!(contenders("you"), ["you"]);
        let know = contenders("know");
        assert!(know[0] == "know" && !know.contains(&"knots".to_string()), "{know:?}");
        let put = contenders("put");
        assert!(put.contains(&"pot".to_string()) && put.contains(&"pit".to_string()), "{put:?}");
    }

    #[test]
    fn adult_words_can_be_swiped() {
        let engine = Engine::new();
        for word in ["fuck", "shit", "cock", "pussy"] {
            let got = engine.swipe("", &trace(word, 0.2), 4);
            assert!(got.contains(&word.to_string()), "{word}: {got:?}");
        }
        // Next to an innocent word they are offered but are not contenders.
        let scored = engine.swipe_scored("", &trace("duck", 0.2), 4);
        assert_eq!(scored[0].0, "duck");
        let rude = scored.iter().find(|(word, _)| word == "fuck").expect("still offered");
        assert!(scored[0].1 - rude.1 > CONTENDER_MARGIN, "{scored:?}");
    }

    #[test]
    fn nonsense_paths_decode_to_nothing_much() {
        let engine = Engine::new();
        assert!(engine.swipe("", &[], 3).is_empty());
        assert!(engine.swipe("", &[(-40.0, 9.0), (-41.0, 9.5)], 3).is_empty());
    }
}
