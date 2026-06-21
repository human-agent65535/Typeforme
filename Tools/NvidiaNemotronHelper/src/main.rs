use parakeet_rs::{Nemotron, NemotronMode};
use serde_json::json;
use std::env;
use std::error::Error;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::time::Instant;

const CHUNK_SIZE: usize = 8_960;

#[derive(Debug)]
struct Args {
    model_dir: PathBuf,
    audio: Option<PathBuf>,
    target_lang: String,
    stream_stdin_f32: bool,
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

    let mut model = Nemotron::from_pretrained(&args.model_dir, None)?;
    if model.mode() == NemotronMode::Multilingual {
        model.set_target_lang(&args.target_lang)?;
    }

    if args.stream_stdin_f32 {
        run_streaming_stdin(&mut model, started)?;
        return Ok(());
    }

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

fn run_streaming_stdin(model: &mut Nemotron, started: Instant) -> Result<(), Box<dyn Error>> {
    let mut stdin = std::io::stdin().lock();
    let mut read_buffer = [0u8; 32 * 1024];
    let mut byte_buffer: Vec<u8> = Vec::new();
    let mut sample_buffer: Vec<f32> = Vec::with_capacity(CHUNK_SIZE * 2);
    let mut last_text = String::new();
    let mut total_samples: usize = 0;

    loop {
        let count = stdin.read(&mut read_buffer)?;
        if count == 0 {
            break;
        }
        byte_buffer.extend_from_slice(&read_buffer[..count]);
        let aligned_byte_count = byte_buffer.len() / 4 * 4;
        for bytes in byte_buffer[..aligned_byte_count].chunks_exact(4) {
            sample_buffer.push(f32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]));
        }
        byte_buffer.drain(..aligned_byte_count);

        while sample_buffer.len() >= CHUNK_SIZE {
            let chunk: Vec<f32> = sample_buffer.drain(..CHUNK_SIZE).collect();
            total_samples += chunk.len();
            let _ = model.transcribe_chunk(&chunk)?;
            emit_partial_if_changed(model, &mut last_text)?;
        }
    }

    if !byte_buffer.is_empty() {
        return Err("stdin Float32 stream ended with a partial sample".into());
    }

    if !sample_buffer.is_empty() {
        total_samples += sample_buffer.len();
        sample_buffer.resize(CHUNK_SIZE, 0.0);
        let _ = model.transcribe_chunk(&sample_buffer)?;
        emit_partial_if_changed(model, &mut last_text)?;
    }

    for _ in 0..3 {
        let _ = model.transcribe_chunk(&vec![0.0; CHUNK_SIZE])?;
        emit_partial_if_changed(model, &mut last_text)?;
    }

    let final_text = model.get_transcript().trim().to_string();
    println!("{}", json!({ "event": "final", "text": final_text }));
    std::io::stdout().flush()?;

    eprintln!(
        "typeforme-nemotron-asr stream completed in {:.2}s (audio: {:.2}s)",
        started.elapsed().as_secs_f32(),
        total_samples as f32 / 16_000.0
    );
    std::io::stderr().flush()?;
    Ok(())
}

fn emit_partial_if_changed(model: &Nemotron, last_text: &mut String) -> Result<(), Box<dyn Error>> {
    let text = model.get_transcript().trim().to_string();
    if text.is_empty() || text == *last_text {
        return Ok(());
    }
    *last_text = text.clone();
    println!("{}", json!({ "event": "partial", "text": text }));
    std::io::stdout().flush()?;
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
