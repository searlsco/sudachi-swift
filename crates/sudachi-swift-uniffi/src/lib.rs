//! UniFFI wrapper exposing [sudachi.rs](https://github.com/WorksApplications/sudachi.rs)
//! — the Sudachi Japanese morphological analyzer — to Swift (iOS/macOS).
//!
//! The Swift-facing surface is defined by `sudachi_swift.udl` and implemented
//! here; `scripts/build-ios.sh` regenerates the Swift bindings and the
//! `Sudachi.xcframework` from the two. Design notes live in
//! `docs/ARCHITECTURE.md`.
//!
//! The hand-written code here is 100% safe Rust; the only `unsafe` in the
//! crate lives in the UniFFI-generated scaffolding (`#[unsafe(no_mangle)]`
//! exports), which precludes a crate-level `#![deny(unsafe_code)]`.

// UniFFI's generated scaffolding defines its UDL metadata as a large `const`
// array, which newer clippy (1.98+) rejects under `-D warnings`. The lint cannot
// be scoped to the `include_scaffolding!` expansion, so it is allowed here.
#![allow(clippy::large_const_arrays)]

use std::path::{Path, PathBuf};
use std::sync::Arc;

use parking_lot::Mutex;
use thiserror::Error;

use sudachi::analysis::mlist::MorphemeList;
use sudachi::analysis::stateful_tokenizer::StatefulTokenizer;
use sudachi::analysis::Mode as SudachiMode;
use sudachi::config::ConfigBuilder;
use sudachi::dic::dictionary::JapaneseDictionary;

uniffi::include_scaffolding!("sudachi_swift");

/// Default `sudachi.json` baked into the binary. Source:
/// `third_party/sudachi.rs/resources/sudachi.json` (Apache-2.0). Plugin
/// classes here all use bundled implementations — on iOS the DSO fallback
/// is gracefully disabled (`sudachi/src/plugin/loader.rs:70-82`).
const DEFAULT_CONFIG_JSON: &[u8] = include_bytes!("default_config.json");

// ----- Errors -----

#[derive(Debug, Error)]
pub enum SudachiError {
    #[error("Dictionary file not found: {message}")]
    DictionaryNotFound { message: String },
    #[error("Dictionary file invalid: {message}")]
    DictionaryInvalid { message: String },
    #[error("Config invalid: {message}")]
    ConfigInvalid { message: String },
    #[error("Tokenization failed: {message}")]
    Tokenization { message: String },
}

impl From<sudachi::error::SudachiError> for SudachiError {
    fn from(e: sudachi::error::SudachiError) -> Self {
        let message = e.to_string();
        Self::classify(&e, message)
    }
}

impl SudachiError {
    /// Map a `sudachi.rs` error onto our Swift-facing taxonomy by matching on
    /// the actual error *variants* (not on message text, which is
    /// locale/version-dependent). `ErrWithContext` wrappers are unwrapped so we
    /// classify by the root cause while keeping the full contextual message.
    fn classify(e: &sudachi::error::SudachiError, message: String) -> Self {
        use sudachi::error::SudachiError as S;
        match e {
            S::ErrWithContext { cause, .. } => Self::classify(cause, message),
            S::Io { cause, .. } => {
                if cause.kind() == std::io::ErrorKind::NotFound {
                    Self::DictionaryNotFound { message }
                } else {
                    Self::DictionaryInvalid { message }
                }
            }
            S::ConfigError(_) => Self::ConfigInvalid { message },
            S::InvalidHeader(_)
            | S::LexiconSetError(_)
            | S::InvalidCharacterCategory(_)
            | S::InvalidDataFormat(..)
            | S::InvalidDictionaryGrammar
            | S::DictionaryCompilationError(_) => Self::DictionaryInvalid { message },
            _ => Self::Tokenization { message },
        }
    }
}

// ----- Split mode -----

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SplitMode {
    A,
    B,
    C,
}

impl From<SplitMode> for SudachiMode {
    fn from(m: SplitMode) -> Self {
        match m {
            SplitMode::A => SudachiMode::A,
            SplitMode::B => SudachiMode::B,
            SplitMode::C => SudachiMode::C,
        }
    }
}

impl From<SudachiMode> for SplitMode {
    fn from(m: SudachiMode) -> Self {
        match m {
            SudachiMode::A => SplitMode::A,
            SudachiMode::B => SplitMode::B,
            SudachiMode::C => SplitMode::C,
        }
    }
}

// ----- Morpheme (FFI value type) -----

