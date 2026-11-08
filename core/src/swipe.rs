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
/// Average distance between evenly spaced points of the two paths beyond
/// which a word is not looked at more closely. Loose: a finger that turns
/// short of a key throws every later point out of step.
const MAX_MEAN_DISTANCE: f32 = 1.8;
/// How many samples either path may run ahead of the other when they are
/// aligned, to make up for corners the finger cut short.
const WARP: usize = 6;
/// Average distance between the aligned paths beyond which a word is not considered.
const MAX_ALIGNED_DISTANCE: f32 = 0.9;
/// Nats of word frequency that one key width of average deviation between the aligned paths costs.
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
/// How much worse, in nats, a contender's shape may fit the swipe than the
/// best reading's, leaving word frequency aside. "pit" traces the same line as
/// "put" and is only rarer; "facilities" scores near "fabulous" by being
/// ten times as common, though its shape fits far worse.
pub const SHAPE_MARGIN: f32 = 3.0;
/// A letter where the path doubles back on itself by more than this angle,
/// in radians, is a turnaround: "n" in "and", "n" in "into".
const TURNAROUND: f32 = 2.0;
/// How far, as a fraction, a finger is taken to reach towards a turnaround's
/// key from the point between its neighbours before it heads back. Fingers
/// turn early, so a swiped "and" turns at "v" and traces "saved".
const TURNAROUND_REACH: f32 = 0.65;
/// Nats each turnaround taken early costs, so that a word that zigzags, like
/// "facilities", isn't let off every corner it has.
const TURNAROUND_WEIGHT: f32 = 1.5;

/// Whether a swipe came up off the space bar from the word before, or ran
/// down onto it to go on to the next, so that its path starts or ends there
/// rather than on a letter.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Through {
    pub from_space: bool,
    pub to_space: bool,
}

/// One word a swipe may be read as.
#[derive(Clone, Debug, PartialEq)]
pub struct Reading {
    pub word: String,
    /// In nats; higher fits better.
    pub score: f32,
    /// How badly the path fits the word's shape, in nats, however common it is.
    pub cost: f32,
}

/// How many of the leading `readings` are serious contenders for what was
/// meant: they score nearly as well as the first and trace nearly the same shape.
pub fn contenders(readings: &[Reading]) -> usize {
    let Some(best) = readings.first() else { return 0 };
    readings
        .iter()
        .take_while(|r| best.score - r.score <= CONTENDER_MARGIN && r.cost - best.cost <= SHAPE_MARGIN)
        .count()
}

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

