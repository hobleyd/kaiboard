//! Edit distance tuned for thumb typing on a QWERTY layout.

use std::sync::OnceLock;

const ROWS: [(&[u8], f32); 3] = [(b"qwertyuiop", 0.0), (b"asdfghjkl", 0.5), (b"zxcvbnm", 1.5)];

const MAX_LEN: usize = 32;

const SUBSTITUTE: f32 = 1.0;
const SUBSTITUTE_NEIGHBOUR: f32 = 0.7;
const FIRST_LETTER_PENALTY: f32 = 0.4;
const INSERT_OR_DELETE: f32 = 1.0;
const DOUBLED_LETTER: f32 = 0.6;
const TRANSPOSE: f32 = 0.4;

fn centers() -> &'static [(f32, f32); 26] {
    static TABLE: OnceLock<[(f32, f32); 26]> = OnceLock::new();
    TABLE.get_or_init(|| {
        let mut pos = [(0.0f32, 0.0f32); 26];
        for (row, (keys, offset)) in ROWS.iter().enumerate() {
            for (col, key) in keys.iter().enumerate() {
                pos[(key - b'a') as usize] = (col as f32 + offset + 0.5, row as f32 + 0.5);
            }
        }
        pos
    })
}

/// Centre of a lowercase letter's key, in key widths from the left edge of the
/// keyboard and rows from the top of the letter grid.
pub fn key_center(letter: u8) -> Option<(f32, f32)> {
    letter.is_ascii_lowercase().then(|| centers()[(letter - b'a') as usize])
}

fn neighbours() -> &'static [[bool; 26]; 26] {
    static TABLE: OnceLock<[[bool; 26]; 26]> = OnceLock::new();
    TABLE.get_or_init(|| {
        let pos = centers();
        let mut table = [[false; 26]; 26];
        for a in 0..26 {
            for b in 0..26 {
                let (dx, dy) = (pos[a].0 - pos[b].0, pos[a].1 - pos[b].1);
                table[a][b] = a != b && dy.abs() <= 1.0 && dx.abs() <= 1.1;
            }
        }
        table
    })
}

/// Whether two lowercase ASCII letters sit next to each other on the keyboard.
pub fn adjacent(a: u8, b: u8) -> bool {
    a.is_ascii_lowercase() && b.is_ascii_lowercase() && neighbours()[(a - b'a') as usize][(b - b'a') as usize]
}

/// Cost of `typed` being a slip of the thumb for `intended`, or `None` when it
/// exceeds `max`. Both are lowercase bytes.
pub fn typo_cost(typed: &[u8], intended: &[u8], max: f32) -> Option<f32> {
    let (n, m) = (typed.len(), intended.len());
    if n > MAX_LEN || m > MAX_LEN {
        return None;
    }
    // People rarely get the first letter of a word wrong.
    let edge = |index: usize| if index == 1 { FIRST_LETTER_PENALTY } else { 0.0 };
    let mut d = [[0.0f32; MAX_LEN + 1]; MAX_LEN + 1];
    for j in 1..=m {
        d[0][j] = d[0][j - 1] + INSERT_OR_DELETE + edge(j);
    }
    for i in 1..=n {
        d[i][0] = d[i - 1][0] + INSERT_OR_DELETE + edge(i);
        let mut row_min = d[i][0];
        for j in 1..=m {
            let (t, c) = (typed[i - 1], intended[j - 1]);

            let substitute = if t == c {
                0.0
            } else {
                let base = if adjacent(t, c) { SUBSTITUTE_NEIGHBOUR } else { SUBSTITUTE };
                base + edge(i.max(j))
            };
            let mut best = d[i - 1][j - 1] + substitute;

            // An extra typed letter; cheaper when the key simply registered twice.
            let extra = if i > 1 && typed[i - 2] == t { DOUBLED_LETTER } else { INSERT_OR_DELETE };
            best = best.min(d[i - 1][j] + extra);

            // A missing letter; cheaper when it is half of a double ("adress").
            let missing = if j > 1 && intended[j - 2] == c { DOUBLED_LETTER } else { INSERT_OR_DELETE };
            best = best.min(d[i][j - 1] + missing);

            if i > 1 && j > 1 && t == intended[j - 2] && typed[i - 2] == c && t != c {
                best = best.min(d[i - 2][j - 2] + TRANSPOSE);
            }

            d[i][j] = best;
            row_min = row_min.min(best);
        }
        if row_min > max {
            return None;
        }
    }
    (d[n][m] <= max).then_some(d[n][m])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cost(a: &str, b: &str) -> Option<f32> {
        typo_cost(a.as_bytes(), b.as_bytes(), 2.0)
    }

    #[test]
    fn keyboard_neighbours() {
        assert!(adjacent(b'q', b'w'));
        assert!(adjacent(b'z', b's'));
        assert!(adjacent(b'g', b'b'));
        assert!(!adjacent(b'q', b'p'));
        assert!(!adjacent(b'a', b'a'));
    }

    #[test]
    fn costs() {
        assert_eq!(cost("hello", "hello"), Some(0.0));
        assert_eq!(cost("teh", "the"), Some(TRANSPOSE));
        assert_eq!(cost("adress", "address"), Some(DOUBLED_LETTER));
        assert_eq!(cost("helli", "hello"), Some(SUBSTITUTE_NEIGHBOUR));
        assert_eq!(cost("hellp", "hello"), Some(SUBSTITUTE_NEIGHBOUR));
        assert_eq!(cost("hexlo", "hello"), Some(SUBSTITUTE));
        assert_eq!(cost("wor", "or"), Some(INSERT_OR_DELETE + FIRST_LETTER_PENALTY));
        assert_eq!(cost("keyboard", "elephant"), None);
    }
}
