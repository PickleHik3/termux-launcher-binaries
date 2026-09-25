//! The decode worker: a small pool of threads that decode, fit and encode pictures
//! ([`crate::picture::decode_file`]) and parse READMEs ([`super::readme::parse`]) so a draw
//! never does. Requests go down a channel; each answer comes back on another and pokes a
//! self-pipe, whose read end the app loop polls like a child's stdout, so the store reads the
//! answers as an `Event::Readable` and the next frame uses them.

use std::io;
use std::os::fd::RawFd;
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver, Sender, TryRecvError};
use std::sync::{Arc, Mutex};

use crate::picture::{self, Decoded, FileKey};

use super::readme;

/// How many threads decode at once: one keeps a clip's first frame from waiting behind a
/// README's pictures, two is plenty for a phone.
pub const WORKERS: usize = 2;

/// One thing to do off the UI thread.
pub enum Job {
    Picture(FileKey),
    Readme { name: String, path: PathBuf, skip: Vec<String> },
}

/// One answer.
pub enum Done {
    Picture { key: FileKey, result: io::Result<Decoded> },
    Readme { name: String, doc: readme::Doc },
}

/// The pool, its channels and the wake-up pipe.
pub struct Decoder {
    tx: Sender<Job>,
    rx: Receiver<Done>,
    wake_r: RawFd,
    wake_w: RawFd,
    /// Jobs sent and not yet taken back.
    pending: usize,
}

fn run_worker(jobs: Arc<Mutex<Receiver<Job>>>, done: Sender<Done>, wake_w: RawFd) {
    loop {
        let job = {
            let Ok(guard) = jobs.lock() else { return };
            guard.recv()
        };
        let Ok(job) = job else { return };
        let answer = match job {
            Job::Picture(key) => {
                let result = picture::decode_file(&key);
                Done::Picture { key, result }
            }
            Job::Readme { name, path, skip } => {
                let text = std::fs::read_to_string(&path).unwrap_or_default();
                Done::Readme { name, doc: readme::parse(&text, &skip) }
            }
        };
        if done.send(answer).is_err() {
            return;
        }
        let b = [1u8];
        // SAFETY: a one-byte write to a pipe this process owns; a full pipe (EAGAIN) or a
        // closed one (EBADF after the decoder is dropped) is fine to ignore.
        unsafe {
            libc::write(wake_w, b.as_ptr().cast(), 1);
        }
    }
}

impl Decoder {
    /// Starts the pool. Fails only when the pipe cannot be made.
    pub fn new() -> io::Result<Decoder> {
        let mut fds = [0 as libc::c_int; 2];
        // SAFETY: fds has room for two descriptors.
        if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        for fd in fds {
            // SAFETY: fd is one we just created. Non-blocking so a worker never waits on a
            // full pipe; close-on-exec so the script never inherits it.
            unsafe {
                let fl = libc::fcntl(fd, libc::F_GETFL);
                libc::fcntl(fd, libc::F_SETFL, fl | libc::O_NONBLOCK);
                libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
            }
        }
        let (tx, jobs) = mpsc::channel::<Job>();
        let (done_tx, rx) = mpsc::channel::<Done>();
        let jobs = Arc::new(Mutex::new(jobs));
        for i in 0..WORKERS {
            let jobs = jobs.clone();
            let done_tx = done_tx.clone();
            let wake_w = fds[1];
            let spawned = std::thread::Builder::new()
                .name(format!("tlstore-decode-{i}"))
                .spawn(move || run_worker(jobs, done_tx, wake_w));
            if spawned.is_err() && i == 0 {
                return Err(io::Error::other("no decode thread"));
            }
        }
        Ok(Decoder { tx, rx, wake_r: fds[0], wake_w: fds[1], pending: 0 })
    }

    /// The fd to poll while [`Decoder::busy`].
    pub fn fd(&self) -> RawFd {
        self.wake_r
    }

    /// True while an answer is still to come.
    pub fn busy(&self) -> bool {
        self.pending > 0
    }

    /// Hands a job to the pool.
    pub fn submit(&mut self, job: Job) {
        if self.tx.send(job).is_ok() {
            self.pending += 1;
        }
    }

    /// Takes every answer that has arrived (and clears the wake-up pipe).
    pub fn drain(&mut self) -> Vec<Done> {
        let mut sink = [0u8; 64];
        // SAFETY: non-blocking read into a local buffer.
        while unsafe { libc::read(self.wake_r, sink.as_mut_ptr().cast(), sink.len()) } > 0 {}
        let mut out = Vec::new();
        loop {
            match self.rx.try_recv() {
                Ok(d) => {
                    self.pending = self.pending.saturating_sub(1);
                    out.push(d);
                }
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    self.pending = 0;
                    break;
                }
            }
        }
        out
    }
}

impl Drop for Decoder {
    fn drop(&mut self) {
        // SAFETY: closing descriptors this process owns; the workers' late writes fail
        // quietly.
        unsafe {
            libc::close(self.wake_r);
            libc::close(self.wake_w);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::picture::Fit;
    use std::path::Path;
    use std::time::{Duration, Instant};

    fn wait(d: &mut Decoder) -> Vec<Done> {
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut got = Vec::new();
        while d.busy() && Instant::now() < deadline {
            let _ = crate::term::poll_fds(&[(d.fd(), libc::POLLIN)], Some(Duration::from_millis(200)));
            got.extend(d.drain());
        }
        got
    }

    #[test]
    fn answers_come_back_and_wake_the_pipe() {
        let mut d = Decoder::new().unwrap();
        assert!(!d.busy());
        let dir = std::env::temp_dir().join(format!("tlstore-ui-decode-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let md = dir.join("r.md");
        std::fs::write(&md, "## A\n\ntext\n").unwrap();
        d.submit(Job::Readme { name: "x".into(), path: md, skip: vec![] });
        d.submit(Job::Picture((Path::new("/nonexistent/p.png").to_path_buf(), 4, 4, Fit::Contain, None, false)));
        assert!(d.busy());
        let got = wait(&mut d);
        assert_eq!(got.len(), 2);
        assert!(!d.busy());
        assert!(got.iter().any(|g| matches!(g, Done::Readme { name, doc } if name == "x" && !doc.blocks.is_empty())));
        assert!(got.iter().any(|g| matches!(g, Done::Picture { result: Err(_), .. })));
        std::fs::remove_dir_all(&dir).ok();
    }
}
