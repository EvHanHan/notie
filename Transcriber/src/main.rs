use anyhow::{anyhow, Context, Result};
use chrono::Utc;
use hound::{SampleFormat, WavReader};
use reqwest::blocking::Client;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;
use transcribe_cpp::{Model, RunOptions};

const MODEL_NAME: &str = "parakeet-tdt-0.6b-v2-Q4_K_M.gguf";
const MODEL_URL: &str = "https://huggingface.co/handy-computer/parakeet-tdt-0.6b-v2-gguf/resolve/07cee0616125a08ef619729bb47f40ef747e4bc4/parakeet-tdt-0.6b-v2-Q4_K_M.gguf?download=true";
const MODEL_SHA256: &str = "4853f9653f641d376e6f7de65d73c7a34a73677704a606727bf51acc83f999f3";

#[derive(Deserialize)]
struct SessionMeta {
    duration_seconds: i64,
    files: TrackFiles,
    start_offset_ms: TrackOffsets,
}

#[derive(Deserialize)]
struct TrackFiles {
    mic: String,
    system: String,
}

#[derive(Deserialize)]
struct TrackOffsets {
    mic: i64,
    system: i64,
}

#[derive(Serialize)]
struct TranscriptDocument {
    engine: String,
    model: String,
    language: String,
    created: String,
    duration_seconds: i64,
    segments: Vec<TranscriptSegment>,
}

#[derive(Serialize)]
struct TranscriptSegment {
    speaker: String,
    start: f64,
    end: f64,
    text: String,
    confidence: f32,
}

