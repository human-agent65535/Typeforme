use parakeet_rs::{Nemotron, NemotronMode};
use serde_json::json;
use std::env;
use std::error::Error;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread;
use std::time::Instant;

const CHUNK_SIZE: usize = 8_960;
const CONTROL_FINISH_BITS: u32 = 0x7FC0_1001;
const CONTROL_CANCEL_BITS: u32 = 0x7FC0_1002;

#[derive(Debug)]
struct Args {
    model_dir: PathBuf,
    audio: Option<PathBuf>,
    target_lang: String,
    stream_stdin_f32: bool,
}

struct StreamChunk {
    samples: Vec<f32>,
    real_samples: usize,
    flushing: bool,
}

enum StreamItem {
    Audio(StreamChunk),
    Finish,
    Cancel,
}

fn main() {
    match run() {
        Ok(()) => {}
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    }
}

fn run() -> Result<(), Box<dyn Error>> {
    let args = Args::parse()?;
    let started = Instant::now();

    if args.stream_stdin_f32 {
        let stream_chunks = spawn_stdin_chunk_reader(started);
        let mut model = Nemotron::from_pretrained(&args.model_dir, None)?;
        if model.mode() == NemotronMode::Multilingual {
            model.set_target_lang(&args.target_lang)?;
        }
        eprintln!(
            "typeforme-nemotron-asr ready mode={:?} target_lang={} load_ms={}",
            model.mode(),
            args.target_lang,
            started.elapsed().as_millis()
        );
        std::io::stderr().flush()?;
        run_streaming_stdin(&mut model, stream_chunks, started)?;
        return Ok(());
    }

    let mut model = Nemotron::from_pretrained(&args.model_dir, None)?;
    if model.mode() == NemotronMode::Multilingual {
        model.set_target_lang(&args.target_lang)?;
    }
    eprintln!(
        "typeforme-nemotron-asr ready mode={:?} target_lang={} load_ms={}",
        model.mode(),
        args.target_lang,
        started.elapsed().as_millis()
    );
    std::io::stderr().flush()?;

    let audio_path = args.audio.as_ref().ok_or("--audio is required")?;
    let audio = read_wav_mono_16khz(audio_path)?;
    let duration = audio.len() as f32 / 16_000.0;

    for chunk in audio.chunks(CHUNK_SIZE) {
        let chunk_vec = if chunk.len() < CHUNK_SIZE {
            let mut padded = chunk.to_vec();
            padded.resize(CHUNK_SIZE, 0.0);
            padded
        } else {
            chunk.to_vec()
        };
        let _ = model.transcribe_chunk(&chunk_vec)?;
    }

    for _ in 0..3 {
        let _ = model.transcribe_chunk(&vec![0.0; CHUNK_SIZE])?;
    }

    eprintln!(
        "typeforme-nemotron-asr completed in {:.2}s (audio: {:.2}s)",
        started.elapsed().as_secs_f32(),
        duration
    );
    std::io::stderr().flush()?;
    println!("{}", json!({ "text": model.get_transcript().trim() }));
    std::io::stdout().flush()?;
    Ok(())
}

impl Args {
    fn parse() -> Result<Self, Box<dyn Error>> {
        let mut model_dir: Option<PathBuf> = None;
        let mut audio: Option<PathBuf> = None;
        let mut target_lang = String::from("auto");
        let mut stream_stdin_f32 = false;
        let mut values = env::args().skip(1);

        while let Some(arg) = values.next() {
            match arg.as_str() {
                "--model-dir" => model_dir = Some(next_path(&mut values, "--model-dir")?),
                "--audio" => audio = Some(next_path(&mut values, "--audio")?),
                "--target-lang" => target_lang = next_value(&mut values, "--target-lang")?,
                "--stream-stdin-f32" => stream_stdin_f32 = true,
                "--help" | "-h" => {
                    print_usage();
                    std::process::exit(0);
                }
                other => return Err(format!("unknown argument: {other}").into()),
            }
        }

        if !stream_stdin_f32 && audio.is_none() {
            return Err("--audio is required unless --stream-stdin-f32 is set".into());
        }

        Ok(Self {
            model_dir: model_dir.ok_or("--model-dir is required")?,
            audio,
            target_lang,
            stream_stdin_f32,
        })
    }
}

fn next_path(
    values: &mut impl Iterator<Item = String>,
    option: &str,
) -> Result<PathBuf, Box<dyn Error>> {
    Ok(PathBuf::from(next_value(values, option)?))
}

fn next_value(
    values: &mut impl Iterator<Item = String>,
    option: &str,
) -> Result<String, Box<dyn Error>> {
    values
        .next()
        .ok_or_else(|| format!("missing value for {option}").into())
}

