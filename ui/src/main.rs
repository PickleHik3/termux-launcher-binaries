use std::path::Path;
use std::process::{Command, ExitCode};

use tlstore_ui::app::{self, Options};
use tlstore_ui::launch;
use tlstore_ui::store::{proc::Env, Exit, Router};
use tlstore_ui::term::{self, Parser, Tty};

const USAGE: &str = "tlstore-ui opens the store; run tlstore to start it.

  tlstore-ui           open the store
  tlstore-ui --probe   list what this terminal can draw
";

fn probe() -> std::io::Result<()> {
    let mut tty = Tty::open()?;
    let (caps, _) = term::probe(&mut tty, &mut Parser::new(), term::probe::PROBE_TIMEOUT);
    let size = tty.size()?;
    drop(tty);
    let yes = |b: bool| if b { "yes" } else { "no" };
    println!("pictures        {}", yes(caps.kitty_graphics));
    println!("text sizing     {}", yes(caps.text_sizing));
    println!("smooth frames   {}", yes(caps.sync_output));
    println!("resize reports  {}", yes(caps.in_band_resize));
    match caps.cell_px {
        Some((w, h)) => println!("cell            {w}x{h} px"),
        None => println!("cell            unknown"),
    }
    println!("grid            {}x{}", size.cols, size.rows);
    match caps.dark() {
        Some(d) => println!("background      {}", if d { "dark" } else { "light" }),
        None => println!("background      unknown"),
    }
    println!("answered        {}", yes(caps.answered));
    Ok(())
}

/// Opens the store here, or in a window of its own when this pane is smaller than the store
/// is designed for (see `launch`). When the store moved itself to a newer release while it
/// ran, the new `tlstore-ui` takes over from here (see [`reexec`]).
fn store() -> ExitCode {
    let env = Env::from_env();
    // This binary's path, taken now: a self-update renames the new copy over this file,
    // after which /proc/self/exe names a deleted inode and the path is what to run.
    let exe = std::env::current_exe().unwrap_or_else(|_| "tlstore-ui".into());
    let size = Tty::open().and_then(|t| t.size()).ok();
    let hint = match size {
        Some(s) => {
            let no_window = std::env::var("TLSTORE_NO_WINDOW").is_ok_and(|v| v == "1");
            match launch::start(s.cols, s.rows, no_window, env.launcherctl.as_deref(), &exe) {
                launch::Start::Moved => {
                    println!("{}", launch::OPENED);
                    return ExitCode::SUCCESS;
                }
                launch::Start::Here(hint) => hint,
            }
        }
        None => None,
    };
    let mut router = Router::animated(env);
    if let Some(h) = hint {
        router.st.notice = Some(h.to_string());
    }
    let exit = router.st.exit.clone();
    match app::run(Box::new(router), Options::default()) {
        Ok(()) => match exit.borrow_mut().take() {
            Some(Exit::ReExec { version }) => reexec(&exe, &version),
            None => ExitCode::SUCCESS,
        },
        Err(e) => {
            eprintln!("tlstore-ui: {e}");
            ExitCode::FAILURE
        }
    }
}

/// The store under this process is a newer release now: runs the new `tlstore-ui` in this
/// process's place — same arguments, same environment, plus `TLSTORE_UI_SELF_UPDATED=<version>`
/// so the new copy says so once and never checks for an update again on this launch. The
/// terminal is already back the way it was found (`app::run` restores it on the way out, as
/// on any exit). exec only returns when it failed; then the person is told to start again.
fn reexec(exe: &Path, version: &str) -> ExitCode {
    use std::os::unix::process::CommandExt;
    let mut args = std::env::args_os();
    let argv0 = args.next().unwrap_or_else(|| "tlstore".into());
    let err = Command::new(exe).args(args).arg0(argv0).env("TLSTORE_UI_SELF_UPDATED", version).exec();
    eprintln!("tlstore-ui: could not start the new store: {err}");
    println!("tlstore updated to {version} — run tlstore again");
    ExitCode::SUCCESS
}

fn main() -> ExitCode {
    let arg = std::env::args().nth(1).unwrap_or_default();
    name_process(arg.is_empty());
    let result = match arg.as_str() {
        "" => return store(),
        #[cfg(feature = "shot")]
        "--shot" | "--shot-all" => {
            let args: Vec<String> = std::env::args().skip(1).collect();
            tlstore_ui::shot::cli(&args)
        }
        "--probe" => probe(),
        "--version" => {
            // The second line is one compile-time literal (`concat!`, not two prints that just
            // happen to run back to back) so the label and hash sit in a single contiguous
            // string in the binary's rodata — checkTlstoreUiFresh (app/build.gradle) greps the
            // built binary for it without executing it, since a device-ABI binary cannot run on
            // the build host. See scripts/ui-src-hash.sh and build.rs.
            const SRC_HASH_LINE: &str = concat!("TLSTORE_UI_SRC_HASH=", env!("TLSTORE_UI_SRC_HASH"));
            println!("tlstore-ui {}", env!("CARGO_PKG_VERSION"));
            println!("{SRC_HASH_LINE}");
            Ok(())
        }
        _ => {
            eprint!("{USAGE}");
            return ExitCode::from(2);
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("tlstore-ui: {e}");
            ExitCode::FAILURE
        }
    }
}

/// The launcher labels a pane or window chip with the foreground process's name: argv[0] from
/// `/proc/<pid>/cmdline` (WindowForegroundResolver), which for this binary is the path of
/// `tlstore-ui`. People know the store as `tlstore`, so the store re-executes itself once with
/// that argv[0], and also sets `comm` for `ps` and `top`. The environment survives that exec,
/// `TLSTORE_UI_SELF_UPDATED` included.
fn name_process(store: bool) {
    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        use std::os::unix::process::CommandExt;
        let argv0 = std::env::args_os().next().unwrap_or_default();
        if store && argv0 != "tlstore" {
            // exec only returns on failure; the store then runs under its own name.
            let _ = std::process::Command::new("/proc/self/exe").arg0("tlstore").exec();
        }
        unsafe {
            libc::prctl(libc::PR_SET_NAME, c"tlstore".as_ptr());
        }
    }
}