pub struct Morpheme {
    pub surface: String,
    pub reading_form: String,
    pub dictionary_form: String,
    pub normalized_form: String,
    pub part_of_speech: Vec<String>,
    pub synonym_group_ids: Vec<u32>,
    pub is_oov: bool,
    pub word_id: u32,
    pub begin: u32,
    pub end: u32,
}

// ----- Morpheme (compact FFI value type) -----

/// Lean morpheme carrying only the fields the Swift display/merge pipeline
/// consumes, with `part_of_speech` pre-joined into a single comma string
/// and a raw `pos_id` for cheap integer checks. See `tokenize_lite`.
pub struct MorphemeLite {
    pub surface: String,
    pub dictionary_form: String,
    pub reading_form: String,
    pub part_of_speech: String,
    pub pos_id: u16,
}

// ----- Dictionary -----

pub struct SudachiDictionary {
    inner: Arc<JapaneseDictionary>,
}

impl SudachiDictionary {
    pub fn new(
        system_dict_path: String,
        user_dict_paths: Vec<String>,
        resource_dir: String,
    ) -> Result<Self, SudachiError> {
        // Validate paths up front so a missing file yields a precise error
        // naming the offending path, before we ever touch the loader.
        Self::validate_paths(&system_dict_path, &user_dict_paths, &resource_dir)?;

        let builder = Self::config_builder(DEFAULT_CONFIG_JSON)?
            .system_dict(PathBuf::from(&system_dict_path))
            .resource_path(PathBuf::from(&resource_dir));
        let builder = Self::apply_user_dicts(builder, &user_dict_paths);

        let config = builder.build();
        let dict = JapaneseDictionary::from_cfg(&config).map_err(SudachiError::from)?;
        Ok(Self {
            inner: Arc::new(dict),
        })
    }

    /// Validate that the dictionary/resource paths exist before handing them to
    /// the loader, so a missing file surfaces as a precise `DictionaryNotFound`
    /// / `ConfigInvalid` naming the offending path rather than an opaque loader
    /// failure. Only stats paths (no dictionary is read), so it is unit-testable
    /// without a dictionary on disk.
    fn validate_paths(
        system_dict_path: &str,
        user_dict_paths: &[String],
        resource_dir: &str,
    ) -> Result<(), SudachiError> {
        if !Path::new(system_dict_path).is_file() {
            return Err(SudachiError::DictionaryNotFound {
                message: format!("system dictionary not found: {system_dict_path}"),
            });
        }
        for udp in user_dict_paths {
            if !Path::new(udp).is_file() {
                return Err(SudachiError::DictionaryNotFound {
                    message: format!("user dictionary not found: {udp}"),
                });
            }
        }
        if !Path::new(resource_dir).is_dir() {
            return Err(SudachiError::ConfigInvalid {
                message: format!("resource directory not found: {resource_dir}"),
            });
        }
        Ok(())
    }

    /// Register each user-dictionary path in the config. This only wires the
    /// paths in — the files are loaded later by `from_cfg` — so it is unit-
    /// testable without a valid user dictionary on disk (loading a bogus user
    /// dict panics deep inside the loader, so it can't be driven through `new`).
    fn apply_user_dicts(mut builder: ConfigBuilder, user_dict_paths: &[String]) -> ConfigBuilder {
        for udp in user_dict_paths {
            builder = builder.user_dict(PathBuf::from(udp));
        }
        builder
    }

    /// Parse a `sudachi.json` byte blob into a `ConfigBuilder`, mapping a parse
    /// failure onto `ConfigInvalid`. Extracted from `new` so the error mapping
    /// is unit-testable — at runtime `new` only ever feeds it the valid baked
    /// `DEFAULT_CONFIG_JSON`, so its error arm is otherwise unreachable.
    fn config_builder(config_json: &[u8]) -> Result<ConfigBuilder, SudachiError> {
        ConfigBuilder::from_bytes(config_json).map_err(|e| SudachiError::ConfigInvalid {
            message: format!("{e}"),
        })
    }
}

// ----- Tokenizer -----

pub struct SudachiTokenizer {
    dict: Arc<JapaneseDictionary>,
    tok: Mutex<StatefulTokenizer<Arc<JapaneseDictionary>>>,
}