fn print_usage() {
    eprintln!(
        "usage: typeforme-nemotron-asr --model-dir DIR (--audio AUDIO.wav | --stream-stdin-f32) [--target-lang auto|en-US|zh-CN|...]"
    );
}

fn spawn_stdin_chunk_reader(started: Instant) -> Receiver<Result<StreamItem, String>> {
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        if let Err(error) = read_stdin_chunks(sender.clone(), started) {
            let _ = sender.send(Err(error));
        }
    });
    receiver
}

fn read_stdin_chunks(
    sender: Sender<Result<StreamItem, String>>,
    started: Instant,
) -> Result<(), String> {
    let mut stdin = std::io::stdin().lock();
    let mut read_buffer = [0u8; 32 * 1024];
    let mut byte_buffer: Vec<u8> = Vec::new();
    let mut sample_buffer: Vec<f32> = Vec::with_capacity(CHUNK_SIZE * 2);
    let mut first_read_logged = false;

    loop {
        let count = stdin.read(&mut read_buffer).map_err(|error| error.to_string())?;
        if count == 0 {
            break;
        }
        if !first_read_logged {
            first_read_logged = true;
            eprintln!(
                "typeforme-nemotron-asr stream first_stdin_bytes={} elapsed_ms={}",
                count,
                started.elapsed().as_millis()
            );
            std::io::stderr()
                .flush()
                .map_err(|error| error.to_string())?;
        }
        byte_buffer.extend_from_slice(&read_buffer[..count]);
        let aligned_byte_count = byte_buffer.len() / 4 * 4;
        for bytes in byte_buffer[..aligned_byte_count].chunks_exact(4) {
            let bits = u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
            match bits {
                CONTROL_FINISH_BITS => {
                    flush_stream_samples(&sender, &mut sample_buffer, true)?;
                    if sender.send(Ok(StreamItem::Finish)).is_err() {
                        return Ok(());
                    }
                }
                CONTROL_CANCEL_BITS => {
                    sample_buffer.clear();
                    if sender.send(Ok(StreamItem::Cancel)).is_err() {
                        return Ok(());
                    }
                }
                _ => sample_buffer.push(f32::from_bits(bits)),
            }
        }
        byte_buffer.drain(..aligned_byte_count);

        while sample_buffer.len() >= CHUNK_SIZE {
            let chunk: Vec<f32> = sample_buffer.drain(..CHUNK_SIZE).collect();
            if sender
                .send(Ok(StreamItem::Audio(StreamChunk {
                    samples: chunk,
                    real_samples: CHUNK_SIZE,
                    flushing: false,
                })))
                .is_err()
            {
                return Ok(());
            }
        }
    }

    if !byte_buffer.is_empty() {
        return Err("stdin Float32 stream ended with a partial sample".into());
    }

    flush_stream_samples(&sender, &mut sample_buffer, true)?;

    Ok(())
}

fn flush_stream_samples(
    sender: &Sender<Result<StreamItem, String>>,
    sample_buffer: &mut Vec<f32>,
    flushing: bool,
) -> Result<(), String> {
    if sample_buffer.is_empty() {
        return Ok(());
    }
    let real_samples = sample_buffer.len();
    sample_buffer.resize(CHUNK_SIZE, 0.0);
    let chunk = std::mem::take(sample_buffer);
    if sender
        .send(Ok(StreamItem::Audio(StreamChunk {
            samples: chunk,
            real_samples,
            flushing,
        })))
        .is_err()
    {
        return Ok(());
    }
    Ok(())
}

fn run_streaming_stdin(
    model: &mut Nemotron,
    chunks: Receiver<Result<StreamItem, String>>,
    started: Instant,
) -> Result<(), Box<dyn Error>> {
    let mut last_text = String::new();
    let mut total_samples: usize = 0;
    let mut chunk_index: usize = 0;

    for item in chunks {
        match item.map_err(|error| -> Box<dyn Error> { error.into() })? {
            StreamItem::Audio(chunk) => {
                total_samples += chunk.real_samples;
                chunk_index += 1;
                let decode_started = Instant::now();
                let _ = model.transcribe_chunk(&chunk.samples)?;
                let changed = emit_partial_if_changed(model, &mut last_text)?;
                log_stream_chunk(
                    started,
                    chunk_index,
                    total_samples,
                    decode_started.elapsed().as_millis(),
                    changed,
                    last_text.chars().count(),
                    chunk.flushing,
                )?;
            }
            StreamItem::Finish => {
                let final_text = flush_final_audio(
                    model,
                    &mut last_text,
                    &mut chunk_index,
                    total_samples,
                    started,
                )?;
                model.reset();
                emit_final(&final_text)?;
                last_text.clear();
                total_samples = 0;
                chunk_index = 0;
                eprintln!(
                    "typeforme-nemotron-asr stream reset elapsed_ms={}",
                    started.elapsed().as_millis()
                );
                std::io::stderr().flush()?;
            }
            StreamItem::Cancel => {
                model.reset();
                last_text.clear();
                total_samples = 0;
                chunk_index = 0;
                emit_cancelled()?;
                eprintln!(
                    "typeforme-nemotron-asr stream cancelled elapsed_ms={}",
                    started.elapsed().as_millis()
                );
                std::io::stderr().flush()?;
            }
        }
    }

    if total_samples == 0 && last_text.is_empty() {
        return Ok(());
    }
    let final_text = flush_final_audio(
        model,
        &mut last_text,
        &mut chunk_index,
        total_samples,
        started,
    )?;
    emit_final(&final_text)?;

    eprintln!(
        "typeforme-nemotron-asr stream completed in {:.2}s (audio: {:.2}s)",
        started.elapsed().as_secs_f32(),
        total_samples as f32 / 16_000.0
    );
    std::io::stderr().flush()?;
    Ok(())
}