/// Average distance between `a` and `b` once their samples are matched up,
/// in order, so as to bring the paths as close as possible, letting each run
/// up to `WARP` samples ahead of the other (dynamic time warping).
fn aligned_distance(a: &[Point; SAMPLES], b: &[Point; SAMPLES]) -> f32 {
    // Cheapest alignment of a[..i] with b[..j], kept one row at a time.
    let mut above = [f32::INFINITY; SAMPLES + 1];
    above[0] = 0.0;
    for i in 1..=SAMPLES {
        let mut row = [f32::INFINITY; SAMPLES + 1];
        for j in i.saturating_sub(WARP).max(1)..=(i + WARP).min(SAMPLES) {
            row[j] = distance(a[i - 1], b[j - 1]) + above[j - 1].min(above[j]).min(row[j - 1]);
        }
        above = row;
    }
    above[SAMPLES] / SAMPLES as f32
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

/// `keys` with each turnaround pulled in to where a finger usually turns back,
/// and how many there were, or `None` if the path has no turnarounds.
fn turned_early(keys: &[Point]) -> Option<(Vec<Point>, usize)> {
    let mut out = keys.to_vec();
    let mut turns = 0;
    for (i, w) in keys.windows(3).enumerate() {
        let (a, b, c) = (w[0], w[1], w[2]);
        let (u, v) = ((b.0 - a.0, b.1 - a.1), (c.0 - b.0, c.1 - b.1));
        let turn = (u.0 * v.1 - u.1 * v.0).atan2(u.0 * v.0 + u.1 * v.1).abs();
        if turn > TURNAROUND {
            let mid = ((a.0 + c.0) / 2.0, (a.1 + c.1) / 2.0);
            out[i + 1] = (mid.0 + (b.0 - mid.0) * TURNAROUND_REACH, mid.1 + (b.1 - mid.1) * TURNAROUND_REACH);
            turns += 1;
        }
    }
    (turns > 0).then_some((out, turns))
}

/// Ranks `lexicon` entries `(lowercase, spelling, log probability)` by how
/// well they explain `path` and returns the best `limit` spellings.
pub fn decode<'a>(
    path: &[Point],
    through: Through,
    lexicon: impl Iterator<Item = (&'a str, &'a str, f32)>,
    limit: usize,
) -> Vec<Reading> {
    let (Some(&start), Some(&end)) = (path.first(), path.last()) else { return Vec::new() };
    let traced = resample(path);
    let traced_length = length(path);

    let mut keys = Vec::with_capacity(32);
    let mut scored: Vec<(f32, f32, &str)> = Vec::new();
    for (lower, spelling, logp) in lexicon {
        // A swipe can't tell a one-letter word from a tap, unless it ran to or from the space bar.
        let single = through.from_space || through.to_space;
        if (lower.len() < 2 && !single) || ideal(lower, &mut keys).is_none() {
            continue;
        }
        // The finger travels between the word and the space bar in a straight
        // line from its first letter or to its last, which the ideal path takes too.
        if through.from_space {
            keys.insert(0, start);
        }
        if through.to_space {
            keys.push(end);
        }
        let ends = (distance(keys[0], start), distance(keys[keys.len() - 1], end));
        if ends.0 > ENDPOINT_SLACK || ends.1 > ENDPOINT_SLACK {
            continue;
        }
        // A word's shape is judged against both the path through its keys and
        // the one a finger takes that turns back early.
        let fit = |keys: &[Point]| -> Option<f32> {
            // Fingers cut corners, so a real path is usually a little shorter than the ideal one.
            let ideal_length = length(keys);
            if ideal_length > traced_length * 1.8 + 1.0 || ideal_length < traced_length * 0.5 - 1.0 {
                return None;
            }
            let wanted = resample(keys);
            let mean = traced.iter().zip(&wanted).map(|(&a, &b)| distance(a, b)).sum::<f32>() / SAMPLES as f32;
            if mean > MAX_MEAN_DISTANCE {
                return None;
            }
            let aligned = aligned_distance(&traced, &wanted);
            if aligned > MAX_ALIGNED_DISTANCE {
                return None;
            }
            let missed = keys
                .iter()
                .map(|&key| path.iter().map(|&point| distance(key, point)).fold(f32::INFINITY, f32::min))
                .sum::<f32>()
                / keys.len() as f32;
            Some(DISTANCE_WEIGHT * aligned + KEY_WEIGHT * missed)
        };
        let early = turned_early(&keys).and_then(|(early, turns)| Some(fit(&early)? + TURNAROUND_WEIGHT * turns as f32));
        let shape = match (fit(&keys), early) {
            (Some(a), Some(b)) => a.min(b),
            (a, b) => match a.or(b) {
                Some(cost) => cost,
                None => continue,
            },
        };
        let cost = shape + ENDPOINT_WEIGHT * (ends.0 + ends.1);
        scored.push((logp - cost, cost, spelling));
    }
    scored.sort_by(|a, b| b.0.total_cmp(&a.0).then_with(|| a.2.cmp(b.2)));

    let mut out: Vec<Reading> = Vec::with_capacity(limit);
    for (score, cost, spelling) in scored {
        if out.len() >= limit {
            break;
        }
        if !out.iter().any(|seen| seen.word == spelling) {
            out.push(Reading { word: spelling.to_string(), score, cost });
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
        trace_through(&keys, wobble)
    }

    /// As `trace`, through `keys` wherever they are aimed.
    fn trace_through(keys: &[Point], wobble: f32) -> Vec<Point> {
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
        // Smoothing rounds the corners off, as a hurried finger does. The
        // finger lands where it aimed, though, so the first point stays put.
        let smoothed: Vec<Point> = std::iter::once(path[0])
            .chain((1..path.len()).map(|i| {
                let window = &path[i.saturating_sub(2)..(i + 3).min(path.len())];
                let n = window.len() as f32;
                (window.iter().map(|p| p.0).sum::<f32>() / n, window.iter().map(|p| p.1).sum::<f32>() / n)
            }))
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
        let got = engine.swipe("", &trace("coffee", 0.0), 2);
        assert!(got.contains(&"code".to_string()) && got.contains(&"coffee".to_string()), "{got:?}");
        assert_eq!(engine.swipe("thank ", &trace("you", 0.2), 1), ["you"]);
        assert_eq!(engine.swipe("thank", &trace("you", 0.2), 1), ["you"]);
    }

    #[test]
    fn only_look_alikes_are_contenders() {
        let engine = Engine::new();
        let close = |before: &str, path: &[Point]| -> Vec<String> {
            let readings = engine.swipe_readings(before, path, 8);
            readings[..contenders(&readings)].iter().map(|r| r.word.clone()).collect()
        };
        assert_eq!(close("", &trace("you", 0.2)), ["you"]);
        let know = close("", &trace("know", 0.2));
        assert!(know[0] == "know" && !know.contains(&"knots".to_string()), "{know:?}");
        let put = close("", &trace("put", 0.2));
        assert!(put.contains(&"pot".to_string()) && put.contains(&"pit".to_string()), "{put:?}");
        let the = close("", &trace("there", 0.2));
        assert!(the.contains(&"the".to_string()) && the.contains(&"there".to_string()), "{the:?}");
    }

    #[test]
    fn commoner_words_of_another_shape_are_not_contenders() {
        let engine = Engine::new();
        // "fabulous" with the final "s" landing up and to the left. Ten times
        // as common, "facilities" scores close behind, but its path is quite
        // different; offered it, the model once picked it after "Sounds".
        let mut keys = Vec::new();
        ideal("fabulous", &mut keys).unwrap();
        let last = keys.len() - 1;
        keys[last] = (keys[last].0 - 0.3, keys[last].1 - 0.4);
        let path = trace_through(&keys, 0.0);
        let readings = engine.swipe_readings("Sounds ", &path, 8);
        assert_eq!(readings[0].word, "fabulous");
        let facilities = readings.iter().position(|r| r.word == "facilities").expect("still offered");
        assert!(readings[0].score - readings[facilities].score <= CONTENDER_MARGIN, "{readings:?}");
        assert!(contenders(&readings) <= facilities, "{readings:?}");
        // Nor does "help" contend with a swiped "hello".
        let readings = engine.swipe_readings("", &trace("hello", 0.2), 8);
        assert_eq!(readings[..contenders(&readings)].iter().map(|r| r.word.as_str()).collect::<Vec<_>>(), ["hello"]);
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
    fn swiped_contractions_get_their_apostrophe() {
        let engine = Engine::new();
        assert_eq!(engine.swipe("", &trace("im", 0.0), 1), ["I'm"]);
        for (bare, full) in [("dont", "don't"), ("didnt", "didn't"), ("youre", "you're"), ("thats", "that's")] {
            assert_eq!(engine.swipe("", &trace(bare, 0.2), 1), [full]);
        }
        // Their look-alikes still win when they are what was swiped.
        assert_eq!(engine.swipe("", &trace("your", 0.2), 1), ["your"]);
        assert_eq!(engine.swipe("", &trace("doing", 0.2), 1), ["doing"]);
        // Where the bare letters are a word too, the contraction is offered but not entered.
        let got = engine.swipe("", &trace("were", 0.2), 8);
        assert_eq!(got[0], "were");
        assert!(got.contains(&"we're".to_string()), "{got:?}");
    }

    #[test]
    fn turnarounds_may_turn_back_early() {
        let engine = Engine::new();
        // Turning back from "n" a third of the way short traces "saved"
        // and "Indi" more closely than the words meant.
        for (before, word) in [("fish ", "and"), ("", "and"), ("went ", "into")] {
            let mut keys = Vec::new();
            ideal(word, &mut keys).unwrap();
            let mid = ((keys[0].0 + keys[2].0) / 2.0, (keys[0].1 + keys[2].1) / 2.0);
            keys[1] = (mid.0 + (keys[1].0 - mid.0) * 0.6, mid.1 + (keys[1].1 - mid.1) * 0.6);
            assert_eq!(engine.swipe(before, &trace_through(&keys, 0.1), 1), [word], "{before}{word}");
        }
    }

    #[test]
    fn words_swiped_through_the_space_bar() {
        let engine = Engine::new();
        // Where a finger crosses onto the space bar, along the top of the bottom row.
        let space = |x: f32| (x, 3.05);
        let mut keys = Vec::new();
        let mut through = |word: &str, from: Option<f32>, to: Option<f32>| -> Vec<String> {
            ideal(word, &mut keys).unwrap();
            let route: Vec<Point> = from.map(space).into_iter().chain(keys.iter().copied()).chain(to.map(space)).collect();
            let spaces = Through { from_space: from.is_some(), to_space: to.is_some() };
            engine.swipe_through("", &trace_through(&route, 0.1), spaces, 3).into_iter().map(|r| r.word).collect()
        };
        // Turning down to the space bar from the last letter, or carrying straight on past it.
        assert_eq!(through("the", None, Some(4.5))[0], "the");
        assert_eq!(through("action", None, Some(6.6))[0], "action");
        assert_eq!(through("dog", Some(5.0), Some(5.0))[0], "dog");
        assert_eq!(through("into", Some(6.0), None)[0], "into");
        // A one-letter word is a swipe up to its key and back.
        assert_eq!(through("i", Some(6.0), Some(6.5))[0], "I");
        assert_eq!(through("a", Some(4.5), Some(4.5))[0], "a");
    }

    /// Swipes recorded on a phone, one per line: the word meant, then the
    /// path as `x,y` points separated by semicolons.
    fn recorded() -> Vec<(&'static str, Vec<Point>)> {
        include_str!("testdata/swipes.txt")
            .lines()
            .map(|line| {
                let (word, path) = line.split_once(' ').unwrap();
                let point = |p: &str| {
                    let (x, y) = p.split_once(',').unwrap();
                    (x.parse().unwrap(), y.parse().unwrap())
                };
                (word, path.split(';').map(point).collect())
            })
            .collect()
    }

    #[test]
    fn decodes_recorded_swipes() {
        let engine = Engine::new();
        let results: Vec<_> = recorded().into_iter().map(|(word, path)| (word, engine.swipe("", &path, 3))).collect();
        // Real fingers turn short of keys at the edge of the keyboard, so these
        // paths are shorter than the words' ideal ones; that must not matter.
        // "sock" traces the same line as the far commoner "stock" and "shock",
        // so on its own it is anyone's guess.
        let missed: Vec<_> =
            results.iter().filter(|(word, got)| *word != "sock" && got.first().map(String::as_str) != Some(*word)).collect();
        assert!(missed.len() <= 1, "{missed:?}");
    }

    #[test]
    fn nonsense_paths_decode_to_nothing_much() {
        let engine = Engine::new();
        assert!(engine.swipe("", &[], 3).is_empty());
        assert!(engine.swipe("", &[(-40.0, 9.0), (-41.0, 9.5)], 3).is_empty());
    }
}