impl SudachiTokenizer {
    /// Infallible today, but returns `Result` to match the UDL's
    /// `[Throws=SudachiError]` constructor — the FFI contract keeps room for
    /// future failure modes (e.g. per-tokenizer config) without a breaking
    /// signature change.
    pub fn new(dictionary: Arc<SudachiDictionary>, mode: SplitMode) -> Result<Self, SudachiError> {
        // The underlying stateful tokenizer holds the default mode; `*_with_mode`
        // calls temporarily override and then restore it (see `tokenize`).
        let tok = StatefulTokenizer::new(dictionary.inner.clone(), mode.into());
        Ok(Self {
            dict: dictionary.inner.clone(),
            tok: Mutex::new(tok),
        })
    }

    pub fn tokenize(&self, text: String) -> Result<Vec<Morpheme>, SudachiError> {
        // Invariant: outside a `*_with_mode` call the underlying tokenizer is
        // always at `default_mode`, so the default path needs no mode juggling.
        let mut tok = self.tok.lock();
        Self::run_full(&self.dict, &mut tok, &text)
    }

    pub fn tokenize_with_mode(
        &self,
        text: String,
        mode: SplitMode,
    ) -> Result<Vec<Morpheme>, SudachiError> {
        let mut tok = self.tok.lock();
        let restore = tok.set_mode(mode.into());
        let out = Self::run_full(&self.dict, &mut tok, &text);
        // Restore whether or not tokenization succeeded, so mode never leaks
        // into the next call.
        let _ = tok.set_mode(restore);
        out
    }

    // ----- Lean / batch API (additive; existing methods unchanged) -----

    /// Lean single-text tokenize. See `MorphemeLite`.
    pub fn tokenize_lite(&self, text: String) -> Result<Vec<MorphemeLite>, SudachiError> {
        let mut tok = self.tok.lock();
        Self::run_lite(&self.dict, &mut tok, &text)
    }

    /// Lean single-text tokenize with an explicit split mode.
    pub fn tokenize_lite_with_mode(
        &self,
        text: String,
        mode: SplitMode,
    ) -> Result<Vec<MorphemeLite>, SudachiError> {
        let mut tok = self.tok.lock();
        let restore = tok.set_mode(mode.into());
        let out = Self::run_lite(&self.dict, &mut tok, &text);
        let _ = tok.set_mode(restore);
        out
    }

    /// Batch tokenize using the tokenizer's default mode.
    pub fn tokenize_many(
        &self,
        texts: Vec<String>,
    ) -> Result<Vec<Vec<MorphemeLite>>, SudachiError> {
        let mut tok = self.tok.lock();
        let mut out = Vec::with_capacity(texts.len());
        for text in &texts {
            out.push(Self::run_lite(&self.dict, &mut tok, text)?);
        }
        Ok(out)
    }

    /// Batch tokenize with an explicit split mode, holding the lock once for
    /// the whole batch so we pay a single FFI crossing and a single lock.
    pub fn tokenize_many_with_mode(
        &self,
        texts: Vec<String>,
        mode: SplitMode,
    ) -> Result<Vec<Vec<MorphemeLite>>, SudachiError> {
        let mut tok = self.tok.lock();
        let restore = tok.set_mode(mode.into());
        let mut out = Vec::with_capacity(texts.len());
        let mut result = Ok(());
        for text in &texts {
            match Self::run_lite(&self.dict, &mut tok, text) {
                Ok(v) => out.push(v),
                Err(e) => {
                    result = Err(e);
                    break;
                }
            }
        }
        let _ = tok.set_mode(restore);
        result.map(|()| out)
    }

    /// Tokenize one string into full `Morpheme`s with the tokenizer already
    /// locked and its mode already set.
    fn run_full(
        dict: &Arc<JapaneseDictionary>,
        tok: &mut StatefulTokenizer<Arc<JapaneseDictionary>>,
        text: &str,
    ) -> Result<Vec<Morpheme>, SudachiError> {
        tok.reset().push_str(text);
        tok.do_tokenize()?;

        let mut morphemes = MorphemeList::empty(dict.clone());
        morphemes.collect_results(tok)?;

        let result = morphemes
            .iter()
            .map(|m| Morpheme {
                surface: m.surface().to_string(),
                reading_form: m.reading_form().to_string(),
                dictionary_form: m.dictionary_form().to_string(),
                normalized_form: m.normalized_form().to_string(),
                part_of_speech: m.part_of_speech().to_vec(),
                synonym_group_ids: m.synonym_group_ids().to_vec(),
                is_oov: m.is_oov(),
                word_id: m.word_id().as_raw(),
                // Use char offsets (codepoint-indexed), not byte offsets —
                // Swift String indexing is scalar/grapheme based, so byte
                // indices misalign on every kanji. The casts cannot truncate:
                // sudachi.rs caps input at u16::MAX / 4 * 3 bytes (~49 KB),
                // so codepoint indices always fit u32 with room to spare.
                begin: u32::try_from(m.begin_c()).unwrap_or(u32::MAX),
                end: u32::try_from(m.end_c()).unwrap_or(u32::MAX),
            })
            .collect();

        Ok(result)
    }