fn flush_final_audio(
    model: &mut Nemotron,
    last_text: &mut String,
    chunk_index: &mut usize,
    total_samples: usize,
    started: Instant,
) -> Result<String, Box<dyn Error>> {
    for _ in 0..3 {
        *chunk_index += 1;
        let decode_started = Instant::now();
        let _ = model.transcribe_chunk(&vec![0.0; CHUNK_SIZE])?;
        let changed = emit_partial_if_changed(model, last_text)?;
        log_stream_chunk(
            started,
            *chunk_index,
            total_samples,
            decode_started.elapsed().as_millis(),
            changed,
            last_text.chars().count(),
            true,
        )?;
    }

    Ok(model.get_transcript().trim().to_string())
}

fn emit_final(text: &str) -> Result<(), Box<dyn Error>> {
    println!("{}", json!({ "event": "final", "text": text }));
    std::io::stdout().flush()?;
    Ok(())
}

fn emit_cancelled() -> Result<(), Box<dyn Error>> {
    println!("{}", json!({ "event": "cancelled", "text": "" }));
    std::io::stdout().flush()?;
    Ok(())
}

fn emit_partial_if_changed(
    model: &Nemotron,
    last_text: &mut String,
) -> Result<bool, Box<dyn Error>> {
    let text = model.get_transcript().trim().to_string();
    if text.is_empty() || text == *last_text {
        return Ok(false);
    }
    *last_text = text.clone();
    println!("{}", json!({ "event": "partial", "text": text }));
    std::io::stdout().flush()?;
    Ok(true)
}

fn log_stream_chunk(
    started: Instant,
    chunk_index: usize,
    total_samples: usize,
    decode_ms: u128,
    changed: bool,
    text_chars: usize,
    flushing: bool,
) -> Result<(), Box<dyn Error>> {
    eprintln!(
        "typeforme-nemotron-asr stream chunk={} audio_ms={} decode_ms={} changed={} text_chars={} flushing={} elapsed_ms={}",
        chunk_index,
        total_samples * 1_000 / 16_000,
        decode_ms,
        changed,
        text_chars,
        flushing,
        started.elapsed().as_millis()
    );
    std::io::stderr().flush()?;
    Ok(())
}

fn read_wav_mono_16khz(path: &PathBuf) -> Result<Vec<f32>, Box<dyn Error>> {
    let mut reader = hound::WavReader::open(path)?;
    let spec = reader.spec();
    if spec.sample_rate != 16_000 {
        return Err(format!("expected 16kHz WAV, got {}Hz", spec.sample_rate).into());
    }

    let mut audio: Vec<f32> = match spec.sample_format {
        hound::SampleFormat::Float => reader.samples::<f32>().collect::<Result<Vec<_>, _>>()?,
        hound::SampleFormat::Int => match spec.bits_per_sample {
            8 => reader
                .samples::<i8>()
                .map(|sample| sample.map(|value| value as f32 / 128.0))
                .collect::<Result<Vec<_>, _>>()?,
            16 => reader
                .samples::<i16>()
                .map(|sample| sample.map(|value| value as f32 / 32_768.0))
                .collect::<Result<Vec<_>, _>>()?,
            24 | 32 => reader
                .samples::<i32>()
                .map(|sample| sample.map(|value| value as f32 / 2_147_483_648.0))
                .collect::<Result<Vec<_>, _>>()?,
            bits => return Err(format!("unsupported PCM bit depth: {bits}").into()),
        },
    };

    if spec.channels > 1 {
        let channels = spec.channels as usize;
        audio = audio
            .chunks(channels)
            .map(|chunk| chunk.iter().sum::<f32>() / channels as f32)
            .collect();
    }

    let max_value = audio.iter().fold(0.0f32, |acc, value| acc.max(value.abs()));
    if max_value > 1e-6 {
        for value in &mut audio {
            *value /= max_value + 1e-5;
        }
    }

    Ok(audio)
}
