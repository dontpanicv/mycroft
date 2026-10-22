// On macOS, Cua Driver's ScreenCaptureKit bindings link the Swift Concurrency runtime (`@rpath/libswift_Concurrency
// .dylib`). Cargo passes a dependency's rpath only to binaries of that dependency, so hands names the system's Swift
// runtime itself, as Cua's own binary does.

fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
    }
}