fn main() {
    if let Err(error) = run() {
        emit(&format!("error\t{}", error));
        if let Some(session) = std::env::args().nth(1) {
            let _ = append_log(Path::new(&session), &error.to_string());
        }
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let session = std::env::args()
        .nth(1)
        .ok_or_else(|| anyhow!("Usage: notie-transcriber <session-directory>"))?;
    let session = PathBuf::from(session);
    let meta: SessionMeta = serde_json::from_reader(
        File::open(session.join("meta.json")).context("Session is missing or has invalid meta.json")?,
    )?;

    emit("status\tLoading Parakeet TDT 0.6B v2 model (downloads once if needed)…");
    let model_path = ensure_model()?;
    emit("status\tLoading local transcription engine…");
    let mut session_model = Model::load(model_path.to_str().unwrap())
        .context("Could not load the Whisper GGUF model")?
        .session()
        .context("Could not create a transcription session")?;

    let tracks = [
        ("me", meta.files.mic, meta.start_offset_ms.mic),
        ("them", meta.files.system, meta.start_offset_ms.system),
    ];
    let mut segments = Vec::new();
    for (speaker, filename, offset_ms) in tracks {
        let path = session.join(filename);
        if !path.exists() {
            continue;
        }
        emit(&format!("status\tTranscribing {speaker}…"));
        let (audio, duration) = read_wav_16khz_mono(&path)?;
        if audio.is_empty() {
            continue;
        }
        let result = session_model
            .run(&audio, &RunOptions::default())
            .with_context(|| format!("Could not transcribe {}", path.display()))?;
        let text = result.text.trim().to_string();
        if !text.is_empty() {
            let start = offset_ms.max(0) as f64 / 1000.0;
            segments.push(TranscriptSegment {
                speaker: speaker.to_string(),
                start,
                end: start + duration,
                text,
                confidence: 0.0,
            });
        }
    }

    segments.sort_by(|a, b| a.start.partial_cmp(&b.start).unwrap_or(std::cmp::Ordering::Equal));
    let document = TranscriptDocument {
        engine: "transcribe-cpp".into(),
        model: "Parakeet TDT 0.6B v2 Q4_K_M".into(),
        language: "en".into(),
        created: iso8601_now(),
        duration_seconds: meta.duration_seconds,
        segments,
    };
    let json = serde_json::to_vec_pretty(&document)?;
    fs::write(session.join("transcript.json"), json).context("Could not write transcript.json")?;
    fs::write(session.join("transcript.md"), render_markdown(&document))
        .context("Could not write transcript.md")?;
    emit("status\tTranscript ready");
    Ok(())
}

fn ensure_model() -> Result<PathBuf> {
    let home = std::env::var_os("HOME").ok_or_else(|| anyhow!("HOME is not available"))?;
    let directory = PathBuf::from(home).join("Library/Application Support/Notie/Models");
    fs::create_dir_all(&directory).context("Could not create the model cache directory")?;
    let destination = directory.join(MODEL_NAME);
    if destination.exists() && sha256(&destination)? == MODEL_SHA256 {
        return Ok(destination);
    }

    emit("status\tDownloading Parakeet TDT 0.6B v2 model…");
    let response = Client::builder()
        .timeout(Duration::from_secs(3600))
        .build()?
        .get(MODEL_URL)
        .send()
        .map_err(|error| anyhow!("Could not download the transcription model from {MODEL_URL}: {error}"))?;
    if !response.status().is_success() {
        return Err(anyhow!("The transcription model download failed with HTTP {}", response.status()));
    }
    let total = response.content_length();
    let partial = destination.with_extension("gguf.part");
    let mut input = response;
    let mut output = File::create(&partial)?;
    let mut downloaded = 0u64;
    let mut buffer = [0u8; 1024 * 1024];
    loop {
        let count = input.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        output.write_all(&buffer[..count])?;
        downloaded += count as u64;
        if let Some(total) = total {
            emit(&format!("progress\t{}", (downloaded.saturating_mul(100) / total).min(100)));
        }
    }
    output.sync_all()?;
    if sha256(&partial)? != MODEL_SHA256 {
        let _ = fs::remove_file(&partial);
        return Err(anyhow!("Downloaded model checksum did not match"));
    }
    fs::rename(partial, &destination)?;
    Ok(destination)
}

fn sha256(path: &Path) -> Result<String> {
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 1024 * 1024];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

fn read_wav_16khz_mono(path: &Path) -> Result<(Vec<f32>, f64)> {
    let mut reader = WavReader::open(path).with_context(|| format!("Could not open {}", path.display()))?;
    let spec = reader.spec();
    if spec.channels == 0 || spec.sample_rate == 0 {
        return Err(anyhow!("Invalid WAV format in {}", path.display()));
    }
    let channels = spec.channels as usize;
    let mut mono = Vec::new();
    match spec.sample_format {
        SampleFormat::Float => {
            let mut frame = Vec::with_capacity(channels);
            for sample in reader.samples::<f32>() {
                frame.push(sample?);
                if frame.len() == channels {
                    mono.push(frame.iter().sum::<f32>() / channels as f32);
                    frame.clear();
                }
            }
        }
        SampleFormat::Int => {
            let scale = 2f32.powi(spec.bits_per_sample.saturating_sub(1) as i32);
            let mut frame = Vec::with_capacity(channels);
            for sample in reader.samples::<i32>() {
                frame.push(sample? as f32 / scale);
                if frame.len() == channels {
                    mono.push(frame.iter().sum::<f32>() / channels as f32);
                    frame.clear();
                }
            }
        }
    }
    let duration = mono.len() as f64 / spec.sample_rate as f64;
    if spec.sample_rate == 16_000 {
        return Ok((mono, duration));
    }
    let output_len = ((mono.len() as f64) * 16_000.0 / spec.sample_rate as f64).round() as usize;
    let ratio = spec.sample_rate as f64 / 16_000.0;
    let mut resampled = Vec::with_capacity(output_len);
    for index in 0..output_len {
        let position = index as f64 * ratio;
        let left = position.floor() as usize;
        let right = (left + 1).min(mono.len().saturating_sub(1));
        let fraction = (position - left as f64) as f32;
        resampled.push(mono[left.min(mono.len().saturating_sub(1))] * (1.0 - fraction) + mono[right] * fraction);
    }
    Ok((resampled, duration))
}

fn render_markdown(document: &TranscriptDocument) -> String {
    let mut output = format!("# Transcript\n\nEngine: {} — {}\n\n", document.engine, document.model);
    for segment in &document.segments {
        output.push_str(&format!("[{}] **{}**: {}\n\n", format_time(segment.start), segment.speaker, segment.text));
    }
    output
}

fn format_time(seconds: f64) -> String {
    let total = seconds.max(0.0).round() as u64;
    format!("{:02}:{:02}", total / 60, total % 60)
}

fn append_log(session: &Path, message: &str) -> Result<()> {
    let mut file = fs::OpenOptions::new().create(true).append(true).open(session.join("transcribe.log"))?;
    writeln!(file, "[{}] {}", iso8601_now(), message)?;
    Ok(())
}

fn iso8601_now() -> String {
    Utc::now().to_rfc3339()
}

fn emit(message: &str) {
    println!("{message}");
    let _ = std::io::stdout().flush();
}
