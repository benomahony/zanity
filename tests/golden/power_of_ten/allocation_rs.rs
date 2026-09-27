struct Log {
    lines: Vec<String>,
}

impl Log {
    fn new(capacity: usize) -> Log {
        Log { lines: Vec::with_capacity(capacity) }
    }

    fn record(&mut self, line: &str) {
        self.lines.push(line.to_string());
    }

    fn first(&self) -> Option<&String> {
        self.lines.first()
    }
}

fn main() {
    let log = Log::new(16);
    let boxed = Box::new(log);
    drop(boxed);
}
