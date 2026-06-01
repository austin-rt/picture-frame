use heic::{DecoderConfig, PixelLayout};
use image::{ImageBuffer, Rgba};
use std::env;
use std::fs;
use std::process;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() != 3 {
        eprintln!("Usage: heic2jpg <input.heic> <output.jpg>");
        process::exit(1);
    }

    let data = match fs::read(&args[1]) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("open: {e}");
            process::exit(1);
        }
    };

    let output = match DecoderConfig::new().decode(&data, PixelLayout::Rgba8) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("decode: {e}");
            process::exit(1);
        }
    };

    let w = output.width;
    let h = output.height;
    let buf: ImageBuffer<Rgba<u8>, _> = match ImageBuffer::from_raw(w, h, output.data) {
        Some(b) => b,
        None => {
            eprintln!("buffer size mismatch");
            process::exit(1);
        }
    };

    let rgb = image::DynamicImage::ImageRgba8(buf);
    match rgb.save(&args[2]) {
        Ok(_) => {}
        Err(e) => {
            eprintln!("save: {e}");
            process::exit(1);
        }
    }
}