    /// Tokenize one string into `MorphemeLite` with the tokenizer already
    /// locked and its mode already set.
    fn run_lite(
        dict: &Arc<JapaneseDictionary>,
        tok: &mut StatefulTokenizer<Arc<JapaneseDictionary>>,
        text: &str,
    ) -> Result<Vec<MorphemeLite>, SudachiError> {
        tok.reset().push_str(text);
        tok.do_tokenize()?;

        let mut morphemes = MorphemeList::empty(dict.clone());
        morphemes.collect_results(tok)?;

        let result = morphemes
            .iter()
            .map(|m| MorphemeLite {
                surface: m.surface().to_string(),
                dictionary_form: m.dictionary_form().to_string(),
                reading_form: m.reading_form().to_string(),
                // Pre-join here so Swift doesn't marshal N POS strings per token
                // just to `.joined(",")` them on the other side.
                part_of_speech: m.part_of_speech().join(","),
                pos_id: m.part_of_speech_id(),
            })
            .collect();

        Ok(result)
    }
}

// ----- Free helpers -----

/// Convert Sudachi-style katakana reading to hiragana for furigana display.
/// Only affects the katakana block (U+30A1..U+30F6); other characters (incl.
/// the prolonged sound mark U+30FC) pass through unchanged.
pub fn katakana_to_hiragana(s: String) -> String {
    s.chars()
        .map(|c| {
            let cp = c as u32;
            if (0x30A1..=0x30F6).contains(&cp) {
                char::from_u32(cp - 0x60).unwrap_or(c)
            } else {
                c
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn katakana_maps_to_hiragana() {
        assert_eq!(katakana_to_hiragana("カタカナ".to_string()), "かたかな");
    }

    #[test]
    fn katakana_passthrough_non_katakana() {
        // ASCII, kanji, and the prolonged sound mark (ー, U+30FC) pass through.
        assert_eq!(katakana_to_hiragana("ABC漢字ー".to_string()), "ABC漢字ー");
    }

    #[test]
    fn split_mode_round_trips() {
        for m in [SplitMode::A, SplitMode::B, SplitMode::C] {
            let round: SplitMode = SudachiMode::from(m).into();
            assert_eq!(m, round);
        }
    }

    #[test]
    fn io_not_found_maps_to_dictionary_not_found() {
        // Build a sudachi Io error via its own From<io::Error> (works around
        // the enum being #[non_exhaustive] / not externally constructible).
        let io = std::io::Error::from(std::io::ErrorKind::NotFound);
        let sudachi_err: sudachi::error::SudachiError = io.into();
        assert!(matches!(
            SudachiError::from(sudachi_err),
            SudachiError::DictionaryNotFound { .. }
        ));
    }

    #[test]
    fn io_other_maps_to_dictionary_invalid() {
        let io = std::io::Error::from(std::io::ErrorKind::PermissionDenied);
        let sudachi_err: sudachi::error::SudachiError = io.into();
        assert!(matches!(
            SudachiError::from(sudachi_err),
            SudachiError::DictionaryInvalid { .. }
        ));
    }

    #[test]
    fn config_error_maps_to_config_invalid() {
        // A malformed config yields a ConfigError, which must classify as
        // ConfigInvalid rather than the generic Tokenization fallback.
        let cfg_err = ConfigBuilder::from_bytes(b"this is not json").unwrap_err();
        let sudachi_err: sudachi::error::SudachiError = cfg_err.into();
        assert!(matches!(
            SudachiError::from(sudachi_err),
            SudachiError::ConfigInvalid { .. }
        ));
    }

    #[test]
    fn dictionary_structure_error_maps_to_dictionary_invalid() {
        // Any dictionary-structure variant (here: a malformed data row) must
        // classify as DictionaryInvalid.
        let sudachi_err = sudachi::error::SudachiError::InvalidDataFormat(0, "bad row".to_string());
        assert!(matches!(
            SudachiError::from(sudachi_err),
            SudachiError::DictionaryInvalid { .. }
        ));
    }

    #[test]
    fn unrelated_error_falls_through_to_tokenization() {
        // An error outside the recognized taxonomy (parse-int) hits the `_` arm.
        let parse_err = "not a number".parse::<i64>().unwrap_err();
        let sudachi_err: sudachi::error::SudachiError = parse_err.into();
        assert!(matches!(
            SudachiError::from(sudachi_err),
            SudachiError::Tokenization { .. }
        ));
    }

    #[test]
    fn err_with_context_is_classified_by_root_cause() {
        // ErrWithContext must be unwrapped and classified by its root cause: a
        // NotFound Io error wrapped in context still maps to DictionaryNotFound.
        let io = std::io::Error::from(std::io::ErrorKind::NotFound);
        let inner: sudachi::error::SudachiError = io.into();
        let wrapped = sudachi::error::SudachiError::ErrWithContext {
            context: "while opening the system dictionary".to_string(),
            cause: Box::new(inner),
        };
        assert!(matches!(
            SudachiError::from(wrapped),
            SudachiError::DictionaryNotFound { .. }
        ));
    }

    // ----- SudachiDictionary::new path validation (no real dictionary needed) -----

    fn write_temp_file(name: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("sudachi_swift_test_{name}"));
        std::fs::write(&p, b"x").unwrap();
        p
    }

    #[test]
    fn new_dictionary_missing_system_dict_is_not_found() {
        // `matches!` on the result (not `unwrap_err`) since the Ok type,
        // SudachiDictionary, deliberately isn't Debug.
        let result = SudachiDictionary::new(
            "/no/such/system_core.dic".to_string(),
            vec![],
            std::env::temp_dir().to_string_lossy().into_owned(),
        );
        assert!(matches!(
            result,
            Err(SudachiError::DictionaryNotFound { .. })
        ));
    }

    #[test]
    fn new_dictionary_missing_user_dict_is_not_found() {
        // A present system file but a missing user dict must fail at the
        // user-dict check, before any dictionary bytes are read.
        let sys = write_temp_file("user_case_sys.dic");
        let result = SudachiDictionary::new(
            sys.to_string_lossy().into_owned(),
            vec!["/no/such/user.dic".to_string()],
            std::env::temp_dir().to_string_lossy().into_owned(),
        );
        assert!(matches!(
            result,
            Err(SudachiError::DictionaryNotFound { .. })
        ));
        let _ = std::fs::remove_file(&sys);
    }

    #[test]
    fn new_dictionary_missing_resource_dir_is_config_invalid() {
        let sys = write_temp_file("resource_case_sys.dic");
        let result = SudachiDictionary::new(
            sys.to_string_lossy().into_owned(),
            vec![],
            "/no/such/resource/dir".to_string(),
        );
        assert!(matches!(result, Err(SudachiError::ConfigInvalid { .. })));
        let _ = std::fs::remove_file(&sys);
    }

    #[test]
    fn config_builder_rejects_malformed_json() {
        // Exercises the ConfigInvalid mapping on the config-parse error arm that
        // `new` never reaches at runtime (its baked config is always valid).
        let result = SudachiDictionary::config_builder(b"definitely not json");
        assert!(matches!(result, Err(SudachiError::ConfigInvalid { .. })));
    }

    #[test]
    fn validate_paths_accepts_existing_paths() {
        // Existing system + existing user + existing resource dir validates OK.
        // This is the only path that exercises the "user file present, keep
        // going" branch of the validation loop.
        let sys = write_temp_file("validate_ok_sys.dic");
        let usr = write_temp_file("validate_ok_usr.dic");
        let resource = std::env::temp_dir();
        let ok = SudachiDictionary::validate_paths(
            &sys.to_string_lossy(),
            &[usr.to_string_lossy().into_owned()],
            &resource.to_string_lossy(),
        );
        assert!(ok.is_ok());
        let _ = std::fs::remove_file(&sys);
        let _ = std::fs::remove_file(&usr);
    }

    #[test]
    fn apply_user_dicts_registers_paths_without_loading() {
        // Wiring a user-dict path only registers it in the config; it must not
        // require the file to exist (loading happens later, in from_cfg).
        let builder =
            SudachiDictionary::config_builder(DEFAULT_CONFIG_JSON).expect("baked config parses");
        let wired =
            SudachiDictionary::apply_user_dicts(builder, &["/nonexistent/user.dic".to_string()]);
        let _ = wired.build(); // succeeds — no file access — proving it only registered the path
    }
}
